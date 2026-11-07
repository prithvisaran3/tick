"""Plaid integration behind a BankProvider interface. Access tokens never leave the server: they live in Supabase Vault and are referenced by id.

HARD CAP: 10 Items ever (Plaid Trial plan). Removing an Item does NOT free a slot, so the lifetime counter lives in plaid_slots.
NEVER create or remove production Items automatically or in tests: Items are only created from the user's explicit Link flow."""
from __future__ import annotations

import hashlib
import json
import logging
import os
import time
from abc import ABC, abstractmethod
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo
from typing import Any

import httpx
import jwt
from cryptography.hazmat.primitives.asymmetric.ec import EllipticCurvePublicNumbers, SECP256R1
from fastapi import APIRouter, BackgroundTasks, Depends, Header, HTTPException, Request
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, ConfigDict, Field

from . import store
from .auth import current_user, require_cron, user_limiter
from .config import settings
from .db import rest
from .audit import audit
from .merchants import categorize, clean_merchant, looks_business
from . import ai
from . import paybacks
from . import rules as rules_mod
from . import transfers as transfers_mod
from .reconcile import Candidate, apply_plaid_removed, plan, plan_and_apply

ITEM_CAP = 10
router = APIRouter()
log = logging.getLogger('tick.plaid')

def base_url(env: str) -> str:
    return {"production": "https://production.plaid.com", "development": "https://development.plaid.com"}.get(env, "https://sandbox.plaid.com")

class BankProvider(ABC):
    @abstractmethod
    def create_link_token(self, user_id: str, *, access_token: str | None = None, accounts: bool = False) -> dict: ...
    @abstractmethod
    def link_token_result(self, link_token: str) -> list[str]: ...
    @abstractmethod
    def exchange(self, public_token: str) -> tuple[str, str]: ...
    @abstractmethod
    def accounts(self, access_token: str) -> list[dict]: ...
    @abstractmethod
    def sync_page(self, access_token: str, cursor: str | None) -> dict: ...
    @abstractmethod
    def item_institution(self, access_token: str) -> str | None: ...
    def item_products(self, access_token: str) -> list[str]:
        return ["transactions"]
    def liabilities(self, access_token: str) -> dict:
        return {}

class PlaidProvider(BankProvider):
    def __init__(self, client_id: str, secret: str, env: str, webhook: str) -> None:
        self.cid, self.secret, self.env, self.webhook = client_id, secret, env, webhook
        self.http = httpx.Client(base_url=base_url(env), timeout=30)

    def _post(self, path: str, body: dict) -> dict:
        r = self.http.post(path, json={"client_id": self.cid, "secret": self.secret, **body})
        if r.status_code >= 400:
            try:
                e = r.json()
            except Exception:
                e = {}
            raise PlaidError(e.get("error_code", "UNKNOWN"), e.get("error_type", ""), r.status_code)
        return r.json()

    def create_link_token(self, user_id: str, *, access_token: str | None = None, accounts: bool = False) -> dict:
        body: dict[str, Any] = {"client_name": "Tick", "language": "en", "country_codes": ["US"], "user": {"client_user_id": user_id},
                                "webhook": self.webhook, "hosted_link": {"completion_redirect_uri": "tick://plaid-complete"}}
        redirect = os.environ.get("PLAID_REDIRECT_URI", "")
        if redirect:
            body["redirect_uri"] = redirect          # only after it is registered under Allowed redirect URIs in the Plaid dashboard
        if access_token:
            body["access_token"] = access_token          # update mode: re-authenticate the SAME Item, never a new one
            if accounts:
                body["update"] = {"account_selection_enabled": True}      # "Some accounts not shared": pick more accounts, still no new slot
            return self._post("/link/token/create", body)
        body["products"] = ["transactions"]
        body["transactions"] = {"days_requested": 365}
        if os.environ.get("PLAID_LIABILITIES", "1") != "0":
            # Cards and loans: statement balance, minimum payment, due date. Optional, so a bank without it still links.
            try:
                return self._post("/link/token/create", {**body, "optional_products": ["liabilities"]})
            except PlaidError as e:
                if e.typ != "INVALID_REQUEST" and e.code not in ("INVALID_PRODUCT", "PRODUCTS_NOT_ENABLED", "PRODUCT_NOT_ENABLED", "INVALID_FIELD"):
                    raise
                # The plan doesn't allow Liabilities: link without it (creating a link token never creates an Item).
        return self._post("/link/token/create", body)

    def link_token_result(self, link_token: str) -> list[str]:
        r = self._post("/link/token/get", {"link_token": link_token})
        out: list[str] = []
        for s in r.get("link_sessions") or []:
            for res in (s.get("results") or {}).get("item_add_results") or []:
                if res.get("public_token"):
                    out.append(res["public_token"])
        return out

    def exchange(self, public_token: str) -> tuple[str, str]:
        r = self._post("/item/public_token/exchange", {"public_token": public_token})
        return r["access_token"], r["item_id"]

    def accounts(self, access_token: str) -> list[dict]:
        return self._post("/accounts/get", {"access_token": access_token})["accounts"]

    def sync_page(self, access_token: str, cursor: str | None) -> dict:
        body: dict[str, Any] = {"access_token": access_token, "count": 250}
        if cursor:
            body["cursor"] = cursor
        return self._post("/transactions/sync", body)

    def item_institution(self, access_token: str) -> str | None:
        try:
            item = self._post("/item/get", {"access_token": access_token})["item"]
            if item.get("institution_id"):
                return self._post("/institutions/get_by_id", {"institution_id": item["institution_id"], "country_codes": ["US"]})["institution"]["name"]
        except PlaidError:
            pass
        return None

    def refresh(self, access_token: str) -> None:
        """Ask the bank for fresh transactions now (/transactions/refresh). Best effort: callers swallow PlaidError."""
        self._post("/transactions/refresh", {"access_token": access_token})

    def item_products(self, access_token: str) -> list[str]:
        try:
            item = self._post("/item/get", {"access_token": access_token})["item"]
            return sorted(set(item.get("products") or []) | set(item.get("billed_products") or []))
        except PlaidError:
            return ["transactions"]

    def liabilities(self, access_token: str) -> dict:
        """Only called for Items that were granted Liabilities at link time."""
        return self._post("/liabilities/get", {"access_token": access_token}).get("liabilities") or {}

    def remove_item(self, access_token: str) -> None:
        """Only from the person's own "Delete all my data". Never automatic, never in tests (they use a fake provider)."""
        self._post("/item/remove", {"access_token": access_token})

    def webhook_key(self, kid: str) -> dict:
        return self._post("/webhook_verification_key/get", {"key_id": kid})["key"]

