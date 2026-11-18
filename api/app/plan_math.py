"""The plan arithmetic Ask Tick and the API share with the app: goals from real balances, planned one-offs, and what a paycheck has to cover.
Pure functions, no database. Dart twins: app/lib/domain/goals.dart and planned.dart (vectors: tests/data/goal_status.json)."""
from __future__ import annotations

from datetime import date, timedelta

TOLERANCE = 100          # a dollar of interest or rounding isn't "behind"
PLANNED_GRACE_DAYS = 7   # a planned one-off still counts this long after its date, in case the purchase is late

def _d(v) -> date:
    return v if isinstance(v, date) else date.fromisoformat(str(v)[:10])

def goal_status(*, mode: str, target: int, start_cents: int, linked: int, start_date, deadline, today, paydays: list) -> dict:
    """[paydays]: every payday after start_date up to the deadline. A payday that is today still counts as one to use."""
    amount = max(0, target - start_cents) if mode == "balance" else max(0, target)
    saved = min(amount, max(0, linked - start_cents))
    remaining = amount - saved
    t = _d(today)
    days = sorted(_d(p) for p in paydays)
    left = len([p for p in days if p >= t]) if deadline else 0
    if remaining == 0:
        return {"status": "done", "saved": saved, "remaining": 0, "paychecks_left": left, "per_paycheck": 0, "behind_by": 0}
    if not deadline:
        return {"status": "on_track", "saved": saved, "remaining": remaining, "paychecks_left": 0, "per_paycheck": 0, "behind_by": 0}
    if left == 0:
        return {"status": "behind", "saved": saved, "remaining": remaining, "paychecks_left": 0, "per_paycheck": remaining, "behind_by": remaining}
    total = len(days)
    planned = -(-amount // total) if total else amount          # what each paycheck was meant to carry
    elapsed = len([p for p in days if p < t])
    behind = max(0, min(amount, planned * elapsed) - saved)
    behind = behind if behind > TOLERANCE else 0
    return {"status": "behind" if behind else "on_track", "saved": saved, "remaining": remaining, "paychecks_left": left, "per_paycheck": -(-remaining // left), "behind_by": behind}


def counts_this_period(p: dict, today: date, payday: date) -> bool:
    """A planned one-off comes out of this pay period: not bought yet, dated before the next payday, and not long past."""
    due = _d(p["due"])
    return p.get("status", "planned") == "planned" and due < payday and due >= today - timedelta(days=PLANNED_GRACE_DAYS)

def goal_relief(planned: list[dict], period_start: date, payday: date) -> int:
    """What goals give up this period for one-offs I already decided about. Stays for the whole period, matched or not."""
    return sum(int(p.get("shortfall_cents") or 0) for p in planned
               if p.get("resolution") and p.get("status") != "dismissed" and period_start - timedelta(days=PLANNED_GRACE_DAYS) <= _d(p["due"]) < payday)

def likely_bought(planned: list[dict], txns: list[dict], today: date) -> set[str]:
    """Names of planned one-offs whose purchase has most likely posted already (money out within 20% or $20, within a week). The same rule as
    the app's plannedMatches; such a one-off stops being set aside while it waits for a Yes, so it's never counted twice."""
    used, out = set(), set()
    for p in sorted((p for p in planned if p.get("status", "planned") == "planned"), key=lambda p: _d(p["due"])):
        slack = max(int(p["cents"]) // 5, 2000)
        best = None
        for t in txns:
            if t.get("amount_cents", 0) >= 0 or t.get("id") in used or not t.get("out_cents") or _d(t["date"]) > today:
                continue
            off, days = abs(-int(t["amount_cents"]) - int(p["cents"])), abs((_d(t["date"]) - _d(p["due"])).days)
            if off <= slack and days <= 7 and (best is None or off + days * 500 < best[0]):
                best = (off + days * 500, t["id"])
        if best:
            used.add(best[1])
            t = next(x for x in txns if x.get("id") == best[1])
            if _d(t["date"]) >= _d(p["due"]) - timedelta(days=2):          # a purchase well before its date isn't it
                out.add(p["name"])
    return out
