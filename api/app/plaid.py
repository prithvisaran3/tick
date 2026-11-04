"""Plaid integration behind a BankProvider interface. Access tokens never leave the server: they live in Supabase Vault and are referenced by id.

HARD CAP: 10 Items ever (Plaid Trial plan). Removing an Item does NOT free a slot, so the lifetime counter lives in plaid_slots.
NEVER create or remove production Items automatically or in tests: Items are only created from the user's explicit Link flow."""
from __future__ import annotations

import hashlib
import json
import time
from abc import ABC, abstractmethod
from datetime import datetime, timedelta, timezone
from typing import Any

import httpx
import jwt
from cryptography.hazmat.primitives.asymmetric.ec import EllipticCurvePublicNumbers, SECP256R1
from fastapi import APIRouter, Depends, Header, HTTPException, Request
from pydantic import BaseModel

from . import store
from .auth import current_user, require_cron
from .config import settings
from .db import rest
from .merchants import categorize, clean_merchant, looks_business
from .reconcile import Candidate, apply_plaid_removed, plan

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
        if access_token:
            body["access_token"] = access_token          # update mode: re-authenticate the SAME Item, never a new one
        else:
            body["products"] = ["transactions"]
            body["transactions"] = {"days_requested": 365}
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
MAX_AGE = 300

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
        try:
            key = prov.webhook_key(kid)  # type: ignore[union-attr]
        except PlaidError:
            raise HTTPException(401, "unknown key")
        _keys[kid] = (time.time() + 3600, key)
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
def slots_used(user_id: str) -> int:
    rows = rest().select("plaid_slots", user_id=f"eq.{user_id}")
    n_rows = len(rest().select("connections", user_id=f"eq.{user_id}", provider="eq.plaid", select="id"))
    return max(rows[0]["used"] if rows else 0, n_rows)

def take_slot(user_id: str) -> None:
    used = slots_used(user_id)
    if used >= ITEM_CAP:
        raise HTTPException(409, "You have used all 10 bank links.")
    rest().insert("plaid_slots", {"user_id": user_id, "used": used + 1}, upsert_on="user_id")

# ---------------- mapping ----------------
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
    pfc = (t.get("personal_finance_category") or {}).get("primary", "")
    if pfc in ("TRANSFER_IN", "TRANSFER_OUT", "LOAN_PAYMENTS") :
        cat = "Transfer"
    elif cents > 0:
        cat = "Income"
    else:
        cat, _ = categorize(clean or raw, rules)
    acct = acct_by_pid.get(t["account_id"], {})
    tags = ["business"] if cents < 0 and looks_business(clean or raw) else []
    c = Candidate("plaid", t["transaction_id"], cents, occurred, raw, clean, acct.get("mask"), "pending" if t.get("pending") else "posted",
                  plaid_transaction_id=t["transaction_id"], plaid_pending_id=t.get("pending_transaction_id"), confidence=1.0,
                  account_id=acct.get("id"), category_id=name_to_id.get(cat), time_precise=precise)
    return c, tags

def _ensure_accounts(user_id: str, conn_id: str, accts: list[dict]) -> dict[str, dict]:
    out: dict[str, dict] = {}
    for a in accts:
        b = a.get("balances") or {}
        typ = {"depository": "checking", "credit": "credit", "investment": "other", "loan": "other"}.get(a.get("type"), "other")
        if a.get("subtype") == "savings":
            typ = "savings"
        cur, avail = b.get("current"), b.get("available")
        # Credit: current balance is what you owe -> negative cents.
        bal = None if cur is None else (-round(cur * 100) if typ == "credit" else round(cur * 100))
        av = None if avail is None else round(avail * 100)
        row = {"user_id": user_id, "connection_id": conn_id, "provider_account_id": a["account_id"], "name": a.get("name") or "Account", "mask": a.get("mask"),
               "type": typ, "balance_cents": bal, "available_cents": av, "include_in_safe": typ != "savings"}
        saved = rest().insert("accounts", row, upsert_on="user_id,provider_account_id")[0]
        out[a["account_id"]] = saved
    return out

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