class PlaidError(Exception):
    def __init__(self, code: str, typ: str, status: int) -> None:
        super().__init__(code)
        self.code, self.typ, self.status = code, typ, status

_provider: BankProvider | None = None

def provider() -> BankProvider:
    global _provider
    if _provider is None:
        s = settings()
        _provider = PlaidProvider(s.plaid_client_id, s.plaid_secret, s.plaid_env, s.public_base_url.rstrip("/") + "/webhooks/plaid")
    return _provider

# ---------------- webhook verification ----------------
_keys: dict[str, tuple[float, dict]] = {}
_bad_kids: dict[str, float] = {}
_key_fetches: list[float] = []
MAX_AGE = 300
KEY_FETCHES_PER_MIN = 6

def verify_webhook(body: bytes, token: str, prov: PlaidProvider | None = None, now: float | None = None) -> dict:
    """Verify Plaid's Plaid-Verification JWT: ES256, key by kid from /webhook_verification_key/get (cached), iat <= 5 min old, body hash matches."""
    try:
        header = jwt.get_unverified_header(token)
    except Exception:
        raise HTTPException(401, "bad verification header")
    if header.get("alg") != "ES256" or not header.get("kid"):
        raise HTTPException(401, "bad verification header")
    kid = header["kid"]
    prov = prov or provider()  # type: ignore[assignment]
    cached = _keys.get(kid)
    if not cached or cached[0] < time.time():
        now_t = time.time()
        if _bad_kids.get(kid, 0) > now_t:
            raise HTTPException(401, "unknown key")
        _key_fetches[:] = [t for t in _key_fetches if t > now_t - 60]
        if len(_key_fetches) >= KEY_FETCHES_PER_MIN:             # garbage kids must not make us hammer Plaid
            if not cached:
                raise HTTPException(429, "too many key lookups")
            # A known key past its refresh time stays usable (Plaid's expired_at is still checked below), so a flood of
            # random kids can never lock out Plaid's real webhooks.
        else:
            _key_fetches.append(now_t)
            try:
                key = prov.webhook_key(kid)  # type: ignore[union-attr]
                _keys[kid] = (now_t + 3600, key)
            except PlaidError:
                if not cached:
                    if len(_bad_kids) > 1000:
                        _bad_kids.clear()
                    _bad_kids[kid] = now_t + 60
                    raise HTTPException(401, "unknown key")
    jwk = _keys[kid][1]
    if jwk.get("expired_at") is not None:
        raise HTTPException(401, "key expired")
    pub = EllipticCurvePublicNumbers(int.from_bytes(_b64(jwk["x"]), "big"), int.from_bytes(_b64(jwk["y"]), "big"), SECP256R1()).public_key()
    try:
        claims = jwt.decode(token, pub, algorithms=["ES256"], options={"verify_aud": False, "require": ["iat"]})
    except Exception:
        raise HTTPException(401, "bad signature")
    if (now or time.time()) - claims["iat"] > MAX_AGE:
        raise HTTPException(401, "stale webhook")
    import hmac
    if not hmac.compare_digest(claims.get("request_body_sha256", ""), hashlib.sha256(body).hexdigest()):
        raise HTTPException(401, "body hash mismatch")
    return claims

def _b64(s: str) -> bytes:
    import base64
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))

# ---------------- slots ----------------
def links_used(user_id: str) -> int:
    """Distinct Plaid item_ids EVER created for this user, removed ones included (plaid_items is append-only).
    Counting attempts or bumping a counter double-counted a link once (webhook + app raced on one session); a set of item_ids can't."""
    items = {r["item_id"] for r in rest().select("plaid_items", user_id=f"eq.{user_id}", select="item_id")}
    items |= {r["item_id"] for r in rest().select("connections", user_id=f"eq.{user_id}", provider="eq.plaid", select="item_id") if r.get("item_id")}
    return len(items)

def total_links_used() -> int:
    """Plaid's Trial cap is per Plaid CLIENT, not per Tick user: count distinct item_ids across everyone."""
    items = {r["item_id"] for r in rest().select("plaid_items", select="item_id")}
    items |= {r["item_id"] for r in rest().select("connections", provider="eq.plaid", select="item_id") if r.get("item_id")}
    return len(items)

def link_slots_left(user_id: str) -> int:
    return max(0, min(ITEM_CAP - links_used(user_id), ITEM_CAP - total_links_used()))

def owners() -> set[str]:
    """Who may create NEW bank links. TICK_OWNER_USER_IDS (comma-separated) when set. Otherwise the user who made the first link
    (fail closed for strangers who signed up later); with no link at all yet, anyone signed in (first run)."""
    env = {x.strip() for x in os.environ.get("TICK_OWNER_USER_IDS", "").split(",") if x.strip()}
    if env:
        return env
    rows = rest().select("plaid_items", select="user_id,created_at", order="created_at.asc", limit="1")
    return {rows[0]["user_id"]} if rows else set()

LINK_LIMITED = "Bank linking is limited to 10 accounts right now."      # one calm line for the owner lock and the cap: no counts, nothing about plans

def can_link(user_id: str) -> bool:
    """May this user create NEW bank links? (Update mode for their own existing connections is always allowed.)"""
    allowed = owners()
    return not allowed or user_id in allowed

def require_link_owner(user_id: str) -> None:
    if not can_link(user_id):
        raise HTTPException(403, LINK_LIMITED)

OPEN_SESSION_MIN = 30

def record_item(user_id: str, item_id: str, institution: str | None, link_token_value: str) -> None:
    """Idempotent: the same item_id is recorded once no matter how many times it is exchanged."""
    rest().insert("plaid_items", {"item_id": item_id, "user_id": user_id, "institution": institution, "link_token_prefix": link_token_value[:24]},
                  returning=False, ignore_duplicates=True)

# ---------------- mapping ----------------
_FEE = ("INTEREST CHARGE", "LATE FEE", "ANNUAL FEE", "FOREIGN TRANSACTION FEE", "FINANCE CHARGE", "OVERDRAFT", "SERVICE FEE", "INTEREST CHARGED")

