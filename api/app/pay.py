"""The pay period comes from SQL (pay_period). This is the only door to it from Python: no payday maths lives here."""
from __future__ import annotations

from datetime import date

from .db import rest

def pay_period(user_id: str, day: date | None = None) -> dict | None:
    """{period_start, period_end, next_payday} as dates, or None when there's no rule."""
    rows = rest().rpc("pay_period", {"p_user": user_id, "p_date": day.isoformat() if day else None})
    if not rows or not rows[0].get("next_payday"):
        return None
    return {k: date.fromisoformat(str(rows[0][k])[:10]) for k in ("period_start", "period_end", "next_payday")}
