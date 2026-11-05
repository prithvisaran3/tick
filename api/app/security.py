"""Edge protections for every request: security headers, strict CORS, request-size limits, per-IP rate limits, bad-token burst
detection, and log redaction. Kept in one place so tests/test_security.py can attack it directly."""
from __future__ import annotations

import logging
import os
import re
import time
from collections import defaultdict, deque

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

log = logging.getLogger("tick.security")

# ---------- request size ----------
DEFAULT_MAX_BODY = 256 * 1024
MAX_BODY = {"/receipts/scan": 8_100_000, "/import/apple-card": 2_100_000, "/webhooks/plaid": 512 * 1024, "/ask": 64 * 1024}

def max_body(path: str) -> int:
    return MAX_BODY.get(path, DEFAULT_MAX_BODY)

# ---------- client IP ----------
def client_ip(request: Request) -> str:
    """Railway's edge APPENDS the real client address to X-Forwarded-For, so the right-most entry is the one a client can't forge.
    (Left-most entries are whatever the client sent.)"""
    xff = request.headers.get("x-forwarded-for", "")
    parts = [p.strip() for p in xff.split(",") if p.strip()]
    if parts:
        return parts[-1][:64]
    return (request.client.host if request.client else "unknown")[:64]

# ---------- per-IP limits and bad-token bursts ----------
class IpGuard:
    """Sliding-window counters per IP. Unauthenticated failures (401/403) are counted separately: a burst of bad tokens from one
    address blocks it for a while and is written to the audit log (alert)."""
    def __init__(self, per_minute: int = 300, bad_per_minute: int = 20, block_seconds: int = 900) -> None:
        self.per_minute, self.bad_per_minute, self.block_seconds = per_minute, bad_per_minute, block_seconds
        self.hits: dict[str, deque] = defaultdict(deque)
        self.bad: dict[str, deque] = defaultdict(deque)
        self.blocked: dict[str, float] = {}

    def _trim(self, q: deque, now: float) -> None:
        while q and q[0] < now - 60:
            q.popleft()

    def allow(self, ip: str, now: float | None = None) -> bool:
        now = now or time.time()
        if self.blocked.get(ip, 0) > now:
            return False
        q = self.hits[ip]
        self._trim(q, now)
        if len(q) >= self.per_minute:
            return False
        q.append(now)
        if len(self.hits) > 20000:
            for k in [k for k, v in self.hits.items() if not v or v[-1] < now - 120]:
                self.hits.pop(k, None)
        return True

    def failed(self, ip: str, now: float | None = None) -> bool:
        """Record an auth failure. Returns True exactly when this failure starts a block (the moment to alert)."""
        now = now or time.time()
        q = self.bad[ip]
        self._trim(q, now)
        q.append(now)
        if len(q) >= self.bad_per_minute and self.blocked.get(ip, 0) <= now:
            self.blocked[ip] = now + self.block_seconds
            return True
        return False

ip_guard = IpGuard(per_minute=int(os.environ.get("TICK_IP_PER_MINUTE", "300")), bad_per_minute=int(os.environ.get("TICK_BAD_TOKEN_BURST", "20")))

# ---------- headers ----------
SECURITY_HEADERS = {
    "Strict-Transport-Security": "max-age=63072000; includeSubDomains",
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "Referrer-Policy": "no-referrer",
    "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
    "Cross-Origin-Opener-Policy": "same-origin",
    "Cross-Origin-Resource-Policy": "same-origin",
    "Content-Security-Policy": "default-src 'none'; frame-ancestors 'none'",
}
HTML_CSP = "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'"

