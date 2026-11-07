"""Ask Tick: the range parser, tools, router, follow-ups, feedback. ask_eval.py is the 50-question accuracy check; this wraps it so CI fails on it."""
from datetime import date

import pytest
from fastapi.testclient import TestClient

from app import ask as A, ask_brain as B
from app.auth import current_user
from app.main import app
from tests import ask_eval as E
from tests.fakerest import FakeRest

T = date(2026, 11, 6)
U = "11111111-1111-1111-1111-111111111111"
P, Q = E.PERIOD, E.PREV

@pytest.mark.parametrize("q,a,b", [
    ("last month", date(2026, 10, 1), date(2026, 10, 31)), ("this month", date(2026, 11, 1), T), ("this week", date(2026, 11, 2), T), ("last week", date(2026, 10, 26), date(2026, 11, 1)),
    ("since payday", date(2026, 10, 30), T), ("this pay period", date(2026, 10, 30), T), ("last pay period", date(2026, 10, 16), date(2026, 10, 29)), ("in October", date(2026, 10, 1), date(2026, 10, 31)),
    ("in December", date(2025, 12, 1), date(2025, 12, 31)), ("march 2025", date(2025, 3, 1), date(2025, 3, 31)), ("last 30 days", date(2026, 10, 8), T), ("last 2 weeks", date(2026, 10, 24), T),
    ("last 3 months", date(2026, 8, 1), T), ("yesterday", date(2026, 11, 5), date(2026, 11, 5)), ("today", T, T), ("this year", date(2026, 1, 1), T), ("last year", date(2025, 1, 1), date(2025, 12, 31)), ("since March", date(2026, 3, 1), T)])
def test_ranges(q, a, b):
    r = B.parse_range(q, T, P, Q)
    assert (r.start, r.end) == (a, b) and r.explicit

def test_no_phrase_means_this_month_and_says_so():
    r = B.parse_range("how much on coffee", T)
    assert (r.start, r.end, r.explicit) == (date(2026, 11, 1), T, False)

def test_a_new_year_rolls_ranges_over():
    assert B.parse_range("last month", date(2027, 1, 5)).start == date(2026, 12, 1)

def test_the_eval_is_green():
    assert E.main() == 0

def test_every_counted_answer_says_its_range_and_can_show_its_rows():
    l = E.ledger()
    r, s = B.route("how much rent did I pay this year", l)
    res = B.run(r.tool, r.params, s, l)
    assert res.text.startswith("$13,200") and res.range.label == "this year"
    assert res.see == {"from": "2026-01-01", "to": "2026-11-06", "categories": ["id-Rent"], "query": ""}

def test_not_rent_lists_every_other_category():
    l = E.ledger()
    r, s = B.route("how much did I send Kaarthik that wasn't rent this year", l)
    see = B.run(r.tool, r.params, s, l).see
    assert "id-Rent" not in see["categories"] and "id-Friends and family" in see["categories"] and see["query"] == "kaarthik"

def test_follow_up_keeps_the_subject_and_changes_the_period():
    l = E.ledger()
    r, s = B.route("how much on groceries this year", l)
    ctx = {"tool": r.tool, "params": r.params, "slots": B.slot_dict(s)}
    r2, s2 = B.route("and last month?", l, context=ctx)
    assert (r2.tool, s2.categories, s2.range.label) == ("spend_summary", ["Groceries"], "last month")

def test_an_unknown_question_reaches_the_phone_then_the_cloud_and_otherwise_says_so():
    l = E.ledger()
    assert B.route("xyzzy", l)[0].path == "none"
    assert B.route("xyzzy", l, device=lambda q: ("safe_to_spend", {}))[0].path == "device"
    assert B.route("xyzzy", l, device=lambda q: None, cloud=lambda q: ("safe_to_spend", {}))[0].path == "cloud"

def test_no_model_is_called_when_rules_can_answer():
    def boom(q):
        raise AssertionError("called a model")
    assert B.route("what's safe to spend", E.ledger(), device=boom, cloud=boom)[0].path == "rules"

class Rest(FakeRest):
    def rpc(self, fn, args):
        return []