def classify(t: dict, acct_type: str | None, cents: int) -> tuple[str | None, str | None, list[str]]:
    """(category name or None for 'categorise by merchant', flow, extra tags) from Plaid's category and the account type.
    Sign convention: Plaid positive = money out; Tick negative = money out. A card purchase is spending; a card payment and a
    loan's 'payment received' are internal transfers; a refund on a card lowers spending and is never income; a loan payment from
    checking is a bill; fees and interest have their own category."""
    pfc = t.get("personal_finance_category") or {}
    primary, detailed = pfc.get("primary", ""), pfc.get("detailed", "")
    name = (t.get("name") or t.get("merchant_name") or "").upper()
    credit_like = acct_type in ("credit", "loan")
    if detailed == "LOAN_PAYMENTS_CREDIT_CARD_PAYMENT" or (credit_like and cents > 0 and primary in ("TRANSFER_IN", "LOAN_PAYMENTS")):
        return "Transfer", "transfer", []
    if acct_type == "loan" and cents > 0:
        return "Transfer", "transfer", []
    if primary == "LOAN_PAYMENTS" and cents < 0 and not credit_like:
        return "Loan payment", "bill", []
    if cents > 0 and not credit_like and ("INTEREST" in detailed or "INTEREST" in name or primary == "INCOME"):
        return "Income", None, []                # "Interest earned" on savings is income, not a fee
    if cents < 0 and (primary == "BANK_FEES" or detailed.startswith("BANK_FEES") or "INTEREST" in detailed or any(k in name for k in _FEE) or acct_type == "loan"):
        return "Fees and interest", None, []
    if transfers_mod.is_p2p(name) and not credit_like:
        return transfers_mod.p2p_category(name), None, []    # Zelle / Venmo / Cash App: money to or from PEOPLE (never a transfer)
    if primary in ("TRANSFER_IN", "TRANSFER_OUT"):
        return "Transfer", None, []              # pairing decides later whether it went to one of my own accounts
    if cents > 0:
        return (None, None, ["refund"]) if credit_like else ("Income", None, [])
    return None, None, []

def plaid_candidate(t: dict, acct_by_pid: dict[str, dict], rules: dict[str, str], name_to_id: dict[str, str]) -> tuple[Candidate, list[str]]:
    cents = -round(float(t["amount"]) * 100)              # Plaid: positive = money out
    when = t.get("datetime") or t.get("authorized_datetime")
    precise = bool(when)
    if when:
        occurred = datetime.fromisoformat(when.replace("Z", "+00:00"))
    else:
        d = t.get("authorized_date") or t["date"]
        occurred = datetime.fromisoformat(d).replace(hour=16, tzinfo=timezone.utc)   # ~noon Eastern
    raw = t.get("name") or t.get("merchant_name") or ""
    clean = t.get("merchant_name") or clean_merchant(raw)
    acct = acct_by_pid.get(t["account_id"], {})
    cat, flow, extra = classify(t, acct.get("type"), cents)
    if cat is None:
        cat, _ = categorize(clean or raw, rules)
    tags = (["business"] if cents < 0 and flow is None and looks_business(clean or raw) else []) + extra
    c = Candidate("plaid", t["transaction_id"], cents, occurred, raw, clean, acct.get("mask"), "pending" if t.get("pending") else "posted",
                  plaid_transaction_id=t["transaction_id"], plaid_pending_id=t.get("pending_transaction_id"), confidence=1.0,
                  account_id=acct.get("id"), category_id=name_to_id.get(cat), time_precise=precise, flow=flow)
    return c, tags

def _ensure_accounts(user_id: str, conn_id: str, accts: list[dict], institution: str | None = None) -> dict[str, dict]:
    """Upsert the Item's accounts. Depository balances are positive; credit and loan balances are what you OWE, stored negative.
    Only masks are stored, never full account or routing numbers."""
    out: dict[str, dict] = {}
    for a in accts:
        b = a.get("balances") or {}
        typ = {"depository": "checking", "credit": "credit", "loan": "loan", "investment": "other"}.get(a.get("type"), "other")
        if a.get("subtype") in ("savings", "money market", "cd", "hsa"):
            typ = "savings"
        cur, avail, limit = b.get("current"), b.get("available"), b.get("limit")
        owes = typ in ("credit", "loan")
        bal = None if cur is None else (-round(cur * 100) if owes else round(cur * 100))
        av = None if avail is None else round(avail * 100)
        row = {"user_id": user_id, "connection_id": conn_id, "provider_account_id": a["account_id"], "name": a.get("official_name") or a.get("name") or "Account",
               "mask": a.get("mask"), "type": typ, "subtype": a.get("subtype"), "institution": institution, "balance_cents": bal, "available_cents": av,
               "credit_limit_cents": None if limit is None else round(limit * 100), "include_in_safe": typ in ("checking", "credit")}
        existing = rest().select("accounts", user_id=f"eq.{user_id}", provider_account_id=f"eq.{a['account_id']}")
        if existing:
            # What the person set survives every sync: the name they chose and whether it counts toward Safe to spend. The bank owns balances only.
            keep = {"name", "include_in_safe"}
            patch = {k: v for k, v in row.items() if k not in keep and k not in ("user_id", "provider_account_id")}
            saved = (rest().update("accounts", {"id": existing[0]["id"], "user_id": user_id}, patch) or [existing[0]])[0]
        else:
            saved = rest().insert("accounts", row, upsert_on="user_id,provider_account_id")[0]
        out[a["account_id"]] = saved
    return out

def _cents(v) -> int | None:
    return None if v is None else round(float(v) * 100)

def apply_liabilities(user_id: str, liab: dict, accts: dict[str, dict]) -> int:
    """Statement balance, minimum payment, due date and rates for cards; rate and next payment for student loans."""
    now = datetime.now(timezone.utc).isoformat()
    n = 0
    for c in liab.get("credit") or []:
        a = accts.get(c.get("account_id"))
        if not a:
            continue
        purchase = next((x for x in c.get("aprs") or [] if x.get("apr_type") == "purchase_apr"), None) or next(iter(c.get("aprs") or []), None)
        rest().update("accounts", {"id": a["id"], "user_id": user_id}, {
            "statement_balance_cents": _cents(c.get("last_statement_balance")), "minimum_payment_cents": _cents(c.get("minimum_payment_amount")),
            "next_payment_due_date": c.get("next_payment_due_date"), "last_statement_date": c.get("last_statement_issue_date"),
            "last_payment_cents": _cents(c.get("last_payment_amount")), "last_payment_date": c.get("last_payment_date"),
            "apr_bps": None if not purchase or purchase.get("apr_percentage") is None else round(float(purchase["apr_percentage"]) * 100),
            "liabilities_updated_at": now})
        n += 1
    for s_ in liab.get("student") or []:
        a = accts.get(s_.get("account_id"))
        if not a:
            continue
        rest().update("accounts", {"id": a["id"], "user_id": user_id}, {
            "interest_rate_bps": None if s_.get("interest_rate_percentage") is None else round(float(s_["interest_rate_percentage"]) * 100),
            "minimum_payment_cents": _cents(s_.get("minimum_payment_amount")), "next_payment_cents": _cents(s_.get("minimum_payment_amount")),
            "next_payment_due_date": s_.get("next_payment_due_date"), "last_payment_cents": _cents(s_.get("last_payment_amount")),
            "last_payment_date": s_.get("last_payment_date"), "liabilities_updated_at": now})
        n += 1
    return n

