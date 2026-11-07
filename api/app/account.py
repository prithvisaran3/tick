"""Account-level security actions: capture tokens (mint once, list, revoke), the panic button, and "Delete all my data".

Capture tokens: the server generates 32 random bytes, returns the token ONCE and stores only its SHA-256. Scope is 'ingest' (the only
route that accepts X-Tick-Token). Every create, revoke, panic, bank removal and deletion is written to the append-only audit_log."""
from __future__ import annotations

import base64
import logging
import secrets

import httpx
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, ConfigDict, Field

from . import auth
from .audit import audit
from .auth import current_user, hash_token, user_limiter
from .config import settings
from .db import rest

router = APIRouter()
log = logging.getLogger("tick.account")

# Rows that belong to the user and go away on "Delete all my data". plaid_items (the lifetime slot counter) and audit_log stay:
# neither holds financial data, and removing an Item never returns its slot anyway.
USER_TABLES = ["messages", "chats", "insights", "expected", "recurring", "ingest_logs", "transactions", "rules", "budgets", "goals", "people",
               "snapshots", "ai_usage", "paydays", "accounts", "connections", "plaid_link_sessions", "ingest_tokens", "categories", "plaid_slots"]

def mint_token() -> str:
    return "tk_" + base64.urlsafe_b64encode(secrets.token_bytes(32)).decode().rstrip("=")

class TokenBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    label: str = Field(default="Shortcuts", min_length=1, max_length=40)
    replace: bool = True          # rotate: revoke every older token in the same step

@router.post("/tokens")
def create_token(body: TokenBody, user_id: str = Depends(current_user)):
    user_limiter.check(f"tokens:{user_id}", 5, 60)
    if body.replace:
        _revoke_all(user_id)
    token = mint_token()
    rest().insert("ingest_tokens", {"user_id": user_id, "token_hash": hash_token(token), "last4": token[-4:], "label": body.label, "scope": "ingest"},
                  returning=False)
    audit(user_id, "token_created", {"token_last4": token[-4:], "scope": "ingest"})
    return {"token": token, "last4": token[-4:], "scope": "ingest", "note": "Shown once. Tick stores only a hash."}

@router.get("/tokens")
def list_tokens(user_id: str = Depends(current_user)):
    rows = rest().select("ingest_tokens", user_id=f"eq.{user_id}", select="id,last4,label,scope,created_at,last_used_at,revoked_at", order="created_at.desc")
    return {"tokens": rows}

@router.post("/tokens/{token_id}/revoke")
def revoke_token(token_id: str, user_id: str = Depends(current_user)):
    rows = rest().update("ingest_tokens", {"id": token_id, "user_id": user_id}, {"revoked_at": "now()"}, where={"revoked_at": "is.null"})
    if not rows:
        if rest().select("ingest_tokens", id=f"eq.{token_id}", user_id=f"eq.{user_id}", select="id"):
            return {"revoked": True}                                     # already revoked: revoked tokens stay revoked
        raise HTTPException(404, "token not found")
    auth.forget_tokens(user_id)
    audit(user_id, "token_revoked", {"token_last4": rows[0].get("last4")})
    return {"revoked": True}

def _revoke_all(user_id: str) -> int:
    rows = rest().update("ingest_tokens", {"user_id": user_id}, {"revoked_at": "now()"}, where={"revoked_at": "is.null"})
    auth.forget_tokens(user_id)
    return len(rows)

@router.post("/security/panic")
def panic(user_id: str = Depends(current_user)):
    """Revoke every capture token now. The app then signs out EVERY session (Supabase global sign-out) and shows how to revoke
    Plaid access. Bank links are kept (removing them never returns a slot); see /me/delete for that."""
    user_limiter.check(f"panic:{user_id}", 5, 60)
    n = _revoke_all(user_id)
    audit(user_id, "tokens_revoked_all", {"count": n})
    audit(user_id, "sessions_revoked", {"scope": "global"})
    return {"tokens_revoked": n, "sign_out": "global",
            "plaid": "To cut Plaid's access too, open my.plaid.com, sign in with your phone number and remove Tick, or use Delete all my data."}

class DeleteBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    confirm: str = Field(pattern="^DELETE$")          # the app sends this only after the hold-to-confirm

@router.post("/me/delete")
def delete_everything(body: DeleteBody, user_id: str = Depends(current_user)):
    """Delete all my data: remove every Plaid Item (Plaid /item/remove), delete the Vault tokens, every row and every receipt photo.
    Removing an Item NEVER returns its lifetime slot (Plaid Trial cap). Only ever triggered by the person, never automatically."""
    user_limiter.check(f"delete:{user_id}", 3, 300)
    from .plaid import PlaidError, provider
    removed, failed = 0, 0
    keep: list[str] = []            # connections whose Item could not be removed: kept (status removed) with their Vault token
    for c in rest().select("connections", user_id=f"eq.{user_id}", provider="eq.plaid"):
        if not c.get("vault_secret_id"):
            continue
        try:
            token = rest().rpc("tick_vault_get", {"secret_id": c["vault_secret_id"]})
            if token:
                provider().remove_item(token)                              # type: ignore[attr-defined]
            rest().rpc("tick_vault_delete", {"secret_id": c["vault_secret_id"]})
            removed += 1
            audit(user_id, "plaid_item_removed", {"institution": c.get("institution")})
            if c.get("item_id"):
                rest().update("plaid_items", {"item_id": c["item_id"]}, {"removed_at": "now()"})
        except (PlaidError, httpx.HTTPError):
            failed += 1                                                    # keep going, but never orphan a live token
            keep.append(c["id"])
    receipts = _delete_receipts(user_id)
    for t in USER_TABLES:
        try:
            if t == "connections" and keep:
                for c in rest().select("connections", user_id=f"eq.{user_id}", select="id"):
                    if c["id"] in keep:
                        rest().update("connections", {"id": c["id"], "user_id": user_id}, {"status": "removed", "error_code": "REMOVE_PENDING"})
                    else:
                        rest().delete("connections", {"id": c["id"], "user_id": user_id})
                continue
            rest().delete(t, {"user_id": user_id})
        except httpx.HTTPError:
            log.warning("delete-all: could not clear a table")
    for t, blank in (("profiles", {"display_name": None, "email": None}), ("settings", {"payday_rule": None, "onboarding_done": False})):
        try:
            rest().update(t, {"user_id": user_id}, blank)
        except httpx.HTTPError:
            pass
    try:
        rest().rpc("seed_default_categories", {"uid": user_id})          # a clean, usable account remains
    except httpx.HTTPError:
        pass
    auth.forget_tokens(user_id)
    audit(user_id, "data_deleted", {"count": removed})
    return {"deleted": True, "banks_removed": removed, "banks_failed": failed, "receipts_deleted": receipts}

def _delete_receipts(user_id: str) -> int:
    s = settings()
    base = s.supabase_url.rstrip("/") + "/storage/v1/object"
    h = {"apikey": s.supabase_secret_key, "Authorization": f"Bearer {s.supabase_secret_key}", "Content-Type": "application/json"}
    try:
        total = 0
        for _ in range(100):                                        # pages of 1000; each pass deletes what it listed
            r = httpx.post(f"{base}/list/receipts", headers=h, json={"prefix": f"{user_id}/", "limit": 1000, "offset": 0}, timeout=20)
            names = [f"{user_id}/{o['name']}" for o in (r.json() if r.status_code == 200 else []) if o.get("name")]
            if not names:
                break
            httpx.request("DELETE", f"{base}/receipts", headers=h, json={"prefixes": names}, timeout=20)
            total += len(names)
        return total
    except (httpx.HTTPError, ValueError):
        return 0
