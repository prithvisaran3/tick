"""DB glue for reconcile: load the candidate window, persist actions."""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

import threading
from collections import defaultdict

from .db import rest
from .reconcile import Action, Candidate, Txn, WINDOW

def _dt(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00"))

def row_to_txn(r: dict) -> Txn:
    return Txn(id=r["id"], amount_cents=r["amount_cents"], occurred_at=_dt(r["occurred_at"]), merchant_raw=r.get("merchant_raw") or "", merchant_clean=r.get("merchant_clean") or "",
               card_last4=r.get("card_last4"), status=r["status"], sources=r.get("sources") or [], plaid_transaction_id=r.get("plaid_transaction_id"),
               plaid_pending_id=r.get("plaid_pending_id"), confidence=float(r.get("confidence") or 1), needs_review=bool(r.get("needs_review")),
               account_id=r.get("account_id"), category_id=r.get("category_id"), user_edited=set(r.get("user_edited") or []), flow=r.get("flow"))

def window(user_id: str, around: datetime) -> list[Txn]:
    lo, hi = (around - WINDOW).isoformat(), (around + WINDOW).isoformat()
    r = rest().c.get(f"{rest().base}/transactions", headers=rest().h,
                     params=[("user_id", f"eq.{user_id}"), ("occurred_at", f"gte.{lo}"), ("occurred_at", f"lte.{hi}"), ("select", "*")])
    r.raise_for_status()
    rows = r.json()
    return [row_to_txn(r) for r in rows]

def window_range(user_id: str, lo: datetime, hi: datetime) -> list[Txn]:
    """One query covering every candidate of a sync page (candidate time +/- the 72h match window)."""
    r = rest().c.get(f"{rest().base}/transactions", headers=rest().h,
                     params=[("user_id", f"eq.{user_id}"), ("occurred_at", f"gte.{(lo - WINDOW).isoformat()}"), ("occurred_at", f"lte.{(hi + WINDOW).isoformat()}"), ("select", "*"), ("limit", "5000")])
    r.raise_for_status()
    return [row_to_txn(x) for x in r.json()]

def by_plaid_ids(user_id: str, ids: list[str]) -> list[Txn]:
    if not ids:
        return []
    rows = rest().select("transactions", user_id=f"eq.{user_id}", plaid_transaction_id=f"in.({','.join(ids)})", select="*")
    return [row_to_txn(r) for r in rows]

def ser(v):
    return v.isoformat() if isinstance(v, datetime) else v

def persist(user_id: str, a: Action, extra: dict | None = None) -> str | None:
    if a.kind == "noop":
        return a.txn_id
    fields = {k: ser(v) for k, v in a.fields.items()}
    if extra:
        fields.update(extra)
    if a.kind == "insert":
        fields["user_id"] = user_id
        return rest().insert("transactions", fields)[0]["id"]
    if a.kind == "update":
        rest().update("transactions", {"id": a.txn_id, "user_id": user_id}, fields)
        return a.txn_id
    if a.kind == "delete":
        rest().delete("transactions", {"id": a.txn_id, "user_id": user_id})
    return a.txn_id

def category_maps(user_id: str) -> tuple[dict[str, str], dict[str, str]]:
    """(name->id, id->name)"""
    rows = rest().select("categories", user_id=f"eq.{user_id}", select="id,name")
    return {r["name"]: r["id"] for r in rows}, {r["id"]: r["name"] for r in rows}

def learned_rules(user_id: str) -> dict[str, str]:
    """pattern -> category name"""
    rows = rest().select("rules", user_id=f"eq.{user_id}", select="pattern,categories(name)")
    return {r["pattern"]: r["categories"]["name"] for r in rows if r.get("categories")}


_locks: dict[str, threading.Lock] = defaultdict(threading.Lock)

def user_lock(user_id: str) -> threading.Lock:
    """Serialise read-decide-write per user so two near-simultaneous captures (SMS + Apple Pay) cannot both insert. One Railway replica."""
    return _locks[user_id]
