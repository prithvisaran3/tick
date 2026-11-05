"""Receipt photo -> Storage (private bucket, <user_id>/...) -> Gemini extraction -> confirm into the ledger as source 'receipt'."""
from __future__ import annotations

import uuid
from datetime import datetime, timezone

import httpx
from fastapi import APIRouter, Depends, File, HTTPException, UploadFile
import re

from pydantic import BaseModel, ConfigDict, Field

from . import ai, store
from .auth import current_user, user_limiter
from .config import settings
from .db import rest
from .merchants import categorize, clean_merchant, looks_business
from .reconcile import Candidate, plan

router = APIRouter()

@router.post("/receipts/scan")
def scan(file: UploadFile = File(...), user_id: str = Depends(current_user)):
    # Plain `def`: FastAPI runs it in the threadpool, so the blocking storage upload and the AI call never stall the event loop.
    user_limiter.check(f"scan:{user_id}", 10, 60)
    data = file.file.read(8_000_001)
    if len(data) > 8_000_000:
        raise HTTPException(413, "Photo too large")
    mime = sniff_image(data)
    if mime is None:
        raise HTTPException(415, "That isn't a photo Tick can read.")
    path = f"{user_id}/{uuid.uuid4().hex}.jpg"
    s = settings()
    r = httpx.post(f"{s.supabase_url.rstrip('/')}/storage/v1/object/receipts/{path}", content=data, headers={"apikey": s.supabase_secret_key, "Content-Type": mime}, timeout=30)
    if r.status_code >= 300:
        raise HTTPException(502, "That didn't go through. Try again, nothing was lost.")
    ext = ai.receipt_extract(user_id, data, mime)      # None when Gemini is unavailable: the app lets the person type it in
    return {"path": path, "extracted": ext}

def sniff_image(data: bytes) -> str | None:
    """Trust the bytes, not the client's Content-Type."""
    if data[:3] == b"\xff\xd8\xff":
        return "image/jpeg"
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return "image/png"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    if data[4:8] == b"ftyp" and data[8:12] in (b"heic", b"heix", b"heif", b"mif1", b"msf1", b"hevc"):
        return "image/heic"
    return None

class ConfirmBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    path: str | None = Field(default=None, max_length=200)
    merchant: str = Field(min_length=1, max_length=200)
    total: float = Field(gt=0, lt=1_000_000)
    date: str | None = Field(default=None, max_length=10)

@router.post("/receipts/confirm")
def confirm(b: ConfirmBody, user_id: str = Depends(current_user)):
    if b.path and not re.fullmatch(rf"{re.escape(user_id)}/[0-9a-f]{{32}}\.jpg", b.path):
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
