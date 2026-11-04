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
    P._keys.clear()

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
