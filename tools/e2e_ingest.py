#!/usr/bin/env python3
"""End-to-end check of /ingest against the live Supabase project (uses a throwaway auth user, deleted at the end).
Usage: e2e_ingest.py [base_url]   (no arg = in-process FastAPI TestClient). Never prints secrets."""
import hashlib, json, os, sys, secrets, urllib.request
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "api"))
url, key = os.environ["SUPABASE_URL"].rstrip("/"), os.environ["SUPABASE_SECRET_KEY"]
H = {"apikey": key, "Authorization": f"Bearer {key}", "Content-Type": "application/json"}

def call(method, path, body=None, headers=None):
    r = urllib.request.Request(url + path, method=method, data=json.dumps(body).encode() if body is not None else None, headers=headers or H)
    try:
        with urllib.request.urlopen(r, timeout=30) as resp:
            t = resp.read(); return json.loads(t) if t else None
    except urllib.error.HTTPError as e:
        raise SystemExit(f"{method} {path} -> {e.code} {e.read().decode()[:300]}")

email = f"e2e-{secrets.token_hex(4)}@test.local"
u = call("POST", "/auth/v1/admin/users", {"email": email, "email_confirm": True, "password": secrets.token_urlsafe(24)})
uid = u["id"]
token = "tk_" + secrets.token_urlsafe(24)
try:
    call("POST", "/rest/v1/ingest_tokens", {"user_id": uid, "token_hash": hashlib.sha256(token.encode()).hexdigest(), "last4": token[-4:]})
    if len(sys.argv) > 1:
        import httpx
        post = lambda b: httpx.post(sys.argv[1] + "/ingest", json=b, headers={"X-Tick-Token": token}, timeout=30)
    else:
        from fastapi.testclient import TestClient
        from app.main import app
        c = TestClient(app); post = lambda b: c.post("/ingest", json=b, headers={"X-Tick-Token": token})
    def txns(): return call("GET", f"/rest/v1/transactions?user_id=eq.{uid}&select=amount_cents,merchant_clean,sources,needs_review,confidence,tags,category_id")
    r1 = post({"source": "sms", "text": "Chase: A $18.40 transaction was made at UBER *TRIP on card ending in 4421."}); print("sms", r1.status_code, r1.json())
    r2 = post({"source": "applepay", "merchant": "Uber", "amount": "18.40", "card": "Chase Freedom Visa 4421"}); print("applepay", r2.status_code, r2.json())
    r3 = post({"source": "sms", "text": "Your card was charged $12.00 at JOES PIZZA."}); print("low-conf", r3.status_code, r3.json())
    r4 = post({"source": "sms", "text": "Chase: A $22.00 transaction was made at CURSOR on card ending in 4421."}); print("business", r4.status_code, r4.json())
    r5 = post({"source": "sms", "text": "your code is 123456"}); print("junk", r5.status_code, r5.json())
    bad = httpx.post if False else None
    rows = txns(); print(json.dumps(rows, indent=1)[:1400])
    assert len(rows) == 3, f"expected 3 transactions (uber merged, pizza, cursor) got {len(rows)}"
    uber = [r for r in rows if r["amount_cents"] == -1840][0]
    assert {s["source"] for s in uber["sources"]} == {"sms", "applepay"}, uber
    assert [r for r in rows if r["amount_cents"] == -1200][0]["needs_review"] is True
    assert "business" in [r for r in rows if r["amount_cents"] == -2200][0]["tags"]
    logs = call("GET", f"/rest/v1/ingest_logs?user_id=eq.{uid}&select=status"); assert len(logs) == 5
    print("E2E OK")
finally:
    call("DELETE", f"/auth/v1/admin/users/{uid}")
