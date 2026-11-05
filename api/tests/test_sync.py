"""Bank sync: state machine, every webhook and error code, pagination, the mutation restart, and credit-card rows landing (Part 0)."""
from datetime import datetime, timezone

import httpx
import pytest
from fastapi import BackgroundTasks

from app import audit as audit_mod, plaid as P, store
from tests.fakerest import FakeRest

U = "11111111-1111-1111-1111-111111111111"
CATS = ["Groceries", "Restaurants", "Coffee", "Transfer", "Income", "Other", "Fees and interest", "Loan payment", "Shopping", "Software", "Rideshare", "Friends and family"]

def txn(i, acct, amount, name="STARBUCKS", **kw):
    return {"transaction_id": f"t{i}", "account_id": acct, "amount": amount, "date": "2026-11-03", "name": name, "pending": False,
            "personal_finance_category": {"primary": "FOOD_AND_DRINK", "detailed": ""}, **kw}

class Prov:
    """A sandbox-shaped provider: scripted /transactions/sync pages and errors."""
    def __init__(self, pages=None, accounts=None, errors=None):
        self.pages = pages or [{"added": [], "modified": [], "removed": [], "next_cursor": "c1", "has_more": False}]
        self.errors = list(errors or [])
        self.calls: list[str | None] = []
        self._accounts = accounts or [{"account_id": "cc1", "name": "Visa", "mask": "5498", "type": "credit", "subtype": "credit card", "balances": {"current": 321.79, "limit": 3000}},
                                      {"account_id": "ck1", "name": "Checking", "mask": "9681", "type": "depository", "subtype": "checking", "balances": {"current": 960.95, "available": 960.95}}]
    def accounts(self, token): return self._accounts
    def sync_page(self, token, cursor):
        self.calls.append(cursor)
        if self.errors:
            e = self.errors.pop(0)
            if e:
                raise e
        idx = 0 if cursor in (None, "start") else int(cursor.lstrip("c")) if cursor.startswith("c") and cursor[1:].isdigit() else 0
        return self.pages[min(idx, len(self.pages) - 1)]

@pytest.fixture
def env(monkeypatch):
    f = FakeRest()
    for mod in (P, store, audit_mod):
        monkeypatch.setattr(mod, "rest", lambda: f)
    for n in CATS:
        f.insert("categories", {"user_id": U, "name": n})
    sid = f.rpc("tick_vault_upsert", {"secret_name": "plaid-x", "secret_value": "access-sandbox-fake"})
    conn = f.insert("connections", {"user_id": U, "provider": "plaid", "item_id": "item-x", "institution": "Bank of America", "vault_secret_id": sid,
                                    "status": "active", "sync_state": "pending", "products": ["transactions"], "cursor": None})[0]
    def rows_between(user_id, lo, hi):
        return [store.row_to_txn(r) for r in f.rows("transactions") if r["user_id"] == user_id]
    monkeypatch.setattr(store, "window_range", rows_between)
    monkeypatch.setattr(store, "by_plaid_ids", lambda uid, ids: [store.row_to_txn(r) for r in f.rows("transactions") if r.get("plaid_transaction_id") in ids])
    monkeypatch.setattr(P, "_ai_categorise", lambda *a, **k: None)
    return f, conn

def state(f): return f.rows("connections")[0]

def test_credit_card_page_with_mixed_tags_lands_and_marks_ok(env):
    """The regression behind 'Discover and Bank of America have no transactions': rows with and without tags in ONE bulk insert."""
    f, conn = env
    page = {"added": [txn(1, "cc1", 12.0, "STARBUCKS"), txn(2, "cc1", -19.99, "AMAZON REFUND"), txn(3, "cc1", 22.0, "CURSOR AI POWERED IDE"), txn(4, "ck1", 5.0, "PUBLIX")],
            "modified": [], "removed": [], "next_cursor": "c1", "has_more": False}
    P.sync_connection(conn, Prov([page]))
    rows = f.rows("transactions")
    assert len(rows) == 4 and all(isinstance(r["tags"], list) for r in rows)
    by = {r["plaid_transaction_id"]: r for r in rows}
    assert by["t1"]["amount_cents"] == -1200 and by["t2"]["amount_cents"] == 1999            # card refund is money back, not income
    assert state(f)["sync_state"] == "ok" and state(f)["last_error"] is None and state(f)["last_added"] == 4 and state(f)["cursor"] == "c1"
    accts = {a["mask"]: a for a in f.rows("accounts")}
    assert accts["5498"]["type"] == "credit" and accts["5498"]["balance_cents"] == -32179 and accts["9681"]["type"] == "checking"

