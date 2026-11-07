"""Finding people without a directory. Search matches an exact handle, email or phone, or a handle prefix from 3 characters (SQL:
tally_search_people), returns at most 5 people, and only ever shows a display name, handle and avatar. It goes through here, and not straight to
the database, so it can be rate limited: per minute against scanning, per day against slow scanning."""
from __future__ import annotations

import re

import httpx
from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, ConfigDict, Field

from .auth import current_user, user_limiter
from .db import rest

router = APIRouter()
HANDLE = re.compile(r"^[a-z0-9_]{3,20}$")
RESERVED = {"tick", "admin", "support", "help", "root", "system", "official", "me", "you", "null"}

def _norm(h: str) -> str:
    return h.strip().lstrip("@").lower()

def suggestion(display_name: str | None, taken) -> str | None:
    base = re.sub(r"[^a-z0-9_]", "", (display_name or "").strip().lower().replace(" ", "_"))[:16].strip("_")
    if len(base) < 3:
        return None
    for h in [base, *(f"{base}{i}" for i in range(2, 10))]:
        if h not in RESERVED and not taken(h):
            return h
    return None

class HandleBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    handle: str = Field(min_length=3, max_length=21)

@router.get("/people/search")
def search(q: str = Query(min_length=1, max_length=120), user_id: str = Depends(current_user)):
    user_limiter.check(f"people:{user_id}", 20, 60)
    user_limiter.check(f"people-day:{user_id}", 300, 86400)
    rows = rest().rpc("tally_search_people", {"p_caller": user_id, "p_q": q})
    return {"people": [{"user_id": r["user_id"], "display_name": r.get("display_name"), "handle": r.get("handle"), "avatar_url": r.get("avatar_url")} for r in rows[:5]]}

@router.get("/people/handle")
def my_handle(user_id: str = Depends(current_user)):
    p = rest().select("profiles", user_id=f"eq.{user_id}", select="handle,display_name,discoverable,zelle")
    me = p[0] if p else {}
    return {"handle": me.get("handle"), "discoverable": me.get("discoverable", True), "zelle": me.get("zelle"),
            "suggestion": None if me.get("handle") else suggestion(me.get("display_name"), lambda h: bool(rest().select("profiles", handle=f"eq.{h}", select="user_id")))}

@router.post("/people/handle")
def set_handle(body: HandleBody, user_id: str = Depends(current_user)):
    user_limiter.check(f"handle:{user_id}", 10, 60)
    h = _norm(body.handle)
    if not HANDLE.fullmatch(h):
        raise HTTPException(422, "Use 3 to 20 letters, numbers or underscores.")
    if h in RESERVED:
        raise HTTPException(409, "That handle is taken.")
    clash = rest().select("profiles", handle=f"eq.{h}", select="user_id")
    if clash and clash[0]["user_id"] != user_id:
        raise HTTPException(409, "That handle is taken.")
    try:
        rest().update("profiles", {"user_id": user_id}, {"handle": h})
    except httpx.HTTPStatusError as e:
        if e.response.status_code == 409:
            raise HTTPException(409, "That handle is taken.")
        raise
    return {"handle": h}
