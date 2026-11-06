"""Re-apply the money rules to EXISTING rows (used by tools/repair_sync.py). Idempotent; dry-run by default."""
from __future__ import annotations

import collections

from . import plaid as P
from .db import rest


def reclassify(user_id: str, apply: bool = False) -> dict:
    raw = rest().select("transactions", user_id=f"eq.{user_id}",
                        select="id,account_id,amount_cents,occurred_at,merchant_clean,merchant_raw,flow,category_id,transfer_pair_id,user_edited", limit="20000")
    plan = P.apply_money_rules(user_id, raw, dry_run=True)
    kinds = collections.Counter(("transfer" if p.get("flow") == "transfer" else "bill" if p.get("flow") == "bill" else "friends and family") for p in plan.values())
    if apply:
        for tid, patch in plan.items():
            rest().update("transactions", {"id": tid, "user_id": user_id}, patch)
    return {"changed": len(plan), "summary": ", ".join(f"{n} {k}" for k, n in sorted(kinds.items())) or "nothing"}