def test_one_bad_row_never_loses_the_page(env, monkeypatch):
    f, conn = env
    real = f.insert
    def flaky(table, row, **kw):
        if table == "transactions" and isinstance(row, list):
            req = httpx.Request("POST", "http://x"); raise httpx.HTTPStatusError("400", request=req, response=httpx.Response(400, request=req))
        if table == "transactions" and row.get("plaid_transaction_id") == "t2":
            req = httpx.Request("POST", "http://x"); raise httpx.HTTPStatusError("400", request=req, response=httpx.Response(400, request=req))
        return real(table, row, **kw)
    monkeypatch.setattr(f, "insert", flaky)
    page = {"added": [txn(1, "cc1", 1.0), txn(2, "cc1", 2.0), txn(3, "cc1", 3.0)], "modified": [], "removed": [], "next_cursor": "c1", "has_more": False}
    P.sync_connection(conn, Prov([page]))
    assert sorted(r["plaid_transaction_id"] for r in f.rows("transactions")) == ["t1", "t3"]

def test_has_more_pagination_saves_the_cursor_only_after_the_last_page(env):
    f, conn = env
    pages = [{"added": [txn(1, "cc1", 1.0)], "modified": [], "removed": [], "next_cursor": "c1", "has_more": True},
             {"added": [txn(2, "cc1", 2.0)], "modified": [], "removed": [], "next_cursor": "c2", "has_more": True},
             {"added": [txn(3, "cc1", 3.0)], "modified": [], "removed": [], "next_cursor": "c3", "has_more": False}]
    prov = Prov(pages)
    seen = []
    real_mark = P.mark
    P.sync_connection(conn, prov)
    assert prov.calls == [None, "c1", "c2"] and len(f.rows("transactions")) == 3 and state(f)["cursor"] == "c3"

def test_failure_midway_keeps_the_old_cursor_and_reruns_idempotently(env):
    f, conn = env
    pages = [{"added": [txn(1, "cc1", 1.0)], "modified": [], "removed": [], "next_cursor": "c1", "has_more": True},
             {"added": [txn(2, "cc1", 2.0)], "modified": [], "removed": [], "next_cursor": "c2", "has_more": False}]
    boom = P.PlaidError("INTERNAL_SERVER_ERROR", "API_ERROR", 500)
    P.sync_connection(conn, Prov(pages, errors=[None, boom]))
    assert state(f)["cursor"] is None and state(f)["sync_state"] == "bank_issue" and state(f)["last_error"] == "INTERNAL_SERVER_ERROR"
    assert len(f.rows("transactions")) == 1
    P.sync_connection({**conn, "cursor": None}, Prov(pages))                 # the retry re-reads page 1: no duplicate
    assert len(f.rows("transactions")) == 2 and state(f)["sync_state"] == "ok" and state(f)["cursor"] == "c2"

def test_mutation_during_pagination_restarts_from_the_saved_cursor(env):
    f, conn = env
    conn = {**conn, "cursor": "c0"}
    pages = [{"added": [txn(1, "cc1", 1.0)], "modified": [], "removed": [], "next_cursor": "c1", "has_more": False}]
    prov = Prov(pages, errors=[None, P.PlaidError(P.MUTATION, "TRANSACTIONS_ERROR", 400)])
    prov.pages = [{"added": [txn(1, "cc1", 1.0)], "modified": [], "removed": [], "next_cursor": "c1", "has_more": True},
                  {"added": [txn(2, "cc1", 2.0)], "modified": [], "removed": [], "next_cursor": "c2", "has_more": False}]
    P.sync_connection(conn, prov)
    assert prov.calls[:3] == ["c0", "c1", "c0"] and state(f)["sync_state"] == "ok" and len(f.rows("transactions")) >= 1

