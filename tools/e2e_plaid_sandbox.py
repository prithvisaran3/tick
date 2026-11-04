#!/usr/bin/env python3
"""Plaid SANDBOX end-to-end: sandbox Item -> Vault -> sync -> reconcile -> idempotent re-sync. Uses PLAID_SANDBOX_SECRET only (never production).
Throwaway auth user is deleted at the end (cascade)."""
import json, os, secrets, sys, time, urllib.request
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "api"))
from app import plaid as P, store
from app.db import rest
url, key = os.environ["SUPABASE_URL"].rstrip("/"), os.environ["SUPABASE_SECRET_KEY"]
H = {"apikey": key, "Authorization": f"Bearer {key}", "Content-Type": "application/json"}
def call(m, path, body=None):
    r = urllib.request.Request(url + path, method=m, data=json.dumps(body).encode() if body is not None else None, headers=H)
    with urllib.request.urlopen(r, timeout=30) as resp:
        t = resp.read(); return json.loads(t) if t else None
prov = P.PlaidProvider(os.environ["PLAID_CLIENT_ID"], os.environ["PLAID_SANDBOX_SECRET"], "sandbox", "https://example.invalid/webhooks/plaid")
uid = call("POST", "/auth/v1/admin/users", {"email": f"plaid-{secrets.token_hex(4)}@test.local", "email_confirm": True, "password": secrets.token_urlsafe(24)})["id"]
access = None
try:
    pt = prov._post("/sandbox/public_token/create", {"institution_id": "ins_109508", "initial_products": ["transactions"]})["public_token"]
    access, item_id = prov.exchange(pt)
    time.sleep(4)
    sid = rest().rpc("tick_vault_put", {"secret_name": f"sandbox-{item_id}", "secret_value": access})
    assert rest().rpc("tick_vault_get", {"secret_id": sid}) == access
    conn = rest().insert("connections", {"user_id": uid, "provider": "plaid", "institution": "Sandbox", "item_id": item_id, "vault_secret_id": sid})[0]
    c1 = P.sync_connection(conn, prov); print("sync1", c1)
    n1 = len(rest().select("transactions", user_id=f"eq.{uid}", select="id"))
    conn = rest().select("connections", id=f"eq.{conn['id']}")[0]
    assert conn["cursor"] and conn["last_synced_at"] and conn["status"] == "active"
    c2 = P.sync_connection(conn, prov); print("sync2", c2)
    n2 = len(rest().select("transactions", user_id=f"eq.{uid}", select="id"))
    accts = rest().select("accounts", user_id=f"eq.{uid}", select="name,type,balance_cents,available_cents,mask")
    print("txns", n1, n2, "accounts", accts[:2])
    assert n1 > 0 and n1 == n2, "re-sync must not duplicate"
    # tokens never in the connections row
    assert access not in json.dumps(conn)
    # simulate a SMS for the same purchase landing after Plaid: must merge, not double count
    row = rest().select("transactions", user_id=f"eq.{uid}", amount_cents="lt.0", order="occurred_at.desc", limit="1")[0]
    from datetime import datetime
    from app.reconcile import Candidate, decide
    when = datetime.fromisoformat(row["occurred_at"].replace("Z", "+00:00"))
    cand = Candidate("sms", "sms-x", row["amount_cents"], when, row["merchant_raw"] or "", "", None, "posted", confidence=0.9)
    act = decide(cand, store.window(uid, when))
    print("late sms ->", act.kind, act.reason); assert act.kind == "update"
    print("PLAID SANDBOX E2E OK")
finally:
    if access:
        try: prov._post("/item/remove", {"access_token": access})
        except Exception: pass
    call("DELETE", f"/auth/v1/admin/users/{uid}")
