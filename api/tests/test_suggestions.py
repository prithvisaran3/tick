"""Suggestions: rules pick, at most two, payday and weekly; the model's wording must keep every number; accept/dismiss teach and rest a kind."""
from datetime import date, timedelta

import pytest
from fastapi.testclient import TestClient

from app import ai, ask as A, suggestions as S
from app.auth import current_user, user_limiter
from app.main import app
from tests.fakerest import FakeRest
from tests.test_planner import PERIOD, ledger

U = "11111111-1111-1111-1111-111111111111"

def test_rules_pick_from_the_plan_most_urgent_first():
    kinds = [c["kind"] for c in S.candidates(ledger())]
    assert kinds == ["goal_behind"]
    c = S.candidates(ledger())[0]
    assert c["text"] == "Emergency fund is $333.34 behind. $750 a paycheck catches it up by Jan\u00a01." and c["facts"]["behind"] == 33334
    over = ledger(planned=[{"name": "Laptop", "cents": 90000, "due": date(2026, 11, 9), "status": "planned"}])
    assert [c["kind"] for c in S.candidates(over)][:3] == ["over_plan", "goal_behind", "planned_soon"]
    assert S.candidates(over)[0]["facts"] == {"gap": 65000}
    l = ledger(goals=[dict(ledger().goals[0], linked_cents=1250000)])
    l.accounts[0]["available_cents"] = l.accounts[0]["balance_cents"] = 400000
    room = [c for c in S.candidates(l) if c["kind"] == "room_to_spare"]
    assert room and room[0]["facts"]["extra"] == (400000 - 62500 - 57750) // 1000 * 1000          # on track, the goal needs $625 a paycheck

def test_payday_suggests_the_move_until_it_is_marked():
    l = ledger()
    l.today = PERIOD["period_start"]
    assert "move_to_savings" in [c["kind"] for c in S.candidates(l)]
    l.goal_moved = True
    assert "move_to_savings" not in [c["kind"] for c in S.candidates(l)]

def test_at_most_two_and_a_kind_dismissed_twice_rests_for_a_month():
    cands = [{"kind": k, "facts": {}, "text": k} for k in S.KINDS]
    today = date(2026, 11, 15)
    assert [c["kind"] for c in S.pick(cands, {}, today)] == ["over_plan", "goal_behind"]
    mem = {"over_plan": {"dismissed": 2, "last_dismissed": "2026-11-01"}, "goal_behind": {"dismissed": 1, "last_dismissed": "2026-11-14"}}
    assert [c["kind"] for c in S.pick(cands, mem, today)] == ["goal_behind", "move_to_savings"]
    assert [c["kind"] for c in S.pick(cands, mem, today + timedelta(days=30))][0] == "over_plan"

def test_cadence():
    assert S.due_today(PERIOD["period_start"], PERIOD, PERIOD["period_start"] - timedelta(days=1))
    assert not S.due_today(date(2026, 11, 6), PERIOD, date(2026, 11, 3))
    assert S.due_today(date(2026, 11, 10), PERIOD, date(2026, 11, 3)) and S.due_today(date(2026, 11, 6), PERIOD, None)

def test_the_model_only_words_and_must_keep_every_number(monkeypatch):
    picked = [{"kind": "goal_behind", "text": "Emergency fund is $333.34 behind. $750 a paycheck catches it up by Jan 1."}, {"kind": "planned_soon", "text": "Gift, $50, is planned for Nov 8."}]
    monkeypatch.setattr(ai, "generate", lambda *a, **k: '{"texts": ["$750 a paycheck gets Emergency fund back on track by Jan 1, it is $333.34 behind.", "Gift is $500 on Nov 8."]}')
    got = S.word(U, picked)
    assert got[0].startswith("$750 a paycheck") and got[1] == picked[1]["text"]          # a changed amount falls back to the template
    monkeypatch.setattr(ai, "generate", lambda *a, **k: None)
    assert S.word(U, picked) == [p["text"] for p in picked]
    monkeypatch.setattr(ai, "generate", lambda *a, **k: '{"texts": ["Emergency fund is $333.34 behind. $750 a paycheck for 4 paychecks fixes it by Jan 1."]}')
    assert S.word(U, picked[:1]) == [picked[0]["text"]]                                   # no new numbers either

@pytest.fixture
def api(monkeypatch):
    f = FakeRest()
    monkeypatch.setattr(S, "rest", lambda: f)
    monkeypatch.setattr(S, "today_ny", lambda: date(2026, 11, 6))
    monkeypatch.setattr(A, "load_ledger", lambda u: ledger(planned=[{"name": "Laptop", "cents": 90000, "due": date(2026, 11, 9), "status": "planned"}]))
    monkeypatch.setattr(ai, "generate", lambda *a, **k: None)
    user_limiter.hits.clear()
    app.dependency_overrides[current_user] = lambda: U
    yield f, TestClient(app)
    app.dependency_overrides.clear()

def test_route_makes_one_batch_a_day_and_answers_teach(api):
    f, c = api
    got = c.get("/plan/suggestions").json()["suggestions"]
    assert [g["kind"] for g in got] == ["over_plan", "goal_behind"] and got[0]["route"] == "/planned"
    assert len(f.rows("plan_suggestions")) == 2
    c.get("/plan/suggestions")
    assert len(f.rows("plan_suggestions")) == 2                                            # same day: no second batch
    assert c.post(f"/plan/suggestions/{got[0]['id']}", json={"action": "dismiss"}).status_code == 200
    assert [g["kind"] for g in c.get("/plan/suggestions").json()["suggestions"]] == ["goal_behind"]
    c.post(f"/plan/suggestions/{got[1]['id']}", json={"action": "accept"})
    mem = {m["key"]: m["value"] for m in f.rows("ask_memory")}
    assert mem["over_plan"]["dismissed"] == 1 and mem["goal_behind"]["accepted"] == 1
    assert c.get("/plan/suggestions").json()["suggestions"] == []
    assert c.post("/plan/suggestions/00000000-0000-0000-0000-000000000000", json={"action": "accept"}).status_code == 404
    assert c.post(f"/plan/suggestions/{got[0]['id']}", json={"action": "delete"}).status_code == 404