@pytest.mark.parametrize("code,expected", [
    ("ITEM_LOGIN_REQUIRED", "login_required"), ("PENDING_EXPIRATION", "login_required"), ("USER_PERMISSION_REVOKED", "login_required"),
    ("INSTITUTION_DOWN", "bank_issue"), ("INSTITUTION_NOT_RESPONDING", "bank_issue"), ("INTERNAL_SERVER_ERROR", "bank_issue"),
    ("PRODUCT_NOT_READY", "syncing"), ("NEW_ACCOUNTS_AVAILABLE", "partial"), ("ADDITIONAL_CONSENT_REQUIRED", "partial"), ("SOMETHING_NEW", "error")])
def test_every_error_code_maps_to_an_honest_state(env, code, expected):
    f, conn = env
    P.sync_connection(conn, Prov(errors=[P.PlaidError(code, "ITEM_ERROR", 400)]))
    assert state(f)["sync_state"] == expected and state(f)["last_error"] == code
    assert state(f)["status"] == ("login_required" if expected == "login_required" else ("active" if expected == "syncing" else "error"))

def test_an_unexpected_exception_is_recorded_not_swallowed(env, monkeypatch):
    f, conn = env
    monkeypatch.setattr(P, "plaid_candidate", lambda *a, **k: (_ for _ in ()).throw(KeyError("x")))
    with pytest.raises(KeyError):
        P.sync_connection(conn, Prov([{"added": [txn(1, "cc1", 1.0)], "modified": [], "removed": [], "next_cursor": "c1", "has_more": False}]))
    assert state(f)["sync_state"] == "error" and state(f)["last_error"] == "KeyError" and state(f)["error_code"] == "SYNC_FAILED"
    P._safe_sync(conn)                                                         # the background wrapper never raises

def _webhook(f, monkeypatch, typ, code, **extra):
    import json as _j
    body = _j.dumps({"webhook_type": typ, "webhook_code": code, "item_id": "item-x", **extra}).encode()
    monkeypatch.setattr(P, "verify_webhook", lambda *a, **k: {})
    bg = BackgroundTasks()
    P._handle_webhook(body, "sig", bg)
    return bg

@pytest.mark.parametrize("typ,code,extra,expect_sync,expect", [
    ("TRANSACTIONS", "SYNC_UPDATES_AVAILABLE", {"initial_update_complete": True, "historical_update_complete": False}, True, {"initial_complete": True, "historical_complete": False}),
    ("TRANSACTIONS", "INITIAL_UPDATE", {}, True, {"initial_complete": True}),
    ("TRANSACTIONS", "HISTORICAL_UPDATE", {}, True, {"historical_complete": True}),
    ("TRANSACTIONS", "DEFAULT_UPDATE", {}, True, {}),
    ("TRANSACTIONS", "TRANSACTIONS_REMOVED", {}, True, {}),
    ("ITEM", "ERROR", {"error": {"error_code": "ITEM_LOGIN_REQUIRED"}}, False, {"sync_state": "login_required"}),
    ("ITEM", "ERROR", {"error": {"error_code": "INSTITUTION_DOWN"}}, False, {"sync_state": "bank_issue"}),
    ("ITEM", "PENDING_EXPIRATION", {}, False, {"sync_state": "login_required"}),
    ("ITEM", "PENDING_DISCONNECT", {}, False, {"sync_state": "login_required"}),
    ("ITEM", "USER_PERMISSION_REVOKED", {}, False, {"sync_state": "login_required"}),
    ("ITEM", "NEW_ACCOUNTS_AVAILABLE", {}, False, {"sync_state": "partial"}),
    ("ITEM", "LOGIN_REPAIRED", {}, True, {"sync_state": "syncing"}),
    ("ITEM", "WEBHOOK_UPDATE_ACKNOWLEDGED", {}, False, {}),
    ("LIABILITIES", "DEFAULT_UPDATE", {}, True, {}),
])
def test_every_webhook_code_is_handled_and_recorded(env, monkeypatch, typ, code, extra, expect_sync, expect):
    f, conn = env
    bg = _webhook(f, monkeypatch, typ, code, **extra)
    c = state(f)
    assert c["last_webhook_code"] == f"{typ}:{code}" and c["last_webhook_at"]
    for k, v in expect.items():
        assert c[k] == v, (k, c[k])
    assert bool(bg.tasks) is expect_sync

