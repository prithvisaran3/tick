"""Goals from real balances: the shared vectors, daily snapshots, and the payday move confirmed by the next balance."""
import json
import pathlib
from datetime import date, datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from app import goals as G
from app.auth import current_user, user_limiter
from app.main import app
from tests.fakerest import FakeRest

CASES = json.loads((pathlib.Path(__file__).parent / "data" / "goal_status.json").read_text())["cases"]
U, OTHER = "11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222"

@pytest.mark.parametrize("c", CASES, ids=[c["name"] for c in CASES])
def test_vectors(c):
    got = G.goal_status(mode=c["mode"], target=c["target"], start_cents=c["start_cents"], linked=c["linked"], start_date=c["start_date"], deadline=c["deadline"], today=c["today"], paydays=c["paydays"])
    assert got == c["want"]

def test_nine_thousand_in_three_months_is_six_paychecks_of_fifteen_hundred():
    c = CASES[0]
    got = G.goal_status(mode="save_more", target=900000, start_cents=0, linked=0, start_date="2026-11-15", deadline="2027-02-15", today="2026-11-15", paydays=c["paydays"])
    assert (got["paychecks_left"], got["per_paycheck"], got["per_paycheck"] * got["paychecks_left"]) == (6, 150000, 900000)

@pytest.fixture
def api(monkeypatch):
    f = FakeRest()
    monkeypatch.setattr(G, "rest", lambda: f)
    user_limiter.hits.clear()
    f.insert("accounts", [{"id": "chk", "user_id": U, "type": "checking", "balance_cents": 300000}, {"id": "sav", "user_id": U, "type": "savings", "balance_cents": 500000},
                          {"id": "sav2", "user_id": U, "type": "savings", "balance_cents": None}, {"id": "x", "user_id": OTHER, "type": "savings", "balance_cents": 999}])
    app.dependency_overrides[current_user] = lambda: U
    yield f, TestClient(app)
    app.dependency_overrides.clear()

def test_one_snapshot_per_account_per_day_last_one_wins(api):
    f, _ = api
    assert G.snapshot_balances(U, date(2026, 11, 15)) == 2                 # the account with no balance yet is skipped
    next(a for a in f.rows("accounts") if a["id"] == "sav")["balance_cents"] = 510000
    G.snapshot_balances(U, date(2026, 11, 15))
    rows = [r for r in f.rows("account_balances") if r["account_id"] == "sav"]
    assert len(rows) == 1 and rows[0]["balance_cents"] == 510000 and not [r for r in f.rows("account_balances") if r["account_id"] == "x"]

def test_done_is_confirmed_by_the_next_balance(api):
    f, c = api
    today = G.today_ny()
    assert c.post("/goals/move", json={"pay_date": today.isoformat(), "cents": 150000}).json() == {"saved": True}
    m = f.rows("goal_moves")[0]
    assert (m["status"], m["balance_before_cents"]) == ("done", 500000)
    assert G.confirm_moves(U) == 0 and f.rows("goal_moves")[0]["status"] == "done"          # the balance hasn't moved yet
    next(a for a in f.rows("accounts") if a["id"] == "sav")["balance_cents"] = 650000
    assert G.confirm_moves(U) == 1 and f.rows("goal_moves")[0]["status"] == "confirmed"
    c.post("/goals/move", json={"pay_date": today.isoformat(), "cents": 1})                  # tapping Done again changes nothing
    assert len(f.rows("goal_moves")) == 1 and f.rows("goal_moves")[0]["cents"] == 150000

def test_no_rise_after_two_days_is_marked_unconfirmed_and_undo_removes_it(api):
    f, c = api
    today = G.today_ny()
    c.post("/goals/move", json={"pay_date": today.isoformat(), "cents": 150000})
    f.rows("goal_moves")[0]["created_at"] = (datetime.now(timezone.utc) - timedelta(days=3)).isoformat()
    G.confirm_moves(U)
    assert f.rows("goal_moves")[0]["status"] == "unconfirmed"
    assert c.post("/goals/move/undo", json={"pay_date": today.isoformat()}).status_code == 200 and f.rows("goal_moves") == []
    assert c.post("/goals/move", json={"pay_date": (today - timedelta(days=30)).isoformat(), "cents": 5}).status_code == 422
    assert c.post("/goals/move", json={"pay_date": today.isoformat(), "cents": -5}).status_code == 422

def test_goals_that_name_accounts_narrow_what_counts(api):
    f, _ = api
    assert G.linked_savings(U) == (["sav", "sav2"], 500000)
    f.insert("goals", {"id": "g", "user_id": U, "account_ids": ["chk"], "paused": False})
    assert G.linked_savings(U) == (["chk"], 300000)
