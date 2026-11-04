import base64, hashlib, json, time
import jwt, pytest
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi import HTTPException

from app import plaid as P

def _b64(i: int) -> str:
    return base64.urlsafe_b64encode(i.to_bytes(32, "big")).rstrip(b"=").decode()

class FakeProv:
    def __init__(self, key):
        n = key.public_key().public_numbers()
        self.jwk = {"x": _b64(n.x), "y": _b64(n.y), "expired_at": None, "kid": "k1"}
        self.calls = 0
    def webhook_key(self, kid):
        self.calls += 1
        return self.jwk

def sign(key, body: bytes, iat=None, alg="ES256", kid="k1", digest=None):
    claims = {"iat": iat if iat is not None else int(time.time()), "request_body_sha256": digest or hashlib.sha256(body).hexdigest()}
    return jwt.encode(claims, key, algorithm=alg, headers={"kid": kid})

@pytest.fixture(autouse=True)
def clear():
    P._keys.clear(); P._bad_kids.clear(); P._key_fetches.clear()

def test_valid_webhook_and_key_cached():
    key = ec.generate_private_key(ec.SECP256R1()); prov = FakeProv(key); body = b'{"webhook_type":"TRANSACTIONS"}'
    assert P.verify_webhook(body, sign(key, body), prov)["request_body_sha256"]
    P.verify_webhook(body, sign(key, body), prov)
    assert prov.calls == 1

def test_stale_rejected():
    key = ec.generate_private_key(ec.SECP256R1()); prov = FakeProv(key); body = b"{}"
    with pytest.raises(HTTPException) as e:
        P.verify_webhook(body, sign(key, body, iat=int(time.time()) - 400), prov)
    assert e.value.status_code == 401

def test_body_tamper_rejected():
    key = ec.generate_private_key(ec.SECP256R1()); prov = FakeProv(key)
    with pytest.raises(HTTPException):
        P.verify_webhook(b'{"a":2}', sign(key, b'{"a":1}'), prov)

def test_wrong_key_and_garbage_rejected():
    key, other = ec.generate_private_key(ec.SECP256R1()), ec.generate_private_key(ec.SECP256R1()); prov = FakeProv(key); body = b"{}"
    with pytest.raises(HTTPException):
        P.verify_webhook(body, sign(other, body), prov)
    with pytest.raises(HTTPException):
        P.verify_webhook(body, "not-a-jwt", prov)

def test_non_es256_rejected():
    body = b"{}"
    tok = jwt.encode({"iat": int(time.time()), "request_body_sha256": hashlib.sha256(body).hexdigest()}, "secret" * 8, algorithm="HS256", headers={"kid": "k1"})
    with pytest.raises(HTTPException):
        P.verify_webhook(body, tok, FakeProv(ec.generate_private_key(ec.SECP256R1())))

def test_expired_key_rejected():
    key = ec.generate_private_key(ec.SECP256R1()); prov = FakeProv(key); prov.jwk["expired_at"] = 123; body = b"{}"
    with pytest.raises(HTTPException):
        P.verify_webhook(body, sign(key, body), prov)

def test_mapping_signs_pending_and_transfers():
    accts = {"a1": {"id": "acc-1", "mask": "1180"}}
    ids = {"Uber": "c-uber", "Transfer": "c-tr", "Income": "c-in", "Other": "c-o", "Rideshare": "c-ride"}
    t = {"transaction_id": "t1", "pending_transaction_id": "p0", "account_id": "a1", "amount": 18.4, "date": "2026-11-03", "name": "UBER *TRIP", "pending": False}
    c, tags = P.plaid_candidate(t, accts, {}, ids)
    assert c.amount_cents == -1840 and c.status == "posted" and c.plaid_pending_id == "p0" and c.card_last4 == "1180" and c.category_id == "c-ride"
    inc, _ = P.plaid_candidate({**t, "amount": -2310.0, "name": "PAYROLL", "pending": True}, accts, {}, ids)
    assert inc.amount_cents == 231000 and inc.status == "pending" and inc.category_id == "c-in"
    tr, _ = P.plaid_candidate({**t, "personal_finance_category": {"primary": "TRANSFER_OUT"}}, accts, {}, ids)
    assert tr.category_id == "c-tr"
    _, tags = P.plaid_candidate({**t, "name": "CURSOR AI"}, accts, {}, ids)
    assert tags == ["business"]

def test_base_urls():
    assert P.base_url("production").startswith("https://production")
    assert P.base_url("sandbox").startswith("https://sandbox")


