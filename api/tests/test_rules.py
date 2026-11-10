"""Recurring person-to-person detection. Matching a rule to a row is SQL: supabase/tests/category_rules.sql."""
from datetime import date

from app import rules as R

def pay(person, cents, day):
    return {"person": person, "amount_cents": cents, "day": day}

RENT = [pay("kaarthik roshan", 120000, "2026-07-01"), pay("kaarthik roshan", 120000, "2026-08-02"), pay("kaarthik roshan", 123000, "2026-08-31"), pay("kaarthik roshan", 120000, "2026-10-01")]

def test_a_monthly_payment_is_spotted_with_its_amount_and_day():
    d = R.detect(RENT)[0]
    assert (d.person, d.amount_cents, d.count, d.last) == ("kaarthik roshan", 120000, 4, date(2026, 10, 1))
    assert d.day in (31, 1, 2)

def test_settle_ups_between_rent_payments_do_not_break_the_run():
    d = R.detect(RENT + [pay("kaarthik roshan", 4500, "2026-07-20"), pay("kaarthik roshan", 900, "2026-09-12")])[0]
    assert (d.amount_cents, d.count) == (120000, 4)

def test_two_occasions_are_enough_one_is_not():
    assert R.detect(RENT[:2]) and not R.detect(RENT[:1])

def test_amounts_outside_the_band_or_gaps_outside_a_month_are_not_recurring():
    assert R.detect([pay("a b", 10000, "2026-07-01"), pay("a b", 12000, "2026-08-01")]) == []
    assert R.detect([pay("a b", 10000, "2026-07-01"), pay("a b", 10000, "2026-07-15")]) == []
    assert R.detect([pay("a b", 10000, "2026-07-01"), pay("a b", 10000, "2026-08-20")]) == []

def test_people_with_an_answer_are_not_asked_again():
    assert R.detect(RENT, {"kaarthik roshan"}) == []

def test_typical_day_rounds_the_month_end():
    assert R.typical_day([30, 1, 2]) in (31, 1)
    assert R.typical_day([14, 15, 16]) == 15

import pytest
from fastapi.testclient import TestClient
from app.auth import current_user
from app.main import app
from tests.fakerest import FakeRest

U = "11111111-1111-1111-1111-111111111111"
RID = "aaaaaaaa-0000-4000-8000-000000000001"

class Rest(FakeRest):
    def rpc(self, fn, args):
        return 0

@pytest.fixture
def api(monkeypatch):
    f = Rest()
    monkeypatch.setattr(R, "rest", lambda: f)
    from app.auth import user_limiter
    user_limiter.hits.clear()
    f.insert("categories", {"id": "c-rent", "user_id": U, "name": "Rent"})
    f.insert("category_rules", {"id": RID, "user_id": U, "person_key": "kaarthik kumar", "category_id": "c-rent", "amount_cents": 49300, "day_of_month": 3})
    app.dependency_overrides[current_user] = lambda: U
    yield f, TestClient(app)
    app.dependency_overrides.clear()

def test_edit_delete_and_undo_a_rule(api):
    f, c = api
    assert c.post(f"/rules/{RID}/amount", json={"amount_cents": 51000}).status_code == 200
    assert f.rows("category_rules")[0]["amount_cents"] == 51000
    gone = c.post(f"/rules/{RID}/delete").json()["rule"]
    assert f.rows("category_rules") == []
    assert c.post("/rules/restore", json={"rule": gone}).status_code == 200
    assert f.rows("category_rules")[0]["person_key"] == "kaarthik kumar"

def test_someone_elses_rule_is_404_and_a_restore_cant_point_at_their_category(api):
    f, c = api
    f.insert("category_rules", {"id": "bbbbbbbb-0000-4000-8000-000000000002", "user_id": "other", "person_key": "x"})
    assert c.post("/rules/bbbbbbbb-0000-4000-8000-000000000002/delete").status_code == 404
    assert c.post("/rules/restore", json={"rule": {"person_key": "x", "category_id": "theirs"}}).status_code == 422