def test_login_repaired_then_sync_goes_back_to_ok(env, monkeypatch):
    f, conn = env
    P.sync_connection(conn, Prov(errors=[P.PlaidError("ITEM_LOGIN_REQUIRED", "ITEM_ERROR", 400)]))
    assert state(f)["sync_state"] == "login_required"
    _webhook(f, monkeypatch, "ITEM", "LOGIN_REPAIRED")
    assert state(f)["sync_state"] == "syncing" and state(f)["status"] == "active"
    P.sync_connection(state(f), Prov())
    assert state(f)["sync_state"] == "ok" and state(f)["last_error"] is None

def test_stuck_cron_only_retries_what_needs_it(env, monkeypatch):
    f, conn = env
    old = "2026-01-01T00:00:00+00:00"
    f.update("connections", {"id": conn["id"]}, {"sync_state": "syncing", "last_attempt_at": old})
    f.insert("connections", {"user_id": U, "provider": "plaid", "item_id": "i2", "vault_secret_id": "v", "status": "login_required", "sync_state": "login_required"})
    f.insert("connections", {"user_id": U, "provider": "plaid", "item_id": "i3", "vault_secret_id": "v", "status": "active", "sync_state": "ok"})
    f.insert("connections", {"user_id": U, "provider": "plaid", "item_id": "i4", "vault_secret_id": "v", "status": "active", "sync_state": "syncing",
                             "last_attempt_at": datetime.now(timezone.utc).isoformat()})                   # tried a moment ago
    bg = BackgroundTasks()
    assert P.sync_all(bg, stuck=True) == {"queued": 1}
    assert P.sync_all(BackgroundTasks(), stuck=False) == {"queued": 3}          # the 6-hourly pass skips only the ones needing a person

def test_manual_refresh_asks_the_bank_then_syncs(env, monkeypatch):
    f, conn = env
    calls = []
    class RP(Prov):
        def refresh(self, token): calls.append("refresh")
    monkeypatch.setattr(P, "_provider", RP())
    monkeypatch.setattr(P, "sync_connection", lambda c, prov=None: calls.append("sync"))
    P._safe_sync(conn, True)
    assert calls == ["refresh", "sync"]
    monkeypatch.setattr(RP, "refresh", lambda self, t: (_ for _ in ()).throw(P.PlaidError("PRODUCT_NOT_ENABLED", "x", 400)))
    calls.clear(); P._safe_sync(conn, True)
    assert calls == ["sync"]                                                   # refresh refused: still sync what we can

def test_update_mode_link_token_selects_accounts_without_products(monkeypatch):
    sent = []
    class Http:
        def post(self, path, json): sent.append(dict(json)); return type("R", (), {"status_code": 200, "json": lambda self: {"link_token": "link-x"}})()
    prov = P.PlaidProvider("c", "s", "sandbox", "https://x/webhooks/plaid"); prov.http = Http()
    prov.create_link_token("U", access_token="access-sandbox-x", accounts=True)
    assert sent[0]["update"] == {"account_selection_enabled": True} and "products" not in sent[0]

def test_a_brand_new_item_says_syncing_history_until_plaid_says_complete_or_it_is_no_longer_new(env, monkeypatch):
    f, conn = env
    fresh = {**conn, "created_at": datetime.now(timezone.utc).isoformat()}
    P.sync_connection(fresh, Prov())
    assert state(f)["sync_state"] == "syncing" and state(f)["initial_complete"] is True and state(f)["last_synced_at"]
    P.sync_connection({**fresh, "historical_complete": True}, Prov())                  # HISTORICAL_UPDATE webhook arrived
    assert state(f)["sync_state"] == "ok"
    f.update("connections", {"id": conn["id"]}, {"sync_state": "syncing", "historical_complete": False})
    P.sync_connection({**conn, "created_at": "2026-01-01T00:00:00+00:00"}, Prov())     # webhook never came, but it is not new: do not spin forever
    assert state(f)["sync_state"] == "ok"
