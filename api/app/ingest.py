"""POST /ingest: source-agnostic capture endpoint (Shortcuts SMS + Apple Pay today; receipt photos and quick add share the core)."""
from __future__ import annotations

import hashlib
import threading
from collections import defaultdict
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, Header, HTTPException
from pydantic import BaseModel, Field

from . import ai, store
from .auth import ingest_limiter, user_for_tick_token
from .db import rest
from .merchants import categorize, clean_merchant, looks_business
from .parsers import ParsedAlert, parse_alert, parse_applepay
from .reconcile import REVIEW_THRESHOLD, Candidate, plan

router = APIRouter()

class IngestBody(BaseModel):
    source: str = Field(pattern="^(sms|applepay)$")
    text: str | None = None
    merchant: str | None = None
    amount: float | str | None = None
    card: str | None = None

def build_candidate(user_id: str, source: str, ref: str, parsed: ParsedAlert, now: datetime) -> tuple[Candidate, list[str]]:
    name_to_id, _ = store.category_maps(user_id)
    rules = store.learned_rules(user_id)
    clean = clean_merchant(parsed.merchant_raw)
    cat_name, how = categorize(clean or parsed.merchant_raw, rules)
    if how == "none" and clean and parsed.amount_cents < 0:
        ai_res = ai.categorize_ai(user_id, clean, list(name_to_id))
        if ai_res:
            clean, cat_name = ai_res[0] or clean, ai_res[1]
    if parsed.amount_cents > 0:
        cat_name = "Income"
    tags = ["business"] if parsed.amount_cents < 0 and looks_business(clean or parsed.merchant_raw) else []
    cand = Candidate(source=source, ref=ref, amount_cents=parsed.amount_cents, occurred_at=now, merchant_raw=parsed.merchant_raw, merchant_clean=clean,
                     card_last4=parsed.card_last4, status="posted", confidence=parsed.confidence, category_id=name_to_id.get(cat_name))
    return cand, tags

@router.post("/ingest")
def ingest(body: IngestBody, who: tuple[str, str] = Depends(user_for_tick_token), idempotency_key: str = Header(default="")):
    user_id, token_hash = who
    ingest_limiter.check(token_hash)
    now = datetime.now(timezone.utc)
    log = rest().insert("ingest_logs", {"user_id": user_id, "source": body.source, "payload": body.model_dump(exclude_none=True), "status": "received"})[0]
    try:
        if body.source == "sms":
            if not body.text:
                raise HTTPException(422, "text required")
            ref = idempotency_key or hashlib.sha256(body.text.encode()).hexdigest()[:20]
            parsed = parse_alert(body.text)
            if parsed is None or parsed.confidence < REVIEW_THRESHOLD:
                better = ai.parse_alert_ai(user_id, body.text)
                if better and (parsed is None or better.confidence > parsed.confidence):
                    parsed = better
        else:
            if body.merchant is None or body.amount is None:
                raise HTTPException(422, "merchant and amount required")
            ref = idempotency_key or hashlib.sha256(f"{body.merchant}|{body.amount}|{body.card}".encode()).hexdigest()[:20]
            parsed = parse_applepay(body.merchant, body.amount, body.card)
        if parsed is None:
            rest().update("ingest_logs", {"id": log["id"]}, {"status": "ignored", "result": {"reason": "not a transaction"}})
            return {"ok": True, "action": "ignored"}
        cand, tags = build_candidate(user_id, body.source, ref, parsed, now)
        _, id_to_name = store.category_maps(user_id)
        with store.user_lock(user_id):
            actions = plan(cand, store.window(user_id, now), category_names=id_to_name)
            action = actions[0]
            tid = None
            for a in actions:
                extra = {"tags": tags} if a.kind == "insert" and tags else None
                tid = store.persist(user_id, a, extra) or tid
        res = {"action": action.kind, "reason": action.reason, "confidence": cand.confidence, "needs_review": cand.confidence < REVIEW_THRESHOLD and action.kind == "insert"}
        rest().update("ingest_logs", {"id": log["id"]}, {"status": "ok", "result": res, "transaction_id": tid})
        return {"ok": True, "transaction_id": tid, **res}
    except HTTPException:
        rest().update("ingest_logs", {"id": log["id"]}, {"status": "error", "result": {"reason": "bad request"}})
        raise
    except Exception:
        rest().update("ingest_logs", {"id": log["id"]}, {"status": "error", "result": {"reason": "server error"}})
        raise HTTPException(500, "That didn't go through. Try again, nothing was lost.")
