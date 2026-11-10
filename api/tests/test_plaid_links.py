"""Plaid slot-burn regression tests (Part 1). Never talks to Plaid: a fake provider stands in for the sandbox."""
import threading
import time

import httpx
import pytest
from fastapi.testclient import TestClient

from app import audit as audit_mod
from app import pay as pay_mod
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
    monkeypatch.setattr(pay_mod, "rest", lambda: f)
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

# ---------------- owner lock and the global cap (audit 2026-11) ----------------
OTHER = "22222222-2222-2222-2222-222222222222"

class _TokenProv:
    def create_link_token(self, uid, access_token=None, accounts=False):
        return {"link_token": "link-production-new1234", "hosted_link_url": "https://hosted.plaid/x"}

def _as(user, fn):
    app.dependency_overrides[current_user] = lambda: user
    try:
        return fn(TestClient(app))
    finally:
        app.dependency_overrides.clear()

def test_links_route_owner_gets_can_link_and_both_counts(db, monkeypatch):
    monkeypatch.setenv("TICK_OWNER_USER_IDS", U)
    for i in range(3):
        db.insert("plaid_items", {"item_id": f"o{i}", "user_id": U})
    db.insert("plaid_items", {"item_id": "x1", "user_id": OTHER})
    j = _as(U, lambda c: c.get("/plaid/links")).json()
    assert j == {"used": 3, "cap": 10, "left": 7, "can_link": True, "total_left": 6}

def test_links_route_non_owner_cannot_link_and_sees_the_global_count(db, monkeypatch):
    monkeypatch.setenv("TICK_OWNER_USER_IDS", U)
    for i in range(4):
        db.insert("plaid_items", {"item_id": f"o{i}", "user_id": U})
    j = _as(OTHER, lambda c: c.get("/plaid/links")).json()
    assert j["can_link"] is False and j["used"] == 0 and j["total_left"] == 6     # per-user "10 left" is a lie; the global number is not

def test_non_owner_link_token_is_403_with_a_clear_reason(db, monkeypatch):
    monkeypatch.setenv("TICK_OWNER_USER_IDS", U)
    monkeypatch.setattr(P, "_provider", _TokenProv())
    r = _as(OTHER, lambda c: c.post("/plaid/link-token", json={}))
    assert r.status_code == 403 and r.json()["detail"] == P.LINK_LIMITED
    assert db.rows("plaid_link_sessions")[-1]["user_id"] == U              # no session was opened for the stranger

def test_owner_gets_409_when_the_shared_cap_is_used_even_if_their_own_count_is_low(db, monkeypatch):
    monkeypatch.setenv("TICK_OWNER_USER_IDS", U)
    monkeypatch.setattr(P, "_provider", _TokenProv())
    for i in range(10):
        db.insert("plaid_items", {"item_id": f"i{i}", "user_id": OTHER if i else U})
    r = _as(U, lambda c: c.post("/plaid/link-token", json={}))
    assert r.status_code == 409 and r.json()["detail"] == P.LINK_LIMITED

def test_owner_can_start_a_link_when_slots_are_left(db, monkeypatch):
    monkeypatch.setenv("TICK_OWNER_USER_IDS", U)
    monkeypatch.setattr(P, "_provider", _TokenProv())
    r = _as(U, lambda c: c.post("/plaid/link-token", json={}))
    assert r.status_code == 200 and r.json()["links_left"] == 10

def test_non_owner_can_still_reconnect_their_own_connection(db, monkeypatch):
    """Update mode never creates an Item, so the owner lock does not apply to a connection the user already has."""
    monkeypatch.setenv("TICK_OWNER_USER_IDS", U)
    monkeypatch.setattr(P, "_provider", _TokenProv())
    conn = db.insert("connections", {"user_id": OTHER, "provider": "plaid", "item_id": "z", "vault_secret_id": "s1", "status": "login_required"})[0]
    monkeypatch.setattr(db, "rpc", lambda name, args: "access-x", raising=False)
    r = _as(OTHER, lambda c: c.post("/plaid/link-token", json={"connection_id": conn["id"]}))
    assert r.status_code == 200

