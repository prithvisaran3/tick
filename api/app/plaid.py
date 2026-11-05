"""Plaid integration behind a BankProvider interface. Access tokens never leave the server: they live in Supabase Vault and are referenced by id.

HARD CAP: 10 Items ever (Plaid Trial plan). Removing an Item does NOT free a slot, so the lifetime counter lives in plaid_slots.
NEVER create or remove production Items automatically or in tests: Items are only created from the user's explicit Link flow."""
from __future__ import annotations

import hashlib
import json
import os
import time
from abc import ABC, abstractmethod
from datetime import datetime, timedelta, timezone
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
from .reconcile import Candidate, apply_plaid_removed, plan, plan_and_apply

ITEM_CAP = 10
router = APIRouter()

def base_url(env: str) -> str:
    return {"production": "https://production.plaid.com", "development": "https://development.plaid.com"}.get(env, "https://sandbox.plaid.com")

class BankProvider(ABC):
    @abstractmethod
    def create_link_token(self, user_id: str, *, access_token: str | None = None) -> dict: ...
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

    def create_link_token(self, user_id: str, *, access_token: str | None = None) -> dict:
        body: dict[str, Any] = {"client_name": "Tick", "language": "en", "country_codes": ["US"], "user": {"client_user_id": user_id},
                                "webhook": self.webhook, "hosted_link": {"completion_redirect_uri": "tick://plaid-complete"}}
        redirect = os.environ.get("PLAID_REDIRECT_URI", "")
        if redirect:
            body["redirect_uri"] = redirect          # only after it is registered under Allowed redirect URIs in the Plaid dashboard
        if access_token:
            body["access_token"] = access_token          # update mode: re-authenticate the SAME Item, never a new one
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
            raise HTTPException(429, "too many key lookups")
        _key_fetches.append(now_t)
        try:
            key = prov.webhook_key(kid)  # type: ignore[union-attr]
        except PlaidError:
            _bad_kids[kid] = now_t + 60
            raise HTTPException(401, "unknown key")
        _keys[kid] = (now_t + 3600, key)
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
    if primary == "BANK_FEES" or detailed.startswith("BANK_FEES") or "INTEREST" in detailed or any(k in name for k in _FEE) or (acct_type == "loan" and cents < 0):
        return "Fees and interest", None, []
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

def pair_transfers(user_id: str, days: int = 60) -> int:
    """Mark internal transfers for the last [days] (see transfers.py). Idempotent; never touches rows whose flow the person edited."""
    from . import transfers
    since = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
    raw = rest().select("transactions", user_id=f"eq.{user_id}", occurred_at=f"gte.{since}",
                        select="id,account_id,amount_cents,occurred_at,merchant_clean,merchant_raw,flow,category_id,transfer_pair_id,user_edited")
    _, id_to_name = store.category_maps(user_id)
    types = {a["id"]: a["type"] for a in rest().select("accounts", user_id=f"eq.{user_id}", select="id,type")}
    patches = transfers.pair(transfers.rows_from_db(raw, id_to_name), types)
    transfer_cat = {v: k for k, v in id_to_name.items()}.get("Transfer")
    for tid, patch in patches.items():
        if patch.get("flow") == "transfer" and transfer_cat:
            row = next(r for r in raw if r["id"] == tid)
            if "category" not in (row.get("user_edited") or []):
                patch = {**patch, "category_id": transfer_cat}
        rest().update("transactions", {"id": tid, "user_id": user_id}, patch)
    return len(patches)

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

def _flush(rows: list[dict]) -> None:
    if rows:
        rest().insert("transactions", list(rows), returning=False)          # one bulk insert instead of a request per transaction
        rows.clear()

def sync_connection(conn: dict, prov: BankProvider | None = None) -> dict:
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
    cursor = conn.get("cursor")
    name_to_id, id_to_name = store.category_maps(user_id)
    rules = store.learned_rules(user_id)
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
            page = prov.sync_page(token, cursor)
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
                    if row is not None and cand.amount_cents > 0:
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
        except Exception:
            pass                                          # pairing is re-run on the next sync; never block the cursor
        rest().update("connections", {"id": conn["id"]}, {"cursor": cursor, "last_synced_at": datetime.now(timezone.utc).isoformat(), "status": "active", "error_code": None})
    except PlaidError as e:
        status = "login_required" if e.code in ("ITEM_LOGIN_REQUIRED", "PENDING_EXPIRATION") else "error"
        rest().update("connections", {"id": conn["id"]}, {"status": status, "error_code": e.code})
        counts["error"] = e.code
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
    connection_id: str | None = Field(default=None, pattern=r"^[0-9a-f\-]{36}$")   # set for update mode (re-link)

