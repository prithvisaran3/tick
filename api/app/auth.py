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

ALGS = ["ES256", "RS256", "EdDSA"]          # asymmetric only: never HS256 with a shared secret, never "none"

def verify_supabase_jwt(token: str) -> dict:
    """Verify a Supabase access token: signature against the project's JWKS, issuer, audience, expiry, subject and role.
    The Auth server is asked ONLY when the JWKS itself can't be fetched (network) - a bad signature is final, never retried remotely."""
    s = settings()
    issuer = s.supabase_url.rstrip("/") + "/auth/v1"
    try:
        header = jwt.get_unverified_header(token)
    except Exception:
        raise HTTPException(401, "invalid token")
    if header.get("alg") not in ALGS:
        raise HTTPException(401, "invalid token")
    try:
        key = _jwks_client().get_signing_key_from_jwt(token)
    except jwt.PyJWKClientConnectionError:
        return _verify_remotely(token)
    except Exception:
        raise HTTPException(401, "invalid token")
    try:
        claims = jwt.decode(token, key.key, algorithms=ALGS, audience="authenticated", issuer=issuer,
                            options={"require": ["exp", "iat", "sub", "iss", "aud"]}, leeway=30)
    except jwt.ExpiredSignatureError:
        raise HTTPException(401, "token expired")
    except Exception:
        raise HTTPException(401, "invalid token")
    if claims.get("role") != "authenticated" or not claims.get("sub"):
        raise HTTPException(401, "invalid token")
    return claims

def _verify_remotely(token: str) -> dict:
    s = settings()
    try:
        r = httpx.get(s.supabase_url.rstrip("/") + "/auth/v1/user", headers={"Authorization": f"Bearer {token}", "apikey": s.supabase_publishable_key}, timeout=10)
    except httpx.HTTPError:
        raise HTTPException(503, "Sign-in check is unavailable. Try again in a moment.")
    if r.status_code != 200 or not r.json().get("id"):
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
    """Returns (user_id, token_hash). Tokens are stored hashed, scoped to capture (/ingest) and revocable.
    Lookup is by SHA-256 of the presented token (an indexed equality on a hash, so timing reveals nothing about stored tokens)."""
    if not x_tick_token.startswith("tk_"):
        raise HTTPException(401, "missing or malformed X-Tick-Token")
    h = hash_token(x_tick_token)
    hit = _cache.get(h)
    if hit and hit[0] > time.time():
        return hit[1], h
    if len(x_tick_token) > 200:
        raise HTTPException(401, "missing or malformed X-Tick-Token")
    try:
        rows = rest().select("ingest_tokens", token_hash=f"eq.{h}", revoked_at="is.null", scope="eq.ingest", select="user_id,id")
    except httpx.HTTPError:
        raise HTTPException(503, "Capture is unavailable for a moment. Nothing was lost.")
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

    def check(self, key: str, limit: int | None = None, per: int | None = None) -> None:
        now = time.time()
        lim, window = limit or self.limit, per or self.per
        q = self.hits[key]
        while q and q[0] < now - window:
            q.popleft()
        if len(q) >= lim:
            raise HTTPException(429, "That was a lot at once. Try again in a moment.")
        q.append(now)
        if len(self.hits) > 5000:                      # bound memory: drop idle keys
            for k in [k for k, v in self.hits.items() if not v or v[-1] < now - 3600]:
                self.hits.pop(k, None)

ingest_limiter = RateLimiter(60, 60)
user_limiter = RateLimiter(30, 60)

def forget_tokens(user_id: str | None = None) -> None:
    """Drop cached capture-token lookups (all of them, or one user's) so a revoke takes effect immediately."""
    for k in [k for k, v in _cache.items() if user_id is None or v[1] == user_id]:
        _cache.pop(k, None)