def test_sync_keeps_the_name_and_include_in_safe_the_person_set(db):
    acct = {"account_id": "acc-1", "name": "Plaid Checking", "official_name": "Total Checking", "mask": "1173", "type": "depository", "subtype": "checking", "balances": {"current": 100.0, "available": 90.0}}
    first = P._ensure_accounts(U, "conn-1", [acct], "Chase")["acc-1"]
    db.update("accounts", {"id": first["id"]}, {"name": "Rent money", "include_in_safe": False})
    acct["balances"] = {"current": 250.5, "available": 200.0}
    again = P._ensure_accounts(U, "conn-1", [acct], "Chase")["acc-1"]
    rows = db.rows("accounts")
    assert len(rows) == 1 and again["id"] == first["id"]
    assert rows[0]["name"] == "Rent money" and rows[0]["include_in_safe"] is False      # edits survive
    assert rows[0]["balance_cents"] == 25050 and rows[0]["available_cents"] == 20000     # balances still refresh

def test_payday_rule_creates_expected_paychecks_once_and_a_deposit_lands_one(db):
    from datetime import date
    db.insert("settings", {"user_id": U, "payday_rule": {"frequency": "biweekly", "next_date": "2026-11-06", "amount_cents": 231000}})
    today = date(2026, 11, 7)
    P.ensure_expected_paycheck(U, today)
    P.ensure_expected_paycheck(U, today)                                  # idempotent
    rows = db.rows("expected")
    assert sorted(r["expected_date"] for r in rows) == ["2026-11-06", "2026-11-20"] and all(r["amount_cents"] == 231000 for r in rows)
    exp = [dict(r) for r in rows if r.get("status", "expected") == "expected"]
    from datetime import datetime as _dt, timezone as _tz
    P._landed_in(exp, U, "txn-1", 230500, _dt(2026, 11, 6, 13, tzinfo=_tz.utc))
    assert [r.get("status", "expected") for r in sorted(db.rows("expected"), key=lambda r: r["expected_date"])] == ["landed", "expected"]

def test_a_card_payment_credit_can_never_land_a_paycheck():
    class C: flow = None; account_id = "card"
    assert P._is_income_deposit(C, {"x": {"id": "card", "type": "credit"}}) is False
    C.account_id = "chk"
    assert P._is_income_deposit(C, {"x": {"id": "chk", "type": "checking"}}) is True
    C.flow = "transfer"
    assert P._is_income_deposit(C, {}) is False

def test_new_google_account_tapping_link_gets_403_before_any_plaid_call_or_session(db, monkeypatch):
    """The friend's case: signed in with her own Google account, no banks, no profile dependency, taps Link."""
    monkeypatch.delenv("TICK_OWNER_USER_IDS", raising=False)                # owner derived from the first item, as a fallback
    db.insert("plaid_items", {"item_id": "item-owner", "user_id": U, "created_at": "2026-11-05T01:35:00+00:00"})
    class Boom:
        def create_link_token(self, *a, **k): raise AssertionError("Plaid must not be called")
    monkeypatch.setattr(P, "_provider", Boom())
    before = len(db.rows("plaid_link_sessions"))
    r = _as(OTHER, lambda c: c.post("/plaid/link-token", json={}))
    assert r.status_code == 403 and r.json()["detail"] == "Bank linking is limited to 10 accounts right now."
    assert len(db.rows("plaid_link_sessions")) == before
    assert _as(OTHER, lambda c: c.get("/plaid/links")).json()["can_link"] is False

def test_a_paycheck_that_varies_lands_when_the_deposit_names_the_employer(db):
    from datetime import datetime as _dt, timezone as _tz
    exp = [{"id": "e1", "amount_cents": 231000, "expected_date": "2026-11-13", "label": "Institute Payroll"}]
    db.insert("expected", {"id": "e1", "user_id": U, "status": "expected", "amount_cents": 231000, "expected_date": "2026-11-13", "label": "Institute Payroll"})
    P._landed_in(list(exp), U, "t1", 190000, _dt(2026, 11, 13, 13, tzinfo=_tz.utc), "INSTITUTE OF NUC PAYROLL")
    assert db.rows("expected")[0]["status"] == "landed"

def test_a_far_off_amount_from_someone_else_does_not_land(db):
    from datetime import datetime as _dt, timezone as _tz
    exp = [{"id": "e1", "amount_cents": 231000, "expected_date": "2026-11-13", "label": "Institute Payroll"}]
    db.insert("expected", {"id": "e1", "user_id": U, "status": "expected", "amount_cents": 231000, "expected_date": "2026-11-13", "label": "Institute Payroll"})
    P._landed_in(list(exp), U, "t1", 190000, _dt(2026, 11, 13, 13, tzinfo=_tz.utc), "VENMO CASHOUT")
    assert db.rows("expected")[0]["status"] == "expected"
