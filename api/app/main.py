from fastapi import FastAPI
from .config import settings
from .ai import provider as ai_provider
from .ingest import router as ingest_router
from .plaid import router as plaid_router
from .intel import router as intel_router
from .ask import router as ask_router
from .receipts import router as receipts_router

app = FastAPI(title="Tick API", version="0.1.0", docs_url=None, redoc_url=None)
app.include_router(ingest_router)
app.include_router(plaid_router)
app.include_router(intel_router)
app.include_router(ask_router)
app.include_router(receipts_router)

@app.get("/health")
def health():
    s = settings()
    # Only booleans about configuration; never values.
    return {"ok": True, "service": "tick-api", "version": s.git_sha,
            "configured": {"supabase": bool(s.supabase_url and s.supabase_secret_key),
                           "ai": ai_provider().available(), "plaid": bool(s.plaid_client_id and s.plaid_secret),
                           "cron": bool(s.cron_secret)},
            "ai_provider": ai_provider().name}
