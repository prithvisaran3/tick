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
