"""Paybacks: when a friend pays me back for something I bought, the purchase should count as my real share (docs/MONEY_RULES.md).

A person-to-person credit that lands within WINDOW_DAYS after a purchase and is no bigger than what is left of it is SUGGESTED as a
reimbursement. Only the person accepts one. The single exception is `auto_link`: a credit that matches an existing Tally settlement exactly
(amount, dates, the friend's name, and exactly one candidate) is linked to that settlement, because the person already recorded it.

`suggest` is pure; the row locks and the "never more than the purchase" rule are in SQL (tick_payback_link)."""
from __future__ import annotations

import re
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import httpx
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, ConfigDict

from .auth import current_user, user_limiter
from .db import rest
from .merchants import clean_merchant
from .transfers import is_p2p

router = APIRouter()
ET = ZoneInfo("America/New_York")
WINDOW_DAYS = 21
MAX_CANDIDATES = 3
SETTLE_BEFORE_DAYS, SETTLE_AFTER_DAYS = 2, 10      # a settlement recorded up to 2 days after, or 10 days before, the money landed
UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
_NOT_A_PERSON = re.compile(r"\b(cash ?out|instant transfer|standard transfer|transfer to bank|add(ed)? money|refund)\b", re.I)
_FROM = re.compile(r"\b(?:from|by)\s+([A-Za-z][A-Za-z'.-]*(?:\s+[A-Za-z][A-Za-z'.-]*){0,3})", re.I)

def _day(s) -> date:
    d = s if isinstance(s, datetime) else datetime.fromisoformat(str(s).replace("Z", "+00:00"))
    return (d if d.tzinfo else d.replace(tzinfo=timezone.utc)).astimezone(ET).date()

def _text(r: dict) -> str:
    return r.get("merchant_raw") or r.get("merchant_clean") or ""

def payer_name(text: str) -> str | None:
    """'Zelle payment from ASWIN KUMAR 3140' -> 'Aswin Kumar'."""
    m = _FROM.search(text or "")
    return m.group(1).strip().title() if m else None

def is_person_credit(r: dict, types: dict[str, str]) -> bool:
    t = _text(r)
    return (r["amount_cents"] > 0 and r.get("flow") is None and is_p2p(t) and not _NOT_A_PERSON.search(t)
            and types.get(r.get("account_id") or "", "checking") not in ("credit", "loan"))

def is_purchase(r: dict, types: dict[str, str]) -> bool:
    return r["amount_cents"] < 0 and r.get("flow") is None and not is_p2p(_text(r)) and types.get(r.get("account_id") or "") != "loan"

def _even_split(total: int, part: int) -> bool:
    n = round(total / part)
    return n >= 2 and abs(total - part * n) <= n          # "half of dinner", give or take the rounding cents

def suggest(rows: list[dict], types: dict[str, str], dismissed: set[str]) -> list[dict]:
    """One entry per credit worth asking about, newest first, each with up to MAX_CANDIDATES purchases, the likeliest first."""
    purchases = [r for r in rows if is_purchase(r, types)]
    out = []
    for c in sorted((r for r in rows if is_person_credit(r, types) and r["id"] not in dismissed), key=lambda r: str(r["occurred_at"]), reverse=True):
        day, found = _day(c["occurred_at"]), []
        for p in purchases:
            gap = (day - _day(p["occurred_at"])).days
            left = -p["amount_cents"] - int(p.get("reimbursed_cents") or 0)
            if 0 <= gap <= WINDOW_DAYS and c["amount_cents"] <= left:
                found.append((not _even_split(left, c["amount_cents"]), gap, p["id"], p, left))
        if not found:
            continue
        found.sort(key=lambda x: x[:3])
        out.append({"payback_id": c["id"], "amount_cents": c["amount_cents"], "from": payer_name(_text(c)), "date": day.isoformat(),
                    "candidates": [{"purchase_id": p["id"], "merchant": p.get("merchant_clean") or clean_merchant(_text(p)), "amount_cents": -p["amount_cents"], "left_cents": left,
                                    "date": _day(p["occurred_at"]).isoformat()} for _, _, _, p, left in found[:MAX_CANDIDATES]]})
    return out

