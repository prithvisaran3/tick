"""Environment-driven settings. Secrets come from env vars only and are never logged."""
import os
from functools import lru_cache

# ONE constant for the Gemini model; update per Google's current "Flash" model docs.
GEMINI_MODEL = os.environ.get("GEMINI_MODEL", "gemini-3.7-flash")

class Settings:
    def __init__(self) -> None:
        e = os.environ.get
        self.supabase_url = e("SUPABASE_URL", "")
        self.supabase_secret_key = e("SUPABASE_SECRET_KEY", "")
        self.supabase_publishable_key = e("SUPABASE_PUBLISHABLE_KEY", "")
        self.cron_secret = e("CRON_SECRET", "")
        self.gemini_api_key = e("GEMINI_API_KEY", "")
        self.plaid_client_id = e("PLAID_CLIENT_ID", "")
        self.plaid_secret = e("PLAID_SECRET", "")
        self.plaid_env = e("PLAID_ENV", "sandbox")
        self.public_base_url = e("PUBLIC_BASE_URL", "")
        self.git_sha = e("RAILWAY_GIT_COMMIT_SHA", "dev")[:7]

@lru_cache
def settings() -> Settings:
    return Settings()