def sync_connection(conn: dict, prov: BankProvider | None = None) -> dict:
    """Pull /transactions/sync pages, reconcile into the ledger, advance the cursor only after everything persisted."""
    prov = prov or provider()
    user_id = conn["user_id"]
    token = rest().rpc("tick_vault_get", {"secret_id": conn["vault_secret_id"]})
    if not token:
        raise HTTPException(500, "missing token")
    cursor = conn.get("cursor")
    name_to_id, id_to_name = store.category_maps(user_id)
    rules = store.learned_rules(user_id)
    counts = {"added": 0, "modified": 0, "removed": 0, "merged": 0}
    try:
        accts = _ensure_accounts(user_id, conn["id"], prov.accounts(token))
        by_pid = {k: v for k, v in accts.items()}
        while True:
            page = prov.sync_page(token, cursor)
            for t in page.get("added", []) + page.get("modified", []):
                cand, tags = plaid_candidate(t, by_pid, rules, name_to_id)
                with store.user_lock(user_id):
                    pool = {t.id: t for t in store.window(user_id, cand.occurred_at) + store.by_plaid_ids(user_id, [i for i in (cand.plaid_transaction_id, cand.plaid_pending_id) if i])}
                    actions = plan(cand, list(pool.values()), category_names=id_to_name)
                    action = actions[0]
                    tid = None
                    for a in actions:
                        tid = store.persist(user_id, a, {"tags": tags} if a.kind == "insert" and tags else None) or tid
                counts["merged" if action.kind == "update" and action.reason == "heuristic" else ("added" if action.kind == "insert" else "modified")] += 1
                if action.kind == "insert" and tid:
                    _landed(user_id, tid, cand.amount_cents, cand.occurred_at)
            rem = [r["transaction_id"] for r in page.get("removed", [])]
            if rem:
                txns = store.by_plaid_ids(user_id, rem)
                for a in apply_plaid_removed(txns, rem):
                    store.persist(user_id, a)
                    counts["removed"] += 1
            cursor = page["next_cursor"]
            if not page.get("has_more"):
                break
        rest().update("connections", {"id": conn["id"]}, {"cursor": cursor, "last_synced_at": datetime.now(timezone.utc).isoformat(), "status": "active", "error_code": None})
    except PlaidError as e:
        status = "login_required" if e.code in ("ITEM_LOGIN_REQUIRED", "PENDING_EXPIRATION") else "error"
        rest().update("connections", {"id": conn["id"]}, {"status": status, "error_code": e.code})
        counts["error"] = e.code
    return counts

# ---------------- routes ----------------
class LinkTokenBody(BaseModel):
    connection_id: str | None = None   # set for update mode (re-link)

@router.get("/plaid/links")
def links(user_id: str = Depends(current_user)):
    used = slots_used(user_id)
    return {"used": used, "cap": ITEM_CAP, "left": max(0, ITEM_CAP - used)}

@router.post("/plaid/link-token")
def link_token(body: LinkTokenBody, user_id: str = Depends(current_user)):
    token = None
    if body.connection_id:
        rows = rest().select("connections", id=f"eq.{body.connection_id}", user_id=f"eq.{user_id}")
        if not rows:
            raise HTTPException(404, "connection not found")
        token = rest().rpc("tick_vault_get", {"secret_id": rows[0]["vault_secret_id"]})
    elif slots_used(user_id) >= ITEM_CAP:
        raise HTTPException(409, "You have used all 10 bank links.")
    try:
        r = provider().create_link_token(user_id, access_token=token)
    except PlaidError as e:
        raise HTTPException(502, f"Bank link unavailable ({e.code})")
    return {"link_token": r["link_token"], "hosted_link_url": r.get("hosted_link_url"), "links_left": ITEM_CAP - slots_used(user_id)}

