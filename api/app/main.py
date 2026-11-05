import logging
import os
import time
import uuid

from fastapi import FastAPI, Request
from starlette.exceptions import HTTPException
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from .ingest import router as ingest_router
from .plaid import router as plaid_router
from .intel import router as intel_router
from .ask import router as ask_router
from .receipts import router as receipts_router
from .imports import router as imports_router

from . import security
from .account import router as account_router

log = logging.getLogger("tick")
security.configure_logging()

if 0 < len(os.environ.get("CRON_SECRET", "")) < 32:
    log.warning("CRON_SECRET is shorter than 32 characters: rotate it (docs/SECURITY.md)")   # length only, never the value

app = FastAPI(title="Tick API", version="0.3.0", docs_url=None, redoc_url=None, openapi_url=None)
security.install(app)
app.include_router(ingest_router)
app.include_router(plaid_router)
app.include_router(intel_router)
app.include_router(ask_router)
app.include_router(receipts_router)
app.include_router(imports_router)
app.include_router(account_router)

CALM = "That didn't go through. Try again, nothing was lost."

def _err(status: int, message: str, code: str) -> JSONResponse:
    # `detail` stays a plain string for the app; `error` is the structured form.
    return JSONResponse(status_code=status, content={"detail": message, "error": {"code": code, "message": message}})

@app.exception_handler(HTTPException)
async def http_error(_: Request, exc: HTTPException):
    msg = exc.detail if isinstance(exc.detail, str) else CALM
    return _err(exc.status_code, msg, {400: "bad_request", 401: "unauthorized", 403: "forbidden", 404: "not_found", 409: "conflict", 413: "too_large", 422: "invalid", 429: "rate_limited"}.get(exc.status_code, "error"))

@app.exception_handler(RequestValidationError)
async def invalid(_: Request, exc: RequestValidationError):
    return _err(422, "Check the details and try again.", "invalid")

@app.exception_handler(Exception)
async def unhandled(request: Request, exc: Exception):
    # Log the type and route only: exception text can contain user data.
    log.error("unhandled %s on %s %s", type(exc).__name__, request.method, request.url.path)
    return _err(500, CALM, "server_error")

@app.middleware("http")
async def access_log(request: Request, call_next):
    rid = request.headers.get("x-request-id") or uuid.uuid4().hex[:12]
    t0 = time.time()
    response = await call_next(request)
    ms = int((time.time() - t0) * 1000)
    if request.url.path != "/health":
        log.info("%s %s -> %s %dms rid=%s", request.method, request.url.path, response.status_code, ms, rid)   # no query string, no body
    response.headers["x-request-id"] = rid
    return response

@app.get("/health")
def health():
    # Liveness only. No version, provider names or configuration flags: nothing that helps an attacker fingerprint the service.
    return {"ok": True}