def my_names(user_id: str) -> set[str]:
    from . import transfers
    prof = rest().select("profiles", user_id=f"eq.{user_id}", select="display_name")
    return transfers.name_tokens(prof[0].get("display_name") if prof else None, os.environ.get("TICK_MY_NAMES", ""))

def pair_transfers(user_id: str, days: int = 60) -> int:
    """Apply the money rules to recent rows (see MONEY_RULES.md and transfers.py): pair internal transfers across institutions, keep
    Zelle and other person-to-person money as real money (category Friends and family), and mark both sides of a transfer excluded.
    Idempotent; never touches rows whose flow or category the person edited."""
    from . import transfers
    since = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
    raw = rest().select("transactions", user_id=f"eq.{user_id}", occurred_at=f"gte.{since}",
                        select="id,account_id,amount_cents,occurred_at,merchant_clean,merchant_raw,flow,category_id,transfer_pair_id,user_edited")
    return apply_money_rules(user_id, raw)

def apply_money_rules(user_id: str, raw: list[dict], *, dry_run: bool = False) -> dict | int:
    from . import transfers
    name_to_id, id_to_name = store.category_maps(user_id)
    accts = rest().select("accounts", user_id=f"eq.{user_id}", select="id,type,institution,name")
    types = {a["id"]: a["type"] for a in accts}
    insts = {a["id"]: next(iter(transfers.inst_keys(a.get("institution") or a.get("name"))), "") for a in accts}
    patches = transfers.pair(transfers.rows_from_db(raw, id_to_name), types, insts, my_names(user_id))
    by_id = {r["id"]: r for r in raw}
    friends, transfer_cat = name_to_id.get("Friends and family"), name_to_id.get("Transfer")
    plan: dict[str, dict] = {}
    for tid, patch in patches.items():
        row = by_id[tid]
        if patch.get("flow") == "transfer" and transfer_cat and "category" not in (row.get("user_edited") or []):
            patch = {**patch, "category_id": transfer_cat}
        plan[tid] = patch
    # Person-to-person rows that are not (now) transfers: Zelle to Kaarthik is spending, labelled Friends and family, not "Transfer".
    for r in raw:
        text = r.get("merchant_clean") or r.get("merchant_raw") or ""
        flow_after = plan.get(r["id"], {}).get("flow", r.get("flow"))
        if (friends and transfers.is_p2p(text) and flow_after is None and id_to_name.get(r.get("category_id") or "") == "Transfer"
                and "category" not in (r.get("user_edited") or [])):
            plan[r["id"]] = {**plan.get(r["id"], {}), "category_id": name_to_id.get(transfers.p2p_category(text)) or friends}
    if dry_run:
        return plan
    for tid, patch in plan.items():
        rest().update("transactions", {"id": tid, "user_id": user_id}, patch)
    return len(plan)

def ensure_expected_paycheck(user_id: str, today: date | None = None) -> None:
    """Nothing else creates `expected` rows on live data, so "Landed" and the Incoming list never had anything to match.
    Derive the paychecks from the person's payday rule: the last payday within 4 days (a deposit can post late) and the next one.
    Idempotent: one row per paycheck date, whatever its status, and it never touches a rule that has no amount."""
    from .pay import pay_period
    today = today or datetime.now(timezone.utc).astimezone(ZoneInfo("America/New_York")).date()
    try:
        st = rest().select("settings", user_id=f"eq.{user_id}", select="payday_rule")
        rule = st[0].get("payday_rule") if st else None
        amount = int((rule or {}).get("amount_cents") or 0)
        if amount <= 0:
            return
        # the first payday on or after four days ago (a deposit can post late), and the first on or after today
        dates = {p["next_payday"] for p in (pay_period(user_id, today - timedelta(days=5)), pay_period(user_id, today - timedelta(days=1))) if p}
        have = {e["expected_date"] for e in rest().select("expected", user_id=f"eq.{user_id}", kind="eq.paycheck", select="expected_date")}
        for d in sorted(dates):
            if d.isoformat() not in have and d <= today + timedelta(days=45):
                rest().insert("expected", {"user_id": user_id, "kind": "paycheck", "label": "Paycheck", "amount_cents": amount, "expected_date": d.isoformat()}, returning=False)
    except Exception:
        pass                                                   # a sync must never fail because of the paycheck helper

def _landed(user_id: str, txn_id: str, cents: int, when: datetime) -> None:
    """A positive transaction near an expected paycheck/refund/IOU of about the same size marks it landed."""
    if cents <= 0:
        return
    rows = rest().select("expected", user_id=f"eq.{user_id}", status="eq.expected", select="id,amount_cents,expected_date")
    best = None
    for e in rows:
        days = abs((datetime.fromisoformat(e["expected_date"]).date() - when.date()).days)
        if days <= 4 and abs(e["amount_cents"] - cents) <= max(500, e["amount_cents"] * 0.1):
            if best is None or days < best[0]:
                best = (days, e)
    if best:
        rest().update("expected", {"id": best[1]["id"]}, {"status": "landed", "matched_transaction_id": txn_id})

def _is_income_deposit(cand, accts: dict[str, dict]) -> bool:
    """Only real deposits can land an expected paycheck: not a card payment or refund on a card/loan, not an internal transfer."""
    if getattr(cand, "flow", None) in ("transfer", "settlement"):
        return False
    acct = next((a for a in accts.values() if a.get("id") == getattr(cand, "account_id", None)), None)
    return not (acct and acct.get("type") in ("credit", "loan"))

def _landed_in(expected: list[dict], user_id: str, txn_id: str, cents: int, when: datetime) -> None:
    """Like _landed, but against an expected-rows list loaded once per sync (no query per deposit)."""
    if cents <= 0:
        return
    best = None
    for e in expected:
        days = abs((datetime.fromisoformat(e["expected_date"]).date() - when.date()).days)
        if days <= 4 and abs(e["amount_cents"] - cents) <= max(500, e["amount_cents"] * 0.1) and (best is None or days < best[0]):
            best = (days, e)
    if best:
        expected.remove(best[1])
        rest().update("expected", {"id": best[1]["id"]}, {"status": "landed", "matched_transaction_id": txn_id})

