"""Paycheck splits: the shared vectors, statement pre-fill, expected deposits per account, and landing without double counting."""
import json
import pathlib
from datetime import date, datetime, timezone

import pytest

from app import plaid as PL, splits as S
from tests.fakerest import FakeRest

CASES = json.loads((pathlib.Path(__file__).parent / "data" / "pay_splits.json").read_text())["cases"]
U = "11111111-1111-1111-1111-111111111111"

@pytest.mark.parametrize("c", CASES, ids=[c["name"] for c in CASES])
def test_vectors(c):
    got = S.split_amounts(c["net"], c["splits"])
    assert got == c["want"]
    if any(s["kind"] == "rest" for s in c["splits"]):
        assert sum(got) == c["net"]                       # with a rest line, every cent lands somewhere

def test_statement_deposits_become_splits_by_last_digits():
    accts = [{"id": "chk", "mask": "1234", "type": "checking"}, {"id": "sav", "mask": "5678", "type": "savings"}, {"id": "card", "mask": "9999", "type": "credit"}]
    got = S.from_deposits([{"label": "Checking", "mask": "1234", "cents": 197707}, {"label": "Savings", "mask": "5678", "cents": 50000}, {"label": "Brokerage", "mask": "9999", "cents": 1000}], accts)
    assert [(g["account_id"], g["kind"], g["value"]) for g in got] == [("chk", "rest", 0), ("sav", "fixed", 50000), (None, "fixed", 1000)]
    assert got[2]["label"] == "Brokerage" and S.split_amounts(248707, got) == [197707, 50000, 1000]
    assert S.from_deposits([], accts) == []

class Rest(FakeRest):
    def rpc(self, fn, args):
        if fn == "pay_period":
            return [{"period_start": "2026-10-30", "period_end": "2026-11-12", "next_payday": "2026-11-13"}]
        return super().rpc(fn, args)

@pytest.fixture
def f(monkeypatch):
    f = Rest()
    monkeypatch.setattr(PL, "rest", lambda: f)
    monkeypatch.setattr(S, "rest", lambda: f)
    from app import pay
    monkeypatch.setattr(pay, "rest", lambda: f)
    f.insert("settings", {"user_id": U, "payday_rule": {"frequency": "biweekly", "next_date": "2026-11-13", "amount_cents": 247707, "employer": "Acme Robotics"}})
    f.insert("pay_splits", [{"id": "s1", "user_id": U, "account_id": "sav", "label": None, "mask": None, "kind": "fixed", "value": 50000, "sort": 0},
                            {"id": "s2", "user_id": U, "account_id": None, "label": "Brokerage", "mask": None, "kind": "percent", "value": 1000, "sort": 1},
                            {"id": "s3", "user_id": U, "account_id": "chk", "label": None, "mask": None, "kind": "rest", "value": 0, "sort": 2}])
    return f

def test_one_expected_deposit_per_account_i_can_see(f):
    f.insert("expected", {"id": "old", "user_id": U, "kind": "paycheck", "label": "Acme Robotics", "amount_cents": 247707, "expected_date": "2026-11-13", "status": "expected", "account_id": None})
    PL.ensure_expected_paycheck(U, today=date(2026, 11, 12))
    rows = sorted((e["account_id"], e["amount_cents"]) for e in f.rows("expected") if e["expected_date"] == "2026-11-13")
    assert rows == [("chk", 172937), ("sav", 50000)]                 # the unsplit row is replaced; the brokerage line isn't an account Tick sees
    PL.ensure_expected_paycheck(U, today=date(2026, 11, 12))
    assert len([e for e in f.rows("expected") if e["expected_date"] == "2026-11-13"]) == 2          # idempotent