def test_unknown_kid_is_negative_cached_and_fetches_are_rate_limited():
    class Boom:
        calls = 0
        def webhook_key(self, kid):
            Boom.calls += 1
            raise P.PlaidError("INVALID_WEBHOOK_VERIFICATION_KEY_ID", "INVALID_REQUEST", 400)
    key = ec.generate_private_key(ec.SECP256R1()); body = b"{}"
    tok = sign(key, body, kid="ghost")
    for _ in range(3):
        with pytest.raises(HTTPException) as e:
            P.verify_webhook(body, tok, Boom())
        assert e.value.status_code == 401
    assert Boom.calls == 1                       # the bad kid was remembered
    Boom.calls = 0
    for i in range(P.KEY_FETCHES_PER_MIN + 4):
        with pytest.raises(HTTPException):
            P.verify_webhook(body, sign(key, body, kid=f"k{i}"), Boom())
    assert Boom.calls == P.KEY_FETCHES_PER_MIN - 1   # garbage kids cannot hammer Plaid

def test_rotated_key_is_refetched_after_ttl(monkeypatch):
    key = ec.generate_private_key(ec.SECP256R1()); prov = FakeProv(key); body = b"{}"
    P.verify_webhook(body, sign(key, body), prov)
    P._keys["k1"] = (time.time() - 1, P._keys["k1"][1])      # TTL passed
    P.verify_webhook(body, sign(key, body), prov)
    assert prov.calls == 2

def test_header_alg_none_and_missing_kid_rejected():
    body = b"{}"
    tok = jwt.encode({"iat": int(time.time()), "request_body_sha256": hashlib.sha256(body).hexdigest()}, None, algorithm="none")
    with pytest.raises(HTTPException):
        P.verify_webhook(body, tok, FakeProv(ec.generate_private_key(ec.SECP256R1())))

def test_whitespace_sensitive_hash_uses_raw_body():
    key = ec.generate_private_key(ec.SECP256R1()); prov = FakeProv(key)
    pretty = json.dumps({"webhook_type": "TRANSACTIONS", "item_id": "i"}, indent=2).encode()
    assert P.verify_webhook(pretty, sign(key, pretty), prov)
    compact = json.dumps({"webhook_type": "TRANSACTIONS", "item_id": "i"}).encode()
    with pytest.raises(HTTPException):
        P.verify_webhook(compact, sign(key, pretty), prov)     # re-serialised body must NOT verify

# ---- route level: SESSION_FINISHED resolves the user through the stored link token ----
def test_session_finished_uses_stored_link_session(monkeypatch):
    from fastapi.testclient import TestClient
    from app.main import app
    key = ec.generate_private_key(ec.SECP256R1()); prov = FakeProv(key)
    monkeypatch.setattr(P, "provider", lambda: prov)
    finished = []
    monkeypatch.setattr(P, "_session_for_link_token", lambda lt: {"user_id": "user-1", "connection_id": None} if lt == "link-abc" else None)
    monkeypatch.setattr(P, "finish_link", lambda uid, lt, **kw: finished.append((uid, lt)) or [])
    class R:
        def select(self, *a, **k): return []
    monkeypatch.setattr(P, "rest", lambda: R())
    body = json.dumps({"webhook_type": "LINK", "webhook_code": "SESSION_FINISHED", "status": "success", "link_token": "link-abc", "public_tokens": ["public-x"]}, indent=2).encode()
    c = TestClient(app)
    r = c.post("/webhooks/plaid", content=body, headers={"Plaid-Verification": sign(key, body), "Content-Type": "application/json"})
    assert r.status_code == 200 and finished == [("user-1", "link-abc")]
    unknown = json.dumps({"webhook_type": "LINK", "webhook_code": "SESSION_FINISHED", "status": "success", "link_token": "link-zzz"}).encode()
    assert c.post("/webhooks/plaid", content=unknown, headers={"Plaid-Verification": sign(key, unknown)}).status_code == 200 and len(finished) == 1
    assert c.post("/webhooks/plaid", content=body, headers={"Plaid-Verification": "garbage"}).status_code == 401
    assert c.post("/webhooks/plaid", content=body).status_code == 401

def test_link_token_includes_redirect_only_when_configured(monkeypatch):
    sent = {}
    class Http:
        def post(self, path, json): sent.clear(); sent.update(json); return type("R", (), {"status_code": 200, "json": lambda self: {"link_token": "link-x"}})()
    pr = P.PlaidProvider("cid", "sec", "sandbox", "https://x/webhooks/plaid"); pr.http = Http()
    monkeypatch.delenv("PLAID_REDIRECT_URI", raising=False)
    pr.create_link_token("u1"); assert "redirect_uri" not in sent and sent["hosted_link"]["completion_redirect_uri"] == "tick://plaid-complete" and sent["products"] == ["transactions"]
    monkeypatch.setenv("PLAID_REDIRECT_URI", "https://tick-api-production.up.railway.app/plaid/oauth-return")
    pr.create_link_token("u1"); assert sent["redirect_uri"].endswith("/plaid/oauth-return")
    pr.create_link_token("u1", access_token="access-x"); assert sent["access_token"] == "access-x" and "products" not in sent
