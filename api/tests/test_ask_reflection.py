"""Reflection: a week's thumbs-down with corrections become proposals; nothing applies until approved; approving adds a rule and eval questions."""
import pytest
from fastapi.testclient import TestClient

from app import ask as A
from app import ask_brain as B
from app.auth import current_user
from app.main import app
from tests.fakerest import FakeRest

U = "11111111-1111-1111-1111-111111111111"

def down(i, q, shape, tool=None, reason="other", rng=None, rating=-1):
    c = {"reason": reason, "tool": tool, "params": {"range_phrase": rng} if rng else {}} if tool else None
    return {"id": f"l{i}", "question": q, "normalised": shape, "tool": "spend_summary", "params": {}, "rating": rating, "correction": c}

def test_corrected_thumbs_down_group_by_shape_and_tool():
    rows = [down(1, "food last month?", "food <period>", "category_breakdown"), down(2, "Food last month", "food <period>", "category_breakdown"),
            down(3, "rent ytd", "rent <period>", "spend_summary", rng="this year"), down(4, "huh", "huh"), down(5, "ok", "ok", "safe_to_spend", rating=1)]
    got = A.propose(rows, {}, set())
    assert [(g["shape"], g["tool"], g["count"]) for g in got] == [("food <period>", "category_breakdown", 2), ("rent <period>", "spend_summary", 1)]
    assert got[0]["questions"] == ["food last month?", "Food last month"] and got[0]["status"] == "open"
    assert got[1]["label"] == "Total spending for this year"

def test_nothing_comes_back_once_decided_or_already_a_rule():
    rows = [down(1, "food last month?", "food <period>", "category_breakdown")]
    key = A.propose(rows, {}, set())[0]["key"]
    assert A.propose(rows, {key: {"status": "dismissed"}}, set()) == []
    assert A.propose(rows, {key: {"status": "approved"}}, set()) == []
    assert A.propose(rows, {}, {"food <period>"}) == []
    assert A.propose([down(1, "x", "x", "not_a_tool")], {}, set()) == []

@pytest.fixture
def api(monkeypatch):
    f = FakeRest()
    monkeypatch.setattr(A, "rest", lambda: f)
    monkeypatch.setattr(A, "user_limiter", type("L", (), {"check": lambda *a, **k: None})())
    from datetime import datetime, timezone
    now = datetime.now(timezone.utc).isoformat()
    for r in [down(1, "food last month?", "food <period>", "category_breakdown"), down(2, "Food last month", "food <period>", "category_breakdown")]:
        f.insert("ask_log", {**r, "user_id": U, "created_at": now})
    app.dependency_overrides[current_user] = lambda: U
    yield f, TestClient(app)
    app.dependency_overrides.clear()

def test_reflect_proposes_and_approve_makes_a_rule_and_eval_cases(api):
    f, c = api
    assert A.reflect(U) == 1
    assert not [m for m in f.rows("ask_memory") if m["kind"] == "rule"]          # nothing applied by the job
    props = c.get("/ask/proposals").json()["proposals"]
    assert len(props) == 1 and props[0]["count"] == 2 and props[0]["label"] == "Spending by category"
    assert c.post(f"/ask/proposals/{props[0]['key']}/approve").json() == {"approved": True}
    rules = [m for m in f.rows("ask_memory") if m["kind"] == "rule"]
    assert rules[0]["key"] == "food <period>" and rules[0]["value"]["tool"] == "category_breakdown"
    assert sorted(m["value"]["question"] for m in f.rows("ask_memory") if m["kind"] == "eval") == ["Food last month", "food last month?"]
    assert c.get("/ask/proposals").json()["proposals"] == []
    assert A.reflect(U) == 0                                                     # approved: not proposed again
    assert c.post(f"/ask/proposals/{props[0]['key']}/approve").status_code == 404

def test_dismiss_and_bad_keys(api):
    f, c = api
    A.reflect(U)
    key = c.get("/ask/proposals").json()["proposals"][0]["key"]
    assert c.post(f"/ask/proposals/{key}/dismiss").json() == {"dismissed": True}
    assert not [m for m in f.rows("ask_memory") if m["kind"] == "rule"]
    assert A.reflect(U) == 0
    assert c.post("/ask/proposals/nope/approve").status_code == 404

def test_an_approved_shape_routes_by_rule():
    assert set(B.TOOL_LABELS) == set(B.TOOL_NAMES)