@router.get("/plaid/links")
def links(user_id: str = Depends(current_user)):
    used = links_used(user_id)
    return {"used": used, "cap": ITEM_CAP, "left": max(0, ITEM_CAP - used)}

@router.post("/plaid/link-token")
def link_token(body: LinkTokenBody, user_id: str = Depends(current_user)):
    token = None
    if body.connection_id:
        rows = rest().select("connections", id=f"eq.{body.connection_id}", user_id=f"eq.{user_id}")
        if not rows:
            raise HTTPException(404, "connection not found")
        token = rest().rpc("tick_vault_get", {"secret_id": rows[0]["vault_secret_id"]})
    elif links_used(user_id) >= ITEM_CAP:
        raise HTTPException(409, "You have used all 10 bank links.")
    user_limiter.check(f"linktoken:{user_id}", 6, 60)
    try:
        r = provider().create_link_token(user_id, access_token=token)
    except PlaidError as e:
        raise HTTPException(502, f"Bank link unavailable ({e.code})")
    # Remember who this link token belongs to: SESSION_FINISHED carries only the link_token.
    rest().insert("plaid_link_sessions", {"link_token": r["link_token"], "user_id": user_id, "connection_id": body.connection_id}, upsert_on="link_token")
    return {"link_token": r["link_token"], "hosted_link_url": r.get("hosted_link_url"), "links_left": ITEM_CAP - links_used(user_id)}

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
    background.add_task(_safe_sync, rows[0])               # the app sees the result through Realtime
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
    if typ == "TRANSACTIONS" and code in ("SYNC_UPDATES_AVAILABLE", "INITIAL_UPDATE", "HISTORICAL_UPDATE", "DEFAULT_UPDATE") and conns:
        background.add_task(_safe_sync, conns[0])
    elif typ == "ITEM" and conns:
        if code == "ERROR":
            err = (ev.get("error") or {}).get("error_code", "ERROR")
            rest().update("connections", {"id": conns[0]["id"]}, {"status": "login_required" if err == "ITEM_LOGIN_REQUIRED" else "error", "error_code": err})
        elif code in ("PENDING_EXPIRATION", "PENDING_DISCONNECT", "USER_PERMISSION_REVOKED"):
            rest().update("connections", {"id": conns[0]["id"]}, {"status": "login_required", "error_code": code})
        elif code == "LOGIN_REPAIRED":
            rest().update("connections", {"id": conns[0]["id"]}, {"status": "active", "error_code": None})
            background.add_task(_safe_sync, conns[0])
    elif typ == "LINK" and code == "SESSION_FINISHED" and ev.get("status") == "success":
        lt = ev.get("link_token")
        sess = _session_for_link_token(lt)
        if sess and not sess.get("connection_id"):
            for conn in finish_link(sess["user_id"], lt, sync_now=False, wait_s=0):
                if conn.pop("_new", False):
                    background.add_task(_safe_sync, conn)
        elif sess and sess.get("connection_id"):
            cs = rest().select("connections", id=f"eq.{sess['connection_id']}")
            if cs:
                background.add_task(_safe_sync, cs[0])                       # update mode finished: same Item, just sync
    return {"ok": True}

def _safe_sync(conn: dict) -> None:
    try:
        sync_connection(conn)
    except Exception:
        rest().update("connections", {"id": conn["id"]}, {"status": "error", "error_code": "SYNC_FAILED"})

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
def sync_all(background: BackgroundTasks):
    """pg_cron backstop every 6 hours. Returns at once; connections sync one after another in the background."""
    conns = [c for c in rest().select("connections", provider="eq.plaid", status="neq.removed") if c.get("vault_secret_id")]
    for c in conns:
        background.add_task(_safe_sync, c)
    return {"queued": len(conns)}
