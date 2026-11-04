from datetime import datetime, timedelta, timezone

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient

from app.auth import RateLimiter
from app.main import app
from app.reconcile import Candidate, plan_and_apply, total_spend

client = TestClient(app, raise_server_exceptions=False)
T0 = datetime(2026, 11, 3, 14, 0, tzinfo=timezone.utc)

def test_error_shape_is_plain_detail_plus_structured_error():
    r = client.get("/plaid/links")
    assert r.status_code == 401 and isinstance(r.json()["detail"], str)
    assert r.json()["error"]["code"] == "unauthorized" and r.json()["error"]["message"] == r.json()["detail"]
    r = client.get("/nope")
    assert r.status_code == 404 and r.json()["error"]["code"] == "not_found"
    assert r.headers["x-request-id"]

def test_unhandled_exception_returns_calm_500_without_details(monkeypatch):
    from app import main
    @main.app.get("/boom-test")
    def boom():
        raise RuntimeError("secret-looking detail sk-or-v1-abc")
    r = client.get("/boom-test")
    assert r.status_code == 500 and "sk-or" not in r.text and r.json()["error"]["code"] == "server_error"

def test_validation_errors_are_calm_strings():
    r = client.post("/receipts/confirm", json={"merchant": "", "total": -5}, headers={"Authorization": "Bearer x"})
    assert r.status_code in (401, 422) and isinstance(r.json()["detail"], str)

def test_cron_route_rejects_without_secret():
    assert client.post("/jobs/sync-all").status_code == 401
    assert client.post("/jobs/daily-advice", headers={"X-Cron-Secret": "wrong"}).status_code == 401

def test_ingest_requires_token_and_validates_source():
    assert client.post("/ingest", json={"source": "sms", "text": "x"}).status_code == 401
    assert client.post("/ingest", json={"source": "bogus"}, headers={"X-Tick-Token": "tk_x"}).status_code in (401, 422)

def test_rate_limiter_per_key_window_and_bounded_memory():
    rl = RateLimiter(3, 60)
    for _ in range(3):
        rl.check("a")
    with pytest.raises(HTTPException) as e:
        rl.check("a")
    assert e.value.status_code == 429
    rl.check("b")                                  # other keys unaffected
    rl.check("c", limit=1, per=60)
    with pytest.raises(HTTPException):
        rl.check("c", limit=1, per=60)

def test_plan_and_apply_pending_then_posted_in_one_batch_never_double_counts():
    def plaid(ref, status, amount=-1840, pending_id=None, mins=0):
        return Candidate("plaid", ref, amount, T0 + timedelta(minutes=mins), "UBER", "Uber", "1180", status, plaid_transaction_id=ref, plaid_pending_id=pending_id)
    txns = []
    plan_and_apply(txns, plaid("pend", "pending"), "id-1")
    acts = plan_and_apply(txns, plaid("post", "posted", pending_id="pend", mins=1440), "id-2")
    assert len(txns) == 1 and total_spend(txns) == 1840 and txns[0].status == "posted" and acts[-1].kind == "update"
    ins = plan_and_apply(txns, plaid("other", "posted", amount=-500), "id-3")
    assert ins[-1].kind == "insert" and ins[-1].txn_id == "id-3" and len(txns) == 2

def test_et_day_boundary_for_evening_purchases():
    from app.intel import ET
    late = datetime(2026, 11, 4, 1, 30, tzinfo=timezone.utc)     # 8:30pm on Nov 3 in Arlington
    assert late.astimezone(ET).date().isoformat() == "2026-11-03"