class CompleteBody(BaseModel):
    link_token: str

def finish_link(user_id: str, link_token_value: str) -> list[str]:
    prov = provider()
    publics = prov.link_token_result(link_token_value)
    ids: list[str] = []
    for pt in publics:
        access, item_id = prov.exchange(pt)
        if rest().select("connections", item_id=f"eq.{item_id}", select="id"):
            continue                                                        # webhook + app both finished the same session
        take_slot(user_id)
        sid = rest().rpc("tick_vault_put", {"secret_name": f"plaid-{item_id}", "secret_value": access})
        inst = prov.item_institution(access) if hasattr(prov, "item_institution") else None
        conn = rest().insert("connections", {"user_id": user_id, "provider": "plaid", "institution": inst, "item_id": item_id, "vault_secret_id": sid, "status": "active"})[0]
        sync_connection(conn, prov)
        ids.append(conn["id"])
    return ids

@router.post("/plaid/complete")
def complete(body: CompleteBody, user_id: str = Depends(current_user)):
    try:
        ids = finish_link(user_id, body.link_token)
    except PlaidError as e:
        raise HTTPException(502, f"Bank link unavailable ({e.code})")
    return {"connections": ids, **links(user_id)}

@router.post("/plaid/sync/{connection_id}")
def sync_one(connection_id: str, user_id: str = Depends(current_user)):
    rows = rest().select("connections", id=f"eq.{connection_id}", user_id=f"eq.{user_id}")
    if not rows:
        raise HTTPException(404, "connection not found")
    return sync_connection(rows[0])

@router.post("/webhooks/plaid")
async def plaid_webhook(request: Request, plaid_verification: str = Header(default="")):
    body = await request.body()
    verify_webhook(body, plaid_verification)
    ev = json.loads(body)
    typ, code, item_id = ev.get("webhook_type"), ev.get("webhook_code"), ev.get("item_id")
    conns = rest().select("connections", item_id=f"eq.{item_id}") if item_id else []
    if typ == "TRANSACTIONS" and code in ("SYNC_UPDATES_AVAILABLE", "INITIAL_UPDATE", "HISTORICAL_UPDATE", "DEFAULT_UPDATE") and conns:
        sync_connection(conns[0])
    elif typ == "ITEM" and conns:
        if code == "ERROR":
            err = (ev.get("error") or {}).get("error_code", "ERROR")
            rest().update("connections", {"id": conns[0]["id"]}, {"status": "login_required" if err == "ITEM_LOGIN_REQUIRED" else "error", "error_code": err})
        elif code in ("PENDING_EXPIRATION", "PENDING_DISCONNECT", "USER_PERMISSION_REVOKED"):
            rest().update("connections", {"id": conns[0]["id"]}, {"status": "login_required", "error_code": code})
        elif code == "LOGIN_REPAIRED":
            rest().update("connections", {"id": conns[0]["id"]}, {"status": "active", "error_code": None})
            sync_connection(conns[0])
    elif typ == "LINK" and code == "SESSION_FINISHED" and ev.get("status") == "success":
        lt = ev.get("link_token")
        uid = _user_for_link_token(ev)
        if lt and uid:
            finish_link(uid, lt)
    return {"ok": True}

def _user_for_link_token(ev: dict) -> str | None:
    # client_user_id is not in the webhook body; look up by recently created link sessions is not possible, so the app calls /plaid/complete.
    return None

@router.post("/jobs/sync-all", dependencies=[Depends(require_cron)])
def sync_all():
    """pg_cron backstop every 6 hours."""
    conns = rest().select("connections", provider="eq.plaid", status="neq.removed")
    out = {}
    for c in conns:
        if c.get("vault_secret_id"):
            try:
                out[c["id"]] = sync_connection(c)
            except Exception:
                out[c["id"]] = {"error": "failed"}
    return {"synced": len(out)}
