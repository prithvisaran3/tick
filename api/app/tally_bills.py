"""Recurring shared bills. A bill posts on its date. Up to MATCH_DAYS around that date, a matching charge on the PAYER's bank account posts it early and
links the two ("it posted on your card"). `match_charge` is pure; posting, the once-per-date rule and stopping are in SQL (tally_post_recurring)."""
from __future__ import annotations

import logging
import re
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends

from .auth import require_cron
from .db import rest

router = APIRouter()
log = logging.getLogger("tick.tally")
ET = ZoneInfo("America/New_York")
MATCH_DAYS = 5
TOLERANCE = 0.05            # a bill's amount drifts a little; more than 5% is a different charge

def _words(s: str | None) -> set[str]:
    return {w for w in re.findall(r"[a-z0-9]+", (s or "").lower()) if len(w) >= 3}

def match_charge(bill: dict, rows: list[dict]) -> dict | None:
    """The closest charge to the bill's date that names it and is about the right amount. None if nothing clearly fits."""
    due = date.fromisoformat(str(bill["next_on"])[:10])
    want, amount = _words(bill.get("match_text") or bill.get("description")), int(bill["amount_cents"])
    if not want:
        return None
    hits = []
    for r in rows:
        day = datetime.fromisoformat(str(r["occurred_at"]).replace("Z", "+00:00")).astimezone(ET).date()
        text = _words(f"{r.get('merchant_clean') or ''} {r.get('merchant_raw') or ''}")
        if r["amount_cents"] < 0 and r.get("flow") in (None, "bill") and abs(-r["amount_cents"] - amount) <= amount * TOLERANCE and abs((day - due).days) <= MATCH_DAYS and want & text:
            hits.append((abs((day - due).days), str(r["id"]), r))
    return min(hits, key=lambda h: h[:2])[2] if hits else None

def run(today: date | None = None) -> int:
    today = today or datetime.now(ET).date()
    horizon = today + timedelta(days=MATCH_DAYS)
    posted = 0
    for b in rest().select("tally_recurring", active="is.true", next_on=f"lte.{horizon.isoformat()}", select="id,description,amount_cents,next_on,match_text,paid_by_member"):
        try:
            payer = rest().select("tally_members", id=f"eq.{b['paid_by_member']}", select="member_user_id")
            uid = payer[0].get("member_user_id") if payer else None
            hit = None
            if uid:
                since = (datetime.now(timezone.utc) - timedelta(days=45)).isoformat()
                taken = {e["transaction_id"] for e in rest().select("tally_expenses", transaction_id="not.is.null", external_ref="like.recurring:*", select="transaction_id")}
                rows = rest().select("transactions", user_id=f"eq.{uid}", occurred_at=f"gte.{since}", select="id,amount_cents,occurred_at,merchant_clean,merchant_raw,flow")
                hit = match_charge(b, [r for r in rows if r["id"] not in taken])
            if hit or date.fromisoformat(str(b["next_on"])[:10]) <= today:
                if rest().rpc("tally_post_recurring", {"p_id": b["id"], "p_txn": hit["id"] if hit else None}):
                    posted += 1
        except Exception:
            log.exception("recurring bill failed")           # one bad bill never stops the rest
    return posted

@router.post("/jobs/tally-recurring", dependencies=[Depends(require_cron)])
def job():
    return {"posted": run()}