ROW_DEFAULTS = {"tags": [], "flow": None, "needs_review": False, "confidence": 1.0, "card_last4": None, "plaid_pending_id": None,
                "account_id": None, "category_id": None, "merchant_clean": None, "merchant_raw": None, "status": "posted"}

def _normalise(rows: list[dict]) -> list[dict]:
    """PostgREST bulk inserts need every object to carry the same keys. A row that had no tags used to omit the key, and the whole
    page then failed with a 400 (this is what left Discover and Bank of America with no transactions). Every row now has every key."""
    keys: set[str] = set(ROW_DEFAULTS)
    for r in rows:
        keys |= set(r)
    return [{k: r.get(k, ROW_DEFAULTS.get(k)) for k in sorted(keys)} for r in rows]

def _flush(rows: list[dict]) -> None:
    if not rows:
        return
    batch = _normalise(rows)
    rows.clear()
    try:
        rest().insert("transactions", batch, returning=False, missing_default=True)       # one bulk insert instead of a request per transaction
    except httpx.HTTPStatusError as e:
        if e.response.status_code not in (400, 409, 422):
            raise
        # One bad row must not lose the page: fall back to row by row and skip only the rows the database refuses.
        for r in batch:
            try:
                rest().insert("transactions", r, returning=False, missing_default=True)
            except httpx.HTTPStatusError as e2:
                if e2.response.status_code not in (400, 409, 422):
                    raise
                log.warning("sync: skipped one row the database refused (%s)", e2.response.status_code)

LOGIN_CODES = {"ITEM_LOGIN_REQUIRED", "PENDING_EXPIRATION", "PENDING_DISCONNECT", "USER_PERMISSION_REVOKED", "USER_ACCOUNT_REVOKED", "ITEM_LOCKED",
               "ITEM_NOT_FOUND_ON_INSTITUTION_SIDE", "INVALID_CREDENTIALS", "INVALID_MFA", "ITEM_LOGIN_REQUIRED_OAUTH"}
CONSENT_CODES = {"NEW_ACCOUNTS_AVAILABLE", "ADDITIONAL_CONSENT_REQUIRED", "ACCESS_NOT_GRANTED", "NO_ACCOUNTS", "NO_AUTH_ACCOUNTS"}
BANK_CODES = {"INSTITUTION_DOWN", "INSTITUTION_NOT_RESPONDING", "INSTITUTION_NOT_AVAILABLE", "INSTITUTION_NO_LONGER_SUPPORTED", "INTERNAL_SERVER_ERROR",
              "PLANNED_MAINTENANCE", "RATE_LIMIT_EXCEEDED", "TRANSACTIONS_LIMIT", "INSTITUTION_REGISTRATION_REQUIRED", "UNAUTHORIZED_INSTITUTION"}
NOT_READY = {"PRODUCT_NOT_READY"}
MUTATION = "TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION"

def state_for_error(code: str | None) -> str:
    """Map a Plaid error code to the connection's sync_state shown on Banks."""
    if code in LOGIN_CODES:
        return "login_required"
    if code in CONSENT_CODES:
        return "partial"
    if code in NOT_READY:
        return "syncing"                      # the bank is still preparing the first history: not an error
    if code in BANK_CODES:
        return "bank_issue"
    return "error"

def mark(conn_id: str, **fields) -> None:
    try:
        rest().update("connections", {"id": conn_id}, fields)
    except Exception:
        log.warning("could not record sync state")

def sync_connection(conn: dict, prov: BankProvider | None = None) -> dict:
    """Run one sync and record the outcome in `sync_state` (never leave a connection looking like it is syncing forever)."""
    now = datetime.now(timezone.utc).isoformat()
    mark(conn["id"], sync_state="syncing", sync_started_at=now, last_attempt_at=now)
    counts: dict = {}
    try:
        counts = _sync_pages(conn, prov)
    except PlaidError as e:
        st = state_for_error(e.code)
        legacy = "login_required" if st == "login_required" else ("active" if st == "syncing" else "error")
        mark(conn["id"], sync_state=st, last_error=e.code, status=legacy, error_code=e.code, last_attempt_at=datetime.now(timezone.utc).isoformat())
        return {**counts, "error": e.code}
    except Exception as e:
        mark(conn["id"], sync_state="error", last_error=type(e).__name__, status="error", error_code="SYNC_FAILED", last_attempt_at=datetime.now(timezone.utc).isoformat())
        log.error("sync failed (%s)", type(e).__name__)
        raise
    done = datetime.now(timezone.utc).isoformat()
    # A successful sync is "up to date" once Plaid says the full history is loaded (webhook flag) or the Item is no longer new.
    # Before that, the first pass only returns recent days, so the honest state is "syncing your history".
    created = conn.get("created_at")
    old_enough = True
    if created:
        try:
            old_enough = datetime.now(timezone.utc) - datetime.fromisoformat(str(created).replace("Z", "+00:00")) > timedelta(minutes=15)
        except ValueError:
            old_enough = True
    try:                                   # the HISTORICAL_UPDATE webhook may have finished while this long first pass was running
        fresh = bool(rest().select("connections", id=f"eq.{conn['id']}", select="historical_complete")[0].get("historical_complete"))
    except Exception:
        fresh = False
    complete = bool(conn.get("historical_complete")) or fresh or old_enough
    mark(conn["id"], sync_state="ok" if complete else "syncing", last_error=None, status="active", error_code=None, last_synced_at=done,
         last_attempt_at=done, initial_complete=True, historical_complete=complete or bool(conn.get("historical_complete")), last_added=counts.get("added", 0))
    return counts

