#!/usr/bin/env python3
"""Live check of the deployed API and database after `supabase db push` + `railway up`: capture token minted by the server, ingest,
/ask (SSE), /plaid/links, the Activity RPCs through PostgREST with a real user JWT, security headers, and that anon gets nothing.
A throwaway user is created and deleted. It signs in with email + password, so run it BEFORE `tools/auth_config.py --apply`
(which turns email sign-in off), or switch email on for the run."""
import json, os, secrets, sys, urllib.request
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
    r = httpx.post(BASE + "/tokens", json={"label": "e2e"}, headers={"Authorization": f"Bearer {tok}"}, timeout=30)
    assert r.status_code == 200, r.status_code
    t = r.json()["token"]
    h = httpx.get(BASE + "/health", timeout=30)
    assert h.json() == {"ok": True} and h.headers.get("x-frame-options") == "DENY" and "strict-transport-security" in h.headers
    print("health + headers ok")
    r = httpx.post(BASE + "/ingest", json={"source": "sms", "text": "Chase: A $18.40 transaction was made at UBER *TRIP on card ending in 4421."}, headers={"X-Tick-Token": t}, timeout=30); print("ingest", r.status_code, r.json())
    assert r.status_code == 200 and r.json()["action"] == "insert"
    r = httpx.post(BASE + "/ingest", json={"source": "sms", "text": "x"}, headers={"X-Tick-Token": "tk_wrong"}, timeout=30); print("bad token", r.status_code); assert r.status_code == 401
    r = httpx.get(BASE + "/plaid/links", headers={"Authorization": f"Bearer {tok}"}, timeout=30); print("links", r.status_code, r.json()); assert r.json()["cap"] == 10
    r = httpx.get(BASE + "/plaid/links", timeout=30); assert r.status_code == 401
    with httpx.stream("POST", BASE + "/ask", json={"question": "How much did I spend on food this month?"}, headers={"Authorization": f"Bearer {tok}"}, timeout=40) as s:
        body = "".join(s.iter_text()); print("ask", s.status_code, body[:300].replace("\n", " "))
        assert s.status_code == 200 and '"type": "done"' in body
    r = httpx.post(BASE + "/jobs/sync-all", timeout=30); assert r.status_code == 401
    uh = {"apikey": pub, "Authorization": f"Bearer {tok}", "Content-Type": "application/json"}
    r = httpx.post(url + "/rest/v1/rpc/tick_flows", json={"p_from": None, "p_to": None}, headers=uh, timeout=30)
    assert r.status_code == 200 and r.json()["out"] == 1840, (r.status_code, r.text[:200]); print("tick_flows ok")
    r = httpx.post(url + "/rest/v1/rpc/tick_activity_page", json={"p_from": None, "p_to": None, "p_limit": 40}, headers=uh, timeout=30)
    assert r.status_code == 200 and len(r.json()["rows"]) == 1; print("tick_activity_page ok")
    r = httpx.post(url + "/rest/v1/rpc/tick_flows", json={"p_from": None, "p_to": None}, headers={"apikey": pub, "Content-Type": "application/json"}, timeout=30)
    assert r.status_code in (401, 403, 404), r.status_code; print("anon rpc refused")
    r = httpx.get(url + "/rest/v1/transactions?select=id", headers={"apikey": pub}, timeout=30)
    assert r.status_code in (401, 403) or r.json() == [], r.status_code; print("anon table read refused")
    print("DEPLOYED E2E OK")
finally:
    admin("DELETE", f"/auth/v1/admin/users/{uid}")
