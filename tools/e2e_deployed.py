#!/usr/bin/env python3
"""Live check of the deployed API: ingest via X-Tick-Token, then /ask (SSE) and /plaid/links with a real Supabase JWT. Throwaway user is deleted at the end."""
import hashlib, json, os, secrets, sys, urllib.request
import httpx
BASE = (sys.argv[1] if len(sys.argv) > 1 else "https://tick-api-production.up.railway.app").rstrip("/")
url, key, pub = os.environ["SUPABASE_URL"].rstrip("/"), os.environ["SUPABASE_SECRET_KEY"], os.environ["SUPABASE_PUBLISHABLE_KEY"]
AH = {"apikey": key, "Authorization": f"Bearer {key}", "Content-Type": "application/json"}
def admin(m, p, b=None):
    r = httpx.request(m, url + p, json=b, headers=AH, timeout=30); r.raise_for_status(); return r.json() if r.content else None
email, pw = f"live-{secrets.token_hex(4)}@test.local", secrets.token_urlsafe(24)
uid = admin("POST", "/auth/v1/admin/users", {"email": email, "email_confirm": True, "password": pw})["id"]
try:
    tok = httpx.post(url + "/auth/v1/token?grant_type=password", json={"email": email, "password": pw}, headers={"apikey": pub}, timeout=30).json()["access_token"]
    t = "tk_" + secrets.token_urlsafe(24)
    admin("POST", "/rest/v1/ingest_tokens", {"user_id": uid, "token_hash": hashlib.sha256(t.encode()).hexdigest(), "last4": t[-4:]})
    r = httpx.post(BASE + "/ingest", json={"source": "sms", "text": "Chase: A $18.40 transaction was made at UBER *TRIP on card ending in 4421."}, headers={"X-Tick-Token": t}, timeout=30); print("ingest", r.status_code, r.json())
    assert r.status_code == 200 and r.json()["action"] == "insert"
    r = httpx.post(BASE + "/ingest", json={"source": "sms", "text": "x"}, headers={"X-Tick-Token": "tk_wrong"}, timeout=30); print("bad token", r.status_code); assert r.status_code == 401
    r = httpx.get(BASE + "/plaid/links", headers={"Authorization": f"Bearer {tok}"}, timeout=30); print("links", r.status_code, r.json()); assert r.json()["cap"] == 10
    r = httpx.get(BASE + "/plaid/links", timeout=30); assert r.status_code == 401
    with httpx.stream("POST", BASE + "/ask", json={"question": "How much did I spend on food this month?"}, headers={"Authorization": f"Bearer {tok}"}, timeout=40) as s:
        body = "".join(s.iter_text()); print("ask", s.status_code, body[:300].replace("\n", " "))
        assert s.status_code == 200 and '"type": "done"' in body
    r = httpx.post(BASE + "/jobs/sync-all", timeout=30); assert r.status_code == 401
    print("DEPLOYED E2E OK")
finally:
    admin("DELETE", f"/auth/v1/admin/users/{uid}")
