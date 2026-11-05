"""Plaid slot-burn regression tests (Part 1). Never talks to Plaid: a fake provider stands in for the sandbox."""
import threading
import time

import httpx
import pytest
from fastapi.testclient import TestClient

from app import audit as audit_mod
from app import plaid as P
from app.auth import current_user
from app.main import app
from tests.fakerest import FakeRest

U = "11111111-1111-1111-1111-111111111111"

class FakeProv:
    """One Link session that produced one Item (item-1). Exchanging the same public token again returns the same item_id,
    exactly what production did on 2026-11-05 (two 200s, one item_id)."""
    def __init__(self, delay=0.0, item_id="item-1"):
        self.delay, self.item_id, self.exchanges, self.lock = delay, item_id, 0, threading.Lock()
    def link_token_result(self, lt): return ["public-1"]
    def exchange(self, pt):
        with self.lock:
            self.exchanges += 1
            n = self.exchanges
        time.sleep(self.delay)
        return f"access-sandbox-{n}", self.item_id
    def item_institution(self, access): return "Chase"
    def accounts(self, access): return []
    def sync_page(self, access, cursor): return {"added": [], "modified": [], "removed": [], "next_cursor": "c", "has_more": False}

@pytest.fixture
def db(monkeypatch):
    f = FakeRest()
    monkeypatch.setattr(P, "rest", lambda: f)
    monkeypatch.setattr(audit_mod, "rest", lambda: f)
    f.insert("plaid_link_sessions", {"link_token": "link-production-abc", "user_id": U, "connection_id": None, "claimed_at": None,
                                     "finished_at": None, "connection_ids": []})
    return f

def test_double_exchange_of_one_session_counts_one_link(db):
    prov = FakeProv()
    a = P.finish_link(U, "link-production-abc", sync_now=False, prov=prov)
    b = P.finish_link(U, "link-production-abc", sync_now=False, prov=prov)
    assert len(a) == 1 and [c["id"] for c in b] == [a[0]["id"]]
    assert prov.exchanges == 1                                   # the second call never even exchanged again
    assert P.links_used(U) == 1 and len(db.rows("connections")) == 1 and len(db.vault) == 1
    assert a[0].get("_new") and not b[0].get("_new")              # only the creator schedules the first sync

def test_webhook_and_app_racing_on_the_same_session_create_one_item(db):
    """Reproduces the production race: SESSION_FINISHED webhook and POST /plaid/complete land within 300 ms."""
    prov = FakeProv(delay=0.3)
    results: dict[str, list] = {}
    def run(name, wait):
        results[name] = P.finish_link(U, "link-production-abc", sync_now=False, prov=prov, wait_s=wait)
    t1 = threading.Thread(target=run, args=("webhook", 0)); t2 = threading.Thread(target=run, args=("app", 5))
    t1.start(); time.sleep(0.05); t2.start(); t1.join(); t2.join()
    assert prov.exchanges == 1
    assert P.links_used(U) == 1 and len(db.rows("connections")) == 1 and len(db.vault) == 1
    assert [c["id"] for c in results["app"]] == [c["id"] for c in results["webhook"]]   # the app waited and got the same row
    assert "tick_vault_put" not in db.rpcs

def test_retry_after_timeout_reuses_the_item_and_vault_entry(db, monkeypatch):
    """First attempt exchanges, then times out before the connection row is written. The retry must not count a second link."""
    prov = FakeProv()
    real_insert = db.insert
    calls = {"n": 0}
    def flaky(table, row, **kw):
        if table == "connections" and calls["n"] == 0:
            calls["n"] += 1
            raise httpx.ReadTimeout("timed out")
        return real_insert(table, row, **kw)
    monkeypatch.setattr(db, "insert", flaky)
    with pytest.raises(httpx.ReadTimeout):
        P.finish_link(U, "link-production-abc", sync_now=False, prov=prov)
    assert db.rows("plaid_link_sessions")[0]["claimed_at"] is None          # claim released so the retry can run
    again = P.finish_link(U, "link-production-abc", sync_now=False, prov=prov)
    assert len(again) == 1 and prov.exchanges == 2                          # Plaid lets the same public token be exchanged again
    assert P.links_used(U) == 1 and len(db.vault) == 1                      # same item_id -> one slot, one Vault entry (upsert)

def test_stale_claim_from_a_crashed_finisher_can_be_taken_over(db):
    from datetime import datetime, timedelta, timezone
    db.rows("plaid_link_sessions")[0]["claimed_at"] = (datetime.now(timezone.utc) - timedelta(minutes=5)).isoformat()
    assert len(P.finish_link(U, "link-production-abc", sync_now=False, prov=FakeProv())) == 1

def test_live_claim_makes_the_loser_return_empty_not_create(db):
    from datetime import datetime, timezone
    db.rows("plaid_link_sessions")[0]["claimed_at"] = datetime.now(timezone.utc).isoformat()
    prov = FakeProv()
    assert P.finish_link(U, "link-production-abc", sync_now=False, prov=prov, wait_s=0) == []
    assert prov.exchanges == 0 and P.links_used(U) == 0

def test_links_used_counts_distinct_item_ids_including_removed(db):
    db.insert("plaid_items", {"item_id": "i1", "user_id": U})
    db.insert("plaid_items", {"item_id": "i2", "user_id": U, "removed_at": "2026-11-01T00:00:00+00:00"})
    db.insert("connections", {"user_id": U, "provider": "plaid", "item_id": "i1", "status": "active"})
    db.insert("connections", {"user_id": U, "provider": "plaid", "item_id": "i2", "status": "removed"})
    db.insert("plaid_slots", {"user_id": U, "used": 7})                      # the old inflated counter is ignored
    assert P.links_used(U) == 2
    P.record_item(U, "i1", "Chase", "link-x")                                 # recording again is a no-op
    assert P.links_used(U) == 2

def test_complete_route_twice_returns_same_connection_and_one_link(db, monkeypatch):
    monkeypatch.setattr(P, "_provider", FakeProv())
    monkeypatch.setattr(P, "_safe_sync", lambda conn: None)
    app.dependency_overrides[current_user] = lambda: U
    try:
        c = TestClient(app)
        r1 = c.post("/plaid/complete", json={"link_token": "link-production-abc"})
        r2 = c.post("/plaid/complete", json={"link_token": "link-production-abc"})
        assert r1.status_code == 200 and r2.status_code == 200
        assert r1.json()["connections"] == r2.json()["connections"] and r2.json()["used"] == 1
        assert c.post("/plaid/complete", json={"link_token": "link-production-unknown"}).status_code == 404
    finally:
        app.dependency_overrides.clear()

def test_complete_route_rejects_someone_elses_session(db, monkeypatch):
    monkeypatch.setattr(P, "_provider", FakeProv())
    app.dependency_overrides[current_user] = lambda: "22222222-2222-2222-2222-222222222222"
    try:
        assert TestClient(app).post("/plaid/complete", json={"link_token": "link-production-abc"}).status_code == 403
    finally:
        app.dependency_overrides.clear()
    assert P.links_used(U) == 0