def _sync_pages(conn: dict, prov: BankProvider | None = None) -> dict:
    """Pull /transactions/sync pages, reconcile into the ledger, advance the cursor only after everything persisted.

    Per page: ONE query loads the existing rows around the page's time range plus rows matching its Plaid ids, every candidate is reconciled
    in memory against that pool (later candidates see earlier ones), new rows go in with one bulk insert, and updates are flushed in order.
    (It used to issue 3-4 queries per transaction, which timed out on a 12-month first sync.)"""
    import uuid
    prov = prov or provider()
    user_id = conn["user_id"]
    token = rest().rpc("tick_vault_get", {"secret_id": conn["vault_secret_id"]})
    if not token:
        raise HTTPException(500, "missing token")
    cursor = start_cursor = conn.get("cursor")
    restarts = 0
    name_to_id, id_to_name = store.category_maps(user_id)
    rules = store.learned_rules(user_id)
    ensure_expected_paycheck(user_id)
    expected = rest().select("expected", user_id=f"eq.{user_id}", status="eq.expected", select="id,amount_cents,expected_date")
    counts = {"added": 0, "modified": 0, "removed": 0, "merged": 0}
    uncategorised: dict[str, str] = {}      # merchant -> txn id (inserted this sync, category fell through to Other)
    try:
        accts = _ensure_accounts(user_id, conn["id"], prov.accounts(token), conn.get("institution"))
        if "liabilities" in (conn.get("products") or []):
            try:
                apply_liabilities(user_id, prov.liabilities(token), accts)
            except PlaidError:
                pass                                      # cards still show owed, limit and utilisation from /accounts/get
        while True:
            try:
                page = prov.sync_page(token, cursor)
            except PlaidError as e:
                if e.code == MUTATION and restarts < 3:
                    restarts += 1
                    cursor = start_cursor                  # the data changed under us mid-pagination: start the page set over (rows are idempotent)
                    continue
                raise
            items = page.get("added", []) + page.get("modified", [])
            cands = [plaid_candidate(t, accts, rules, name_to_id) for t in items]
            with store.user_lock(user_id):
                pool: dict[str, object] = {}
                if cands:
                    lo = min(c.occurred_at for c, _ in cands)
                    hi = max(c.occurred_at for c, _ in cands)
                    ids = [i for c, _ in cands for i in (c.plaid_transaction_id, c.plaid_pending_id) if i]
                    for t in store.window_range(user_id, lo, hi) + store.by_plaid_ids(user_id, ids):
                        pool[t.id] = t
                txns = list(pool.values())
                inserts: list[dict] = []
                for cand, tags in cands:
                    new_id = str(uuid.uuid4())
                    actions = plan_and_apply(txns, cand, new_id, category_names=id_to_name)
                    first = actions[0]
                    for a in actions:
                        if a.kind == "insert":
                            row = {k: store.ser(v) for k, v in a.fields.items()}
                            row.update({"id": a.txn_id, "user_id": user_id})
                            if tags:
                                row["tags"] = tags
                            inserts.append(row)
                        else:
                            _flush(inserts)                       # an update may target a row inserted earlier in this page
                            store.persist(user_id, a)
                    counts["merged" if first.kind == "update" and first.reason == "heuristic" else ("added" if first.kind == "insert" else "modified")] += 1
                    if actions[-1].kind == "insert":
                        if cand.category_id == name_to_id.get("Other") and cand.amount_cents < 0:
                            uncategorised[cand.merchant_clean or cand.merchant_raw] = new_id
                _flush(inserts)
                # Landed matching after rows exist (matched_transaction_id is a foreign key).
                for cand, _ in cands:
                    row = next((t for t in txns if getattr(t, "plaid_transaction_id", None) == cand.plaid_transaction_id), None)
                    if row is not None and cand.amount_cents > 0 and _is_income_deposit(cand, accts):
                        _landed_in(expected, user_id, row.id, cand.amount_cents, cand.occurred_at)
            rem = [r["transaction_id"] for r in page.get("removed", [])]
            if rem:
                gone = store.by_plaid_ids(user_id, rem)
                for a in apply_plaid_removed(gone, rem):
                    store.persist(user_id, a)
                    counts["removed"] += 1
            cursor = page["next_cursor"]
            if not page.get("has_more"):
                break
        _ai_categorise(user_id, uncategorised, name_to_id)
        try:
            pair_transfers(user_id)
            rules_mod.apply(user_id)                      # after pairing, before anything reads a category
            paybacks.auto_link(user_id)
        except Exception:
            pass                                          # pairing is re-run on the next sync; never block the cursor
        rest().update("connections", {"id": conn["id"]}, {"cursor": cursor})          # only after EVERY page of the set persisted
    except Exception:
        counts["failed"] = True
        raise
    return counts

def _ai_categorise(user_id: str, items: dict[str, str], name_to_id: dict[str, str]) -> None:
    """Rules first; whatever is left from this sync goes to the model in ONE batched call (free models, cached per merchant)."""
    if not items:
        return
    try:
        res = ai.categorize_batch(user_id, list(items), [n for n in name_to_id if n not in ("Income", "Transfer", "Other")])
        for m, (clean, cat) in res.items():
            tid = items.get(m)
            cid = name_to_id.get(cat)
            if tid and cid:
                row = rest().select("transactions", id=f"eq.{tid}", select="user_edited")
                if row and "category" not in (row[0].get("user_edited") or []):
                    rest().update("transactions", {"id": tid}, {"category_id": cid, "merchant_clean": clean})
    except Exception:
        pass

# ---------------- routes ----------------
class LinkTokenBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    accounts: bool = False             # update mode with account selection ("Some accounts not shared")
    connection_id: str | None = Field(default=None, pattern=r"^[0-9a-f\-]{36}$")   # set for update mode (re-link)

@router.get("/plaid/links")
def links(user_id: str = Depends(current_user)):
    """`used`/`cap`/`left` are this user's own count; `total_left` is what really limits a new link: Plaid's cap is shared by everyone.
    `can_link` is false for anyone who is not the owner, so the app shows no counter and no Link button for them."""
    used = links_used(user_id)
    total_left = max(0, ITEM_CAP - total_links_used())
    return {"used": used, "cap": ITEM_CAP, "left": max(0, ITEM_CAP - used), "can_link": can_link(user_id), "total_left": total_left}