def test_each_deposit_lands_its_own_line_once(f):
    PL.ensure_expected_paycheck(U, today=date(2026, 11, 12))
    exp = [e for e in f.rows("expected")]
    when = datetime(2026, 11, 13, 15, tzinfo=timezone.utc)
    PL._landed_in(exp, U, "t-sav", 50000, when, "ACME ROBOTICS PAYROLL", "sav")
    PL._landed_in(exp, U, "t-chk", 172937, when, "ACME ROBOTICS PAYROLL", "chk")
    PL._landed_in(exp, U, "t-dup", 172937, when, "ACME ROBOTICS PAYROLL", "chk")          # a second deposit that size isn't the paycheck again
    landed = {e["account_id"]: e["matched_transaction_id"] for e in f.rows("expected") if e.get("status") == "landed"}
    assert landed == {"sav": "t-sav", "chk": "t-chk"}

def test_a_deposit_into_the_wrong_account_does_not_land_a_split_line(f):
    PL.ensure_expected_paycheck(U, today=date(2026, 11, 12))
    exp = [e for e in f.rows("expected")]
    PL._landed_in(exp, U, "t", 50000, datetime(2026, 11, 13, 15, tzinfo=timezone.utc), "ACME ROBOTICS", "chk")
    assert not [e for e in f.rows("expected") if e.get("status") == "landed"]

# ---------- a split paycheck's statement links every deposit, once ----------
from fastapi.testclient import TestClient
from app import audit as audit_mod, imports as I
from app.auth import current_user, user_limiter
from app.main import app

def test_statement_with_two_deposits_links_both_rows_and_updates_each_expected_line(monkeypatch):
    f = FakeRest()
    for m in (I, audit_mod, S):
        monkeypatch.setattr(m, "rest", lambda: f)
    user_limiter.hits.clear()
    f.insert("settings", {"user_id": U, "payday_rule": {"frequency": "biweekly", "next_date": "2026-11-13", "account_id": "chk"}})
    f.insert("accounts", [{"id": "chk", "user_id": U, "mask": "1234", "type": "checking"}, {"id": "sav", "user_id": U, "mask": "5678", "type": "savings"}])
    f.insert("pay_splits", [{"id": "s1", "user_id": U, "account_id": "sav", "kind": "fixed", "value": 50000, "sort": 0}, {"id": "s3", "user_id": U, "account_id": "chk", "kind": "rest", "value": 0, "sort": 1}])
    f.insert("transactions", [{"id": "d-chk", "user_id": U, "amount_cents": 197707, "occurred_at": "2026-11-13T15:00:00+00:00", "account_id": "chk"},
                              {"id": "d-sav", "user_id": U, "amount_cents": 50000, "occurred_at": "2026-11-13T15:00:00+00:00", "account_id": "sav"},
                              {"id": "other", "user_id": U, "amount_cents": 50000, "occurred_at": "2026-11-13T15:00:00+00:00", "account_id": "chk"}])
    f.insert("pay_statements", {"id": "ps", "user_id": U, "employer": "ACME", "pay_date": "2026-11-13", "net_cents": 247707, "matched_txn": None,
                                "deposits": [{"label": "Checking", "mask": "1234", "cents": 197707}, {"label": "Savings", "mask": "5678", "cents": 50000}]})
    f.insert("expected", [{"id": "e1", "user_id": U, "kind": "paycheck", "status": "expected", "expected_date": "2026-11-27", "amount_cents": 1, "account_id": "chk"},
                          {"id": "e2", "user_id": U, "kind": "paycheck", "status": "expected", "expected_date": "2026-11-27", "amount_cents": 1, "account_id": "sav"}])
    assert I.link_paystubs(U) == 1
    noted = sorted(t["id"] for t in f.rows("transactions") if t.get("note") == "Paycheck · Nov 13")
    assert noted == ["d-chk", "d-sav"]                                  # the $500 that landed in checking is not the savings line
    assert f.rows("pay_statements")[0]["matched_txn"] == "d-chk"
    assert {e["id"]: e["amount_cents"] for e in f.rows("expected")} == {"e1": 197707, "e2": 50000}
    app.dependency_overrides[current_user] = lambda: U
    try:
        j = TestClient(app).get("/pay/splits/suggested").json()
    finally:
        app.dependency_overrides.clear()
    assert [(x["account_id"], x["kind"], x["value"]) for x in j["splits"]] == [("chk", "rest", 0), ("sav", "fixed", 50000)] and j["net_cents"] == 247707
