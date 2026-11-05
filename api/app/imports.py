"""POST /import/apple-card: the Apple Card statement CSV (see applecard.py). Signed-in users only; a few imports a minute at most."""
from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, File, HTTPException, UploadFile

from . import applecard as AC
from . import store
from .auth import current_user, user_limiter
from .db import rest

router = APIRouter()

@router.post("/import/apple-card")
def import_apple_card(file: UploadFile = File(...), user_id: str = Depends(current_user)):
    user_limiter.check(f"import:{user_id}", 5, 60)
    raw = file.file.read(AC.MAX_BYTES + 1)
    try:
        rows, bad = AC.parse(raw)
    except AC.ImportError_ as e:
        raise HTTPException(422, str(e))
    if not rows:
        return {"imported": 0, "skipped_duplicates": 0, "already_imported": 0, "unreadable": bad}
    acct = store.apple_card_account(user_id)
    lo = datetime.combine(min(r.when for r in rows), datetime.min.time(), timezone.utc) - timedelta(days=AC.MATCH_DAYS + 1)
    hi = datetime.combine(max(r.when for r in rows), datetime.min.time(), timezone.utc) + timedelta(days=AC.MATCH_DAYS + 2)
    r = rest().c.get(f"{rest().base}/transactions", headers=rest().h, params=[
        ("user_id", f"eq.{user_id}"), ("occurred_at", f"gte.{lo.isoformat()}"), ("occurred_at", f"lte.{hi.isoformat()}"),
        ("select", "id,amount_cents,occurred_at,merchant_clean,merchant_raw,account_id,external_ref"), ("limit", "10000")])
    r.raise_for_status()
    existing = r.json()
    imported = {e["external_ref"] for e in existing if e.get("external_ref")}
    live = [{**e, "_apple_card": e.get("account_id") == acct} for e in existing if not e.get("external_ref")]
    plan = AC.plan_import(rows, live, imported)
    name_to_id, _ = store.category_maps(user_id)
    rules = store.learned_rules(user_id)
    with store.user_lock(user_id):
        batch = []
        for row in plan.inserts:
            f = AC.row_fields(row, acct, name_to_id, rules)
            batch.append({**f, "id": str(uuid.uuid4()), "user_id": user_id})
        for i in range(0, len(batch), 500):
            rest().insert("transactions", batch[i:i + 500], returning=False)
        # A live capture that matched a CSV row now lives on the Apple Card account (Wallet sometimes omits the card).
        for _, tid in plan.duplicates:
            rest().update("transactions", {"id": tid, "user_id": user_id}, {"account_id": acct})
    try:
        from .plaid import pair_transfers
        pair_transfers(user_id, days=400)                     # the CSV's payments pair with the checking side
    except Exception:
        pass
    return {"imported": len(plan.inserts), "skipped_duplicates": len(plan.duplicates), "already_imported": plan.already_imported, "unreadable": bad}