@router.post("/plaid/link-token")
def link_token(body: LinkTokenBody, user_id: str = Depends(current_user)):
    token = None
    if body.connection_id:
        rows = rest().select("connections", id=f"eq.{body.connection_id}", user_id=f"eq.{user_id}")
        if not rows:
            raise HTTPException(404, "connection not found")
        token = rest().rpc("tick_vault_get", {"secret_id": rows[0]["vault_secret_id"]})
    else:
        require_link_owner(user_id)
        if links_used(user_id) >= ITEM_CAP or total_links_used() >= ITEM_CAP:
            raise HTTPException(409, LINK_LIMITED)
        # One open new-bank session at a time: re-opening the sheet reuses it, so parallel sessions can't each burn a slot.
        since = (datetime.now(timezone.utc) - timedelta(minutes=OPEN_SESSION_MIN)).isoformat()
        open_ = rest().select("plaid_link_sessions", user_id=f"eq.{user_id}", connection_id="is.null", finished_at="is.null",
                              created_at=f"gte.{since}", select="link_token,hosted_link_url", order="created_at.desc")
        if open_ and open_[0].get("hosted_link_url"):
            return {"link_token": open_[0]["link_token"], "hosted_link_url": open_[0]["hosted_link_url"], "links_left": link_slots_left(user_id)}
    user_limiter.check(f"linktoken:{user_id}", 6, 60)
    try:
        r = provider().create_link_token(user_id, access_token=token, accounts=body.accounts)
    except PlaidError as e:
        raise HTTPException(502, f"Bank link unavailable ({e.code})")
    # Remember who this link token belongs to: SESSION_FINISHED carries only the link_token.
    rest().insert("plaid_link_sessions", {"link_token": r["link_token"], "user_id": user_id, "connection_id": body.connection_id,
                                          "hosted_link_url": r.get("hosted_link_url")}, upsert_on="link_token")
    return {"link_token": r["link_token"], "hosted_link_url": r.get("hosted_link_url"), "links_left": link_slots_left(user_id)}

class CompleteBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    link_token: str = Field(min_length=10, max_length=120, pattern=r"^link-(sandbox|development|production)-[A-Za-z0-9\-]+$")

CLAIM_STALE_S = 120          # a finisher that crashed mid-way releases its claim after two minutes
WAIT_FOR_OTHER_S = 12.0      # the losing finisher waits this long for the winner's result

def _claim(link_token_value: str, now: datetime | None = None) -> bool:
    """Atomic compare-and-set on the link session: exactly one caller (webhook or app) gets True."""
    now = now or datetime.now(timezone.utc)
    stale = (now - timedelta(seconds=CLAIM_STALE_S)).isoformat()
    rows = rest().update("plaid_link_sessions", {"link_token": link_token_value}, {"claimed_at": now.isoformat()},
                         where={"finished_at": "is.null", "or": f"(claimed_at.is.null,claimed_at.lt.{stale})"})
    return bool(rows)

def _session_connections(link_token_value: str) -> list[dict] | None:
    """The result a finished session recorded, or None while it is still in progress."""
    sess = _session_for_link_token(link_token_value)
    if not sess or not sess.get("finished_at"):
        return None
    ids = sess.get("connection_ids") or []
    return [c for i in ids for c in rest().select("connections", id=f"eq.{i}")]

def finish_link(user_id: str, link_token_value: str, *, sync_now: bool = True, prov: BankProvider | None = None,
                wait_s: float = WAIT_FOR_OTHER_S) -> list[dict]:
    """Exchange the session's public token(s) and create connections. Idempotent and race-safe:
    - the session is claimed atomically first; a second caller waits for the first one's result and returns the SAME rows;
    - an item_id that already has a connection is returned as is (no second slot, no second Vault entry);
    - the slot counter is the set of item_ids, so even a double exchange counts once."""
    prov = prov or provider()
    if not _claim(link_token_value):
        deadline = time.monotonic() + wait_s
        while True:
            done = _session_connections(link_token_value)
            if done is not None:
                return done
            if time.monotonic() >= deadline:
                return []                                          # still running elsewhere; the app sees it arrive through Realtime
            time.sleep(0.4)
    created: list[dict] = []
    try:
        for pt in prov.link_token_result(link_token_value):
            access, item_id = prov.exchange(pt)
            existing = rest().select("connections", item_id=f"eq.{item_id}", provider="eq.plaid")
            if existing:
                record_item(existing[0]["user_id"], item_id, existing[0].get("institution"), link_token_value)
                created.append(existing[0])
                continue
            inst = prov.item_institution(access) if hasattr(prov, "item_institution") else None
            products = prov.item_products(access) if hasattr(prov, "item_products") else ["transactions"]
            record_item(user_id, item_id, inst, link_token_value)
            sid = rest().rpc("tick_vault_upsert", {"secret_name": f"plaid-{item_id}", "secret_value": access})
            try:
                conn = rest().insert("connections", {"user_id": user_id, "provider": "plaid", "institution": inst, "item_id": item_id,
                                                     "vault_secret_id": sid, "status": "active", "products": products})[0]
            except httpx.HTTPStatusError as e:
                if e.response.status_code != 409:
                    raise
                conn = rest().select("connections", item_id=f"eq.{item_id}", provider="eq.plaid")[0]
            audit(user_id, "bank_linked", {"institution": inst})
            if sync_now:
                sync_connection(conn, prov)
            created.append({**conn, "_new": True})          # only the finisher that created it schedules the first sync
    except Exception:
        rest().update("plaid_link_sessions", {"link_token": link_token_value}, {"claimed_at": None})     # let a retry try again
        raise
    rest().update("plaid_link_sessions", {"link_token": link_token_value},
                  {"finished_at": datetime.now(timezone.utc).isoformat(), "connection_ids": [c["id"] for c in created]})
    return created

@router.post("/plaid/complete")
def complete(body: CompleteBody, background: BackgroundTasks, user_id: str = Depends(current_user)):
    """Exchange the public token and create the connection, then run the first sync (up to 12 months) in the BACKGROUND so the app gets an
    answer in a couple of seconds. The app sees rows arrive through Realtime and the connection's last_synced_at."""
    user_limiter.check(f"link:{user_id}", 5, 60)
    sess = _session_for_link_token(body.link_token)
    if not sess:
        raise HTTPException(404, "link session not found")
    if sess["user_id"] != user_id:
        raise HTTPException(403, "not your link session")
    try:
        created = finish_link(user_id, body.link_token, sync_now=False)
    except PlaidError as e:
        raise HTTPException(502, f"Bank link unavailable ({e.code})")
    for conn in created:
        if conn.pop("_new", False):
            background.add_task(_safe_sync, conn)
    return {"connections": [c["id"] for c in created], "syncing": bool(created), **links(user_id)}

@router.post("/plaid/sync/{connection_id}")
def sync_one(connection_id: str, background: BackgroundTasks, user_id: str = Depends(current_user)):
    user_limiter.check(f"sync:{user_id}", 6, 60)
    rows = rest().select("connections", id=f"eq.{connection_id}", user_id=f"eq.{user_id}")
    if not rows:
        raise HTTPException(404, "connection not found")
    conn = rows[0]
    mark(conn["id"], sync_state="syncing" if conn.get("sync_state") not in ("login_required",) else "login_required",
         sync_started_at=datetime.now(timezone.utc).isoformat())
    background.add_task(_safe_sync, conn, True)            # a real sync, after asking the bank for fresh data; the app sees it through Realtime
    return {"syncing": True}

