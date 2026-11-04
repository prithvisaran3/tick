"""Receipt photo -> Storage (private bucket, <user_id>/...) -> Gemini extraction -> confirm into the ledger as source 'receipt'."""
from __future__ import annotations

import uuid
from datetime import datetime, timezone

import httpx
from fastapi import APIRouter, Depends, File, HTTPException, UploadFile
from pydantic import BaseModel

from . import ai, store
from .auth import current_user
from .config import settings
from .db import rest
from .merchants import categorize, clean_merchant, looks_business
from .reconcile import Candidate, plan

router = APIRouter()

@router.post("/receipts/scan")
async def scan(file: UploadFile = File(...), user_id: str = Depends(current_user)):
    data = await file.read()
    if len(data) > 8_000_000:
        raise HTTPException(413, "Photo too large")
    mime = file.content_type if (file.content_type or "").startswith("image/") else "image/jpeg"
    path = f"{user_id}/{uuid.uuid4().hex}.jpg"
    s = settings()
    r = httpx.post(f"{s.supabase_url.rstrip('/')}/storage/v1/object/receipts/{path}", content=data, headers={"apikey": s.supabase_secret_key, "Content-Type": mime}, timeout=30)
    if r.status_code >= 300:
        raise HTTPException(502, "That didn't go through. Try again, nothing was lost.")
    ext = ai.receipt_extract(user_id, data, mime)      # None when Gemini is unavailable: the app lets the person type it in
    return {"path": path, "extracted": ext}

class ConfirmBody(BaseModel):
    path: str | None = None
    merchant: str
    total: float
    date: str | None = None

@router.post("/receipts/confirm")
def confirm(b: ConfirmBody, user_id: str = Depends(current_user)):
    if b.path and not b.path.startswith(f"{user_id}/"):
        raise HTTPException(403, "not yours")
    if b.total <= 0:
        raise HTTPException(422, "total must be positive")
    now = datetime.now(timezone.utc)
    when = now
    if b.date:
        try:
            when = datetime.fromisoformat(b.date).replace(hour=16, tzinfo=timezone.utc)
        except ValueError:
            pass
    clean = clean_merchant(b.merchant) or b.merchant
    name_to_id, id_to_name = store.category_maps(user_id)
    cat, _ = categorize(clean, store.learned_rules(user_id))
    cand = Candidate("receipt", b.path or uuid.uuid4().hex, -round(b.total * 100), when, b.merchant, clean, None, "posted", confidence=0.9, category_id=name_to_id.get(cat), time_precise=False)
    with store.user_lock(user_id):
        actions = plan(cand, store.window(user_id, when), category_names=id_to_name)
        tid = None
        for a in actions:
            tid = store.persist(user_id, a, {"receipt_path": b.path, **({"tags": ["business"]} if looks_business(clean) and a.kind == "insert" else {})} if a.kind == "insert" else ({"receipt_path": b.path} if b.path else None)) or tid
    return {"ok": True, "transaction_id": tid, "action": actions[0].kind}
