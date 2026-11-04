from fastapi import FastAPI
from .config import settings, GEMINI_MODEL
from .ingest import router as ingest_router

app = FastAPI(title="Tick API", version="0.1.0", docs_url=None, redoc_url=None)
app.include_router(ingest_router)

@app.get("/health")
def health():
    s = settings()
    # Only booleans about configuration; never values.
    return {"ok": True, "service": "tick-api", "version": s.git_sha,
            "configured": {"supabase": bool(s.supabase_url and s.supabase_secret_key),
                           "gemini": bool(s.gemini_api_key), "plaid": bool(s.plaid_client_id and s.plaid_secret),
                           "cron": bool(s.cron_secret)},
            "gemini_model": GEMINI_MODEL}