def install(app: FastAPI) -> None:
    # CORS: Tick is a native app, so no browser origin is allowed unless one is configured explicitly (never a wildcard).
    origins = [o.strip() for o in os.environ.get("TICK_CORS_ORIGINS", "").split(",") if o.strip() and o.strip() != "*"]
    app.add_middleware(CORSMiddleware, allow_origins=origins, allow_credentials=False, allow_methods=["GET", "POST", "DELETE"],
                       allow_headers=["Authorization", "Content-Type", "X-Tick-Token", "Idempotency-Key"], max_age=600)

    @app.middleware("http")
    async def edge(request: Request, call_next):
        ip = client_ip(request)
        path = request.url.path
        if path != "/health" and not ip_guard.allow(ip):
            return JSONResponse(status_code=429, content={"detail": "That was a lot at once. Try again in a moment.",
                                                          "error": {"code": "rate_limited", "message": "That was a lot at once. Try again in a moment."}})
        if request.method in ("POST", "PUT", "PATCH", "DELETE"):
            limit = max_body(path)
            cl = request.headers.get("content-length")
            if cl is not None:
                try:
                    too_big = int(cl) > limit
                except ValueError:
                    too_big = True
                if too_big:
                    return JSONResponse(status_code=413, content={"detail": "That's too big to send.", "error": {"code": "too_large", "message": "That's too big to send."}})
            elif request.headers.get("transfer-encoding", "").lower() == "chunked":
                body = await request.body()                 # bounded read: starlette caches it for the route
                if len(body) > limit:
                    return JSONResponse(status_code=413, content={"detail": "That's too big to send.", "error": {"code": "too_large", "message": "That's too big to send."}})
        response = await call_next(request)
        if response.status_code in (401, 403) and ip_guard.failed(ip):
            log.warning("bad-token burst: blocking an address for %ss", ip_guard.block_seconds)
            try:
                from .audit import audit
                audit(None, "bad_token_burst", {"count": ip_guard.bad_per_minute})
            except Exception:
                pass
        for k, v in SECURITY_HEADERS.items():
            response.headers.setdefault(k, v)
        if response.headers.get("content-type", "").startswith("text/html"):
            response.headers["Content-Security-Policy"] = HTML_CSP
        if path != "/plaid/oauth-return":
            response.headers.setdefault("Cache-Control", "no-store")
        return response

# ---------- log redaction ----------
_REDACT = [
    (re.compile(r"(?i)bearer\s+[A-Za-z0-9._\-]+"), "Bearer [redacted]"),
    (re.compile(r"eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"), "[jwt]"),
    (re.compile(r"\btk_[A-Za-z0-9_\-]{8,}"), "[capture-token]"),
    (re.compile(r"\b(access|public|link)-(sandbox|production|development)-[A-Za-z0-9\-]{8,}"), "[plaid-token]"),
    (re.compile(r"\b(sk-or-v1|sk-ant|sk-proj|sb_secret|sbp)[A-Za-z0-9_\-]{8,}"), "[api-key]"),
    (re.compile(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"), "[email]"),
    (re.compile(r"(?i)\$\s?\d[\d,]*(\.\d{1,2})?|\b\d+\.\d{2}\b"), "[amount]"),
    (re.compile(r"(?i)(••|\*{2,}|x{2,}|ending in|mask[=:]\s*)\s?\d{4}\b"), "[mask]"),
    (re.compile(r"(?i)\b(amount_cents|amount|merchant(_raw|_clean)?|note|text|card|mask|token|secret|email)=[^\s&]+"), r"\1=[redacted]"),
]

def redact(s: str) -> str:
    for pat, rep in _REDACT:
        s = pat.sub(rep, s)
    return s

class RedactingFilter(logging.Filter):
    """Applied to every handler: formats the record first, then scrubs it, so arguments can't smuggle data past the filter."""
    def filter(self, record: logging.LogRecord) -> bool:
        try:
            msg = record.getMessage()
        except Exception:
            msg = str(record.msg)
        record.msg, record.args = redact(msg), None
        if record.exc_info:
            record.exc_text = redact(logging.Formatter().formatException(record.exc_info))
            record.exc_info = None
        return True

def configure_logging() -> None:
    root = logging.getLogger()
    if not root.handlers:
        logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    for h in root.handlers:
        if not any(isinstance(f, RedactingFilter) for f in h.filters):
            h.addFilter(RedactingFilter())
    # httpx logs every request URL at INFO: those URLs carry user ids, Plaid transaction ids and filters. Warnings only.
    for name in ("httpx", "httpcore", "hpack", "urllib3"):
        logging.getLogger(name).setLevel(logging.WARNING)
    for name in ("uvicorn.error", "uvicorn.access", "uvicorn"):
        lg = logging.getLogger(name)
        for h in lg.handlers:
            if not any(isinstance(f, RedactingFilter) for f in h.filters):
                h.addFilter(RedactingFilter())
