"""Savings goals measured from real balances, daily balance snapshots, and the payday "Move $X to savings" check.
`goal_status` is the same arithmetic as Dart `goalStatus` (vectors: tests/data/goal_status.json). Nothing here moves money."""
from __future__ import annotations

from datetime import date, datetime, timezone
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, ConfigDict, Field

from .auth import current_user, user_limiter
from .db import rest
from .plan_math import goal_status  # noqa: F401  (re-exported; the arithmetic lives with the other plan maths)

router = APIRouter()
ET = ZoneInfo("America/New_York")
CONFIRM_SHARE = 0.9      # the balance has to rise by most of the move to count as made

def today_ny() -> date:
    return datetime.now(timezone.utc).astimezone(ET).date()

def snapshot_balances(user_id: str, day: date | None = None) -> int:
    """Today's balance for each of the person's accounts, once per New York day (the last sync of the day wins)."""
    day = day or today_ny()
    rows = [{"user_id": user_id, "account_id": a["id"], "day": day.isoformat(), "balance_cents": int(a["balance_cents"])}
            for a in rest().select("accounts", user_id=f"eq.{user_id}", select="id,balance_cents") if a.get("balance_cents") is not None]
    if rows:
        rest().insert("account_balances", rows, upsert_on="account_id,day", returning=False)
    return len(rows)

def linked_savings(user_id: str) -> tuple[list[str], int]:
    """The accounts goals are tied to (every savings account when no goal names one) and their balance now."""
    accts = rest().select("accounts", user_id=f"eq.{user_id}", select="id,type,balance_cents")
    named = {a for g in rest().select("goals", user_id=f"eq.{user_id}", select="account_ids,paused") if not g.get("paused") for a in (g.get("account_ids") or [])}
    ids = [a["id"] for a in accts if (a["id"] in named if named else a.get("type") == "savings")]
    return ids, sum(int(a.get("balance_cents") or 0) for a in accts if a["id"] in ids)

def confirm_moves(user_id: str) -> int:
    """A move I marked done is confirmed once the linked balance has risen by most of it. Two days with no rise: unconfirmed, so the card says so."""
    n = 0
    for m in rest().select("goal_moves", user_id=f"eq.{user_id}", status="eq.done", select="id,cents,balance_before_cents,created_at"):
        _, now_c = linked_savings(user_id)
        if now_c - int(m["balance_before_cents"]) >= int(m["cents"]) * CONFIRM_SHARE:
            rest().update("goal_moves", {"id": m["id"], "user_id": user_id}, {"status": "confirmed", "confirmed_at": datetime.now(timezone.utc).isoformat()})
            n += 1
        elif (datetime.now(timezone.utc) - datetime.fromisoformat(str(m["created_at"]).replace("Z", "+00:00"))).days >= 2:
            rest().update("goal_moves", {"id": m["id"], "user_id": user_id}, {"status": "unconfirmed"})
    return n

def after_sync(user_id: str) -> None:
    """Called at the end of every bank sync. Never raises: a sync must not fail over a snapshot."""
    try:
        snapshot_balances(user_id)
        confirm_moves(user_id)
    except Exception:
        pass

class MoveBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    pay_date: date
    cents: int = Field(gt=0, lt=100_000_000)

@router.post("/goals/move")
def mark_moved(body: MoveBody, user_id: str = Depends(current_user)):
    """"Done" on the payday card. Records what the linked savings held at that moment; the next balance sync confirms the move."""
    user_limiter.check(f"goal-move:{user_id}", 20, 60)
    if abs((body.pay_date - today_ny()).days) > 7:
        raise HTTPException(422, "That payday is too far from today.")
    _, before = linked_savings(user_id)
    rest().insert("goal_moves", {"user_id": user_id, "pay_date": body.pay_date.isoformat(), "cents": body.cents, "status": "done", "balance_before_cents": before, "created_at": datetime.now(timezone.utc).isoformat()},
                  upsert_on="user_id,pay_date", ignore_duplicates=True, returning=False)
    return {"saved": True}

class UndoBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    pay_date: date

@router.post("/goals/move/undo")
def undo_move(body: UndoBody, user_id: str = Depends(current_user)):
    user_limiter.check(f"goal-move:{user_id}", 20, 60)
    rest().delete("goal_moves", {"user_id": user_id, "pay_date": body.pay_date.isoformat()})
    return {"saved": True}