@router.post("/webhooks/plaid")
async def plaid_webhook(request: Request, background: BackgroundTasks, plaid_verification: str = Header(default="")):
    """Verify, then do the work in the background: Plaid expects an answer within seconds and retries slow ones."""
    body = await request.body()
    # Verification and the lookups below are blocking network calls: run them in the threadpool, never on the event loop.
    return await run_in_threadpool(_handle_webhook, body, plaid_verification, background)

def _handle_webhook(body: bytes, plaid_verification: str, background: BackgroundTasks) -> dict:
    verify_webhook(body, plaid_verification)
    ev = json.loads(body)
    typ, code, item_id = ev.get("webhook_type"), ev.get("webhook_code"), ev.get("item_id")
    conns = rest().select("connections", item_id=f"eq.{item_id}") if item_id else []
    if conns:
        conn = conns[0]
        fields: dict = {"last_webhook_code": f"{typ}:{code}", "last_webhook_at": datetime.now(timezone.utc).isoformat()}
        if typ == "TRANSACTIONS":
            if code == "INITIAL_UPDATE":
                fields["initial_complete"] = True
            if code == "HISTORICAL_UPDATE":
                fields["historical_complete"] = True
            if "historical_update_complete" in ev:
                fields["historical_complete"] = bool(ev["historical_update_complete"])
            if "initial_update_complete" in ev:
                fields["initial_complete"] = bool(ev["initial_update_complete"])
            if "historical_complete" in fields:
                conn["historical_complete"] = fields["historical_complete"]
            mark(conn["id"], **fields)
            if code in ("SYNC_UPDATES_AVAILABLE", "INITIAL_UPDATE", "HISTORICAL_UPDATE", "DEFAULT_UPDATE", "TRANSACTIONS_REMOVED"):
                background.add_task(_safe_sync, conn)
        elif typ == "ITEM":
            err = (ev.get("error") or {}).get("error_code") or code
            if code == "ERROR":
                st = state_for_error(err)
                mark(conn["id"], **fields, sync_state=st, last_error=err, status="login_required" if st == "login_required" else "error", error_code=err)
            elif code in ("PENDING_EXPIRATION", "PENDING_DISCONNECT", "USER_PERMISSION_REVOKED", "USER_ACCOUNT_REVOKED"):
                mark(conn["id"], **fields, sync_state="login_required", last_error=code, status="login_required", error_code=code)
            elif code == "NEW_ACCOUNTS_AVAILABLE":
                mark(conn["id"], **fields, sync_state="partial", last_error=code)        # more accounts can be shared: Fix -> update mode
            elif code == "LOGIN_REPAIRED":
                mark(conn["id"], **fields, sync_state="syncing", last_error=None, status="active", error_code=None)
                background.add_task(_safe_sync, conn)
            else:                                                                       # WEBHOOK_UPDATE_ACKNOWLEDGED and friends
                mark(conn["id"], **fields)
        elif typ == "LIABILITIES":
            mark(conn["id"], **fields)
            background.add_task(_safe_sync, conn)                                       # refreshes balances, due dates and statements too
        else:
            mark(conn["id"], **fields)
    if typ == "LINK" and code == "SESSION_FINISHED" and ev.get("status") == "success":
        lt = ev.get("link_token")
        sess = _session_for_link_token(lt)
        if sess and not sess.get("connection_id"):
            for conn in finish_link(sess["user_id"], lt, sync_now=False, wait_s=0):
                if conn.pop("_new", False):
                    background.add_task(_safe_sync, conn)
        elif sess and sess.get("connection_id"):
            cs = rest().select("connections", id=f"eq.{sess['connection_id']}")
            if cs:
                mark(cs[0]["id"], sync_state="syncing", last_error=None, status="active", error_code=None)
                background.add_task(_safe_sync, cs[0])                       # update mode finished: same Item, just sync
    return {"ok": True}

def _safe_sync(conn: dict, refresh: bool = False) -> None:
    """Background sync that never raises and always leaves an honest state behind (sync_connection records it)."""
    try:
        if refresh and conn.get("vault_secret_id") and os.environ.get("PLAID_REFRESH", "1") != "0":
            try:
                token = rest().rpc("tick_vault_get", {"secret_id": conn["vault_secret_id"]})
                if token:
                    provider().refresh(token)                                  # type: ignore[attr-defined]
            except Exception:
                pass                                                           # not allowed or rate limited: sync what we already can
        sync_connection(conn)
    except Exception:
        pass                                                                   # state already recorded by sync_connection

def _session_for_link_token(lt: str | None) -> dict | None:
    """SESSION_FINISHED carries only the link_token, so the owner is looked up from the session stored when the token was created."""
    if not lt:
        return None
    rows = rest().select("plaid_link_sessions", link_token=f"eq.{lt}")
    return rows[0] if rows else None

@router.get("/plaid/oauth-return", response_class=HTMLResponse)
def oauth_return():
    """Blank page to register under Allowed redirect URIs in the Plaid dashboard (only needed if PLAID_REDIRECT_URI is set)."""
    return "<!doctype html><meta charset=utf-8><title>tick</title><body style='background:#0E0E12;color:#F5F3EC;font-family:system-ui;display:grid;place-items:center;height:100vh'>Returning to Tick..."

@router.post("/jobs/sync-all", dependencies=[Depends(require_cron)])
def sync_all(background: BackgroundTasks, stuck: bool = False):
    """Safety net next to webhooks. Every 6 hours: every connection. Every 10 minutes (`?stuck=true`): only connections that are
    not up to date and were last tried more than 10 minutes ago (webhooks missed, a sync that crashed, a bank that came back).
    Connections that need a person (login_required, partial) are left alone. Returns at once; syncs run one after another."""
    conns = [c for c in rest().select("connections", provider="eq.plaid", status="neq.removed") if c.get("vault_secret_id")]
    if stuck:
        cutoff = datetime.now(timezone.utc) - timedelta(minutes=10)
        def due(c: dict) -> bool:
            if c.get("sync_state") in ("ok", "login_required", "partial"):
                return False
            at = c.get("last_attempt_at")
            return not at or datetime.fromisoformat(at.replace("Z", "+00:00")) < cutoff
        conns = [c for c in conns if due(c)]
    else:
        conns = [c for c in conns if c.get("sync_state") != "login_required"]
    for c in conns:
        background.add_task(_safe_sync, c)
    return {"queued": len(conns)}