@pytest.fixture
def api(monkeypatch):
    f = Rest()
    monkeypatch.setattr(A, "rest", lambda: f)
    monkeypatch.setattr(A, "load_ledger", lambda u: E.ledger())
    from app.auth import user_limiter
    user_limiter.hits.clear()
    app.dependency_overrides[current_user] = lambda: U
    yield f, TestClient(app)
    app.dependency_overrides.clear()

def ask(c, q, **kw):
    import json
    r = c.post("/ask", json={"question": q, **kw})
    ev = [json.loads(l[5:]) for l in r.text.splitlines() if l.startswith("data:")]
    return ev, "".join(e.get("text", "") for e in ev if e["type"] == "token"), next((e for e in ev if e["type"] == "meta"), None)

def test_answer_logs_numbers_and_the_path(api):
    f, c = api
    ev, text, meta = ask(c, "what's safe to spend")
    assert text.startswith("$4") and meta["path"] == "rules"
    row = f.rows("ask_log")[0]
    assert row["tool"] == "safe_to_spend" and row["summary"] == {"cents": E.SAFE}

def test_a_paraphrase_is_answered_after_one_thumbs_up(api, monkeypatch):
    f, c = api
    monkeypatch.setattr(A, "cloud_route", lambda u, q, m, a: ("safe_to_spend", {}))
    _, _, meta = ask(c, "hit me with my runway to next pay")
    assert meta["path"] == "cloud"
    assert c.post("/ask/feedback", json={"log_id": _uuid(f), "rating": 1}).status_code == 200
    monkeypatch.setattr(A, "cloud_route", lambda u, q, m, a: pytest.fail("called the model"))
    _, text, meta = ask(c, "hit me with the runway till my next pay")
    assert meta["path"] == "learned" and text.startswith("$4")

def _uuid(f):
    row = f.rows("ask_log")[-1]
    row["id"] = "aaaaaaaa-0000-4000-8000-000000000001"
    return row["id"]

def test_a_correction_is_preferred_and_keeps_its_period_fresh(api):
    f, c = api
    ask(c, "how much on groceries")
    c.post("/ask/feedback", json={"log_id": _uuid(f), "rating": -1, "reason": "period", "range": "last month", "tool": "spend_summary"})
    _, _, meta = ask(c, "how much on groceries")
    assert meta["range"] == "Oct 1 to Oct 31"

def test_a_learned_word_becomes_an_alias(api):
    f, c = api
    ask(c, "how much on munchies")
    c.post("/ask/feedback", json={"log_id": _uuid(f), "rating": -1, "reason": "category", "term": "munchies", "category": "Coffee"})
    _, text, _ = ask(c, "how much on munchies this month")
    assert text.startswith("$5.75")

def test_cloud_off_means_no_cloud(api, monkeypatch):
    f, c = api
    f.insert("settings", {"user_id": U, "ask_cloud": False})
    monkeypatch.setattr(A, "cloud_route", lambda *a: pytest.fail("called the cloud"))
    _, text, meta = ask(c, "xyzzy")
    assert meta["path"] == "none" and "Cloud help is off" in text

def test_the_phone_is_asked_before_the_cloud(api, monkeypatch):
    f, c = api
    monkeypatch.setattr(A, "cloud_route", lambda *a: pytest.fail("called the cloud"))
    ev, _, _ = ask(c, "xyzzy", device_ready=True)
    assert ev[0]["type"] == "need_device" and f.rows("ask_log") == []
    _, _, meta = ask(c, "xyzzy", device_call={"tool": "safe_to_spend", "params": {}})
    assert meta["path"] == "device"

def test_stats_and_clear(api):
    f, c = api
    ask(c, "what's safe to spend")
    c.post("/ask/feedback", json={"log_id": _uuid(f), "rating": 1})
    f.rows("ask_log")[0]["created_at"] = "2099-01-01T00:00:00+00:00"
    s = c.get("/ask/stats").json()
    assert (s["no_model_pct"], s["thumbs_up_pct"]) == (100, 100)
    assert c.post("/ask/clear").json() == {"cleared": True} and f.rows("ask_log") == []

def test_nightly_promotes_a_shape_with_three_good_answers(api):
    f, c = api
    for _ in range(3):
        f.insert("ask_log", {"user_id": U, "normalised": "runway please", "tool": "safe_to_spend", "params": {}, "rating": 1})
    assert A.nightly(U) == 1
    assert any(m["kind"] == "rule" and m["key"] == "runway please" for m in f.rows("ask_memory"))
