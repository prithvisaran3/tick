"""Authentication: Supabase JWT for the app, X-Tick-Token for capture channels, CRON_SECRET for scheduled jobs."""
from __future__ import annotations

import hashlib
import hmac
import time
from collections import defaultdict, deque

import httpx
import jwt
from fastapi import Header, HTTPException

from .config import settings
from .db import rest

_jwks: jwt.PyJWKClient | None = None

def _jwks_client() -> jwt.PyJWKClient:
    global _jwks
    if _jwks is None:
        _jwks = jwt.PyJWKClient(settings().supabase_url.rstrip("/") + "/auth/v1/.well-known/jwks.json", cache_keys=True, lifespan=3600)
    return _jwks

def verify_supabase_jwt(token: str) -> dict:
    """Verify a Supabase access token against the project's JWKS (asymmetric signing keys). Falls back to asking the Auth server."""
    try:
        key = _jwks_client().get_signing_key_from_jwt(token)
        return jwt.decode(token, key.key, algorithms=["ES256", "RS256", "EdDSA"], audience="authenticated", options={"require": ["exp", "sub"]})
    except jwt.ExpiredSignatureError:
        raise HTTPException(401, "token expired")
    except Exception:
        pass
    s = settings()
    r = httpx.get(s.supabase_url.rstrip("/") + "/auth/v1/user", headers={"Authorization": f"Bearer {token}", "apikey": s.supabase_publishable_key}, timeout=10)
    if r.status_code != 200:
        raise HTTPException(401, "invalid token")
    return {"sub": r.json()["id"]}

def current_user(authorization: str = Header(default="")) -> str:
    if not authorization.lower().startswith("bearer "):
        raise HTTPException(401, "missing bearer token")
    return verify_supabase_jwt(authorization[7:].strip())["sub"]

def require_cron(x_cron_secret: str = Header(default="")) -> None:
    secret = settings().cron_secret
    if not secret or not hmac.compare_digest(x_cron_secret.encode(), secret.encode()):
        raise HTTPException(401, "bad cron secret")

def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()

_cache: dict[str, tuple[float, str]] = {}

def user_for_tick_token(x_tick_token: str = Header(default="")) -> tuple[str, str]:
    """Returns (user_id, token_hash). Tokens are stored hashed and revocable."""
    if not x_tick_token.startswith("tk_"):
        raise HTTPException(401, "missing or malformed X-Tick-Token")
    h = hash_token(x_tick_token)
    hit = _cache.get(h)
    if hit and hit[0] > time.time():
        return hit[1], h
    rows = rest().select("ingest_tokens", token_hash=f"eq.{h}", revoked_at="is.null", select="user_id,id")
    if not rows:
        raise HTTPException(401, "unknown or revoked token")
    _cache[h] = (time.time() + 60, rows[0]["user_id"])
    try:
        rest().update("ingest_tokens", {"id": rows[0]["id"]}, {"last_used_at": "now()"})
    except Exception:
        pass
    return rows[0]["user_id"], h

class RateLimiter:
    def __init__(self, limit: int, per_seconds: int) -> None:
        self.limit, self.per, self.hits = limit, per_seconds, defaultdict(deque)

    def check(self, key: str) -> None:
        now = time.time()
        q = self.hits[key]
        while q and q[0] < now - self.per:
            q.popleft()
        if len(q) >= self.limit:
            raise HTTPException(429, "slow down")
        q.append(now)

ingest_limiter = RateLimiter(60, 60)
