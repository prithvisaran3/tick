#!/usr/bin/env python3
"""Live categorisation through the DEPLOYED API: one text for an unknown merchant (regex parses it, so only the categorise call uses AI).
Costs exactly one free-model request. Throwaway user is deleted at the end."""
import hashlib, json, os, secrets, sys, httpx
BASE = "https://tick-api-production.up.railway.app"
url, key = os.environ["SUPABASE_URL"].rstrip("/"), os.environ["SUPABASE_SECRET_KEY"]
AH = {"apikey": key, "Authorization": f"Bearer {key}", "Content-Type": "application/json"}
def admin(m, p, b=None):
    r = httpx.request(m, url + p, json=b, headers=AH, timeout=30); r.raise_for_status(); return r.json() if r.content else None
uid = admin("POST", "/auth/v1/admin/users", {"email": f"ai-{secrets.token_hex(4)}@test.local", "email_confirm": True, "password": secrets.token_urlsafe(24)})["id"]
try:
    t = "tk_" + secrets.token_urlsafe(24)
    admin("POST", "/rest/v1/ingest_tokens", {"user_id": uid, "token_hash": hashlib.sha256(t.encode()).hexdigest(), "last4": t[-4:]})
    r = httpx.post(BASE + "/ingest", json={"source": "sms", "text": "Chase: A $12.00 transaction was made at BLUEBIRD ESPRESSO BAR on card ending in 4421."}, headers={"X-Tick-Token": t}, timeout=60)
    print("ingest", r.status_code, r.json())
    rows = admin("GET", f"/rest/v1/transactions?user_id=eq.{uid}&select=merchant_clean,category_id,categories(name)")
    print("row:", json.dumps(rows))
    usage = admin("GET", "/rest/v1/ai_usage?provider=eq.openrouter&order=created_at.desc&limit=1&select=feature,model_used,status")
    print("usage:", usage)
    assert rows and rows[0]["categories"]["name"] in ("Coffee", "Restaurants"), "AI categorisation did not land"
    print("LIVE AI CATEGORISATION OK")
finally:
    admin("DELETE", f"/auth/v1/admin/users/{uid}")