def _recent(user_id: str, days: int) -> tuple[list[dict], dict[str, str]]:
    since = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
    rows = rest().select("transactions", user_id=f"eq.{user_id}", occurred_at=f"gte.{since}", select="id,account_id,amount_cents,occurred_at,merchant_clean,merchant_raw,flow,reimbursed_cents")
    return rows, {a["id"]: a["type"] for a in rest().select("accounts", user_id=f"eq.{user_id}", select="id,type")}

def auto_link(user_id: str) -> int:
    """A bank credit that is exactly a settlement already recorded in Tally: tie them together (the settlement trigger excludes the row)."""
    open_ = rest().select("tally_settlements", user_id=f"eq.{user_id}", status="eq.confirmed", transaction_id="is.null", deleted_at="is.null", to_person="is.null", select="id,from_person,amount_cents,settled_on")
    if not open_:
        return 0
    people = {p["id"]: p for p in rest().select("people", user_id=f"eq.{user_id}", select="id,name")}
    rows, types = _recent(user_id, 60)
    credits = [r for r in rows if is_person_credit(r, types)]
    used: set[str] = set()
    n = 0
    for s in sorted(open_, key=lambda x: str(x["settled_on"])):
        first = (people.get(s.get("from_person"), {}).get("name") or "").split(" ")[0].lower()
        on = date.fromisoformat(str(s["settled_on"])[:10])
        hits = [c for c in credits if c["id"] not in used and c["amount_cents"] == s["amount_cents"] and first and first in _text(c).lower()
                and -SETTLE_BEFORE_DAYS <= (on - _day(c["occurred_at"])).days <= SETTLE_AFTER_DAYS]
        if len(hits) == 1:
            used.add(hits[0]["id"])
            rest().update("tally_settlements", {"id": s["id"], "user_id": user_id}, {"transaction_id": hits[0]["id"]})
            n += 1
    return n

class LinkBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    purchase_id: str
    payback_id: str

class PaybackBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    payback_id: str

def _uuid(v: str) -> str:
    if not UUID.fullmatch(v or ""):
        raise HTTPException(404, "not found")
    return v

@router.get("/paybacks/suggestions")
def suggestions(user_id: str = Depends(current_user)):
    user_limiter.check(f"paybacks:{user_id}", 30, 60)
    auto_link(user_id)
    rows, types = _recent(user_id, 90)
    linked = {x["payback_id"] for x in rest().select("txn_paybacks", user_id=f"eq.{user_id}", select="payback_id")}
    dismissed = {x["payback_id"] for x in rest().select("txn_payback_dismissals", user_id=f"eq.{user_id}", select="payback_id")}
    return {"suggestions": suggest([r for r in rows if r["id"] not in linked], types, dismissed)}

@router.post("/paybacks/link")
def link(body: LinkBody, user_id: str = Depends(current_user)):
    user_limiter.check(f"paybacks-w:{user_id}", 30, 60)
    try:
        return rest().rpc("tick_payback_link", {"p_uid": user_id, "p_purchase": _uuid(body.purchase_id), "p_payback": _uuid(body.payback_id), "p_source": "user"})
    except httpx.HTTPStatusError as e:
        if e.response.status_code == 404 or "not found" in e.response.text:
            raise HTTPException(404, "not found")
        if "more than the purchase" in e.response.text:
            raise HTTPException(409, "That's more than what's left of this purchase.")
        if e.response.status_code in (400, 409):
            raise HTTPException(409, "That one can't be linked.")
        raise

@router.post("/paybacks/unlink")
def unlink(body: PaybackBody, user_id: str = Depends(current_user)):
    user_limiter.check(f"paybacks-w:{user_id}", 30, 60)
    rest().delete("txn_paybacks", {"user_id": user_id, "payback_id": _uuid(body.payback_id)})
    return {"unlinked": True}

@router.post("/paybacks/dismiss")
def dismiss(body: PaybackBody, user_id: str = Depends(current_user)):
    user_limiter.check(f"paybacks-w:{user_id}", 30, 60)
    pid = _uuid(body.payback_id)
    if not rest().select("transactions", id=f"eq.{pid}", user_id=f"eq.{user_id}", select="id"):
        raise HTTPException(404, "not found")
    rest().insert("txn_payback_dismissals", {"user_id": user_id, "payback_id": pid}, upsert_on="user_id,payback_id")
    return {"dismissed": True}
