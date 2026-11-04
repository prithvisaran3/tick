from datetime import date, timedelta
from app.intel import detect_recurring, weekly_summary, weekly_text_fallback, advice_fallback, AdviceBody, forgotten_subscriptions

TODAY = date(2026, 11, 4)

def monthly(m, amts, start=date(2026, 5, 9)):
    out = []
    for i, a in enumerate(amts):
        y, mo = start.year + (start.month - 1 + i) // 12, (start.month - 1 + i) % 12 + 1
        out.append({"merchant": m, "amount_cents": -a, "date": date(y, mo, start.day)})
    return out

def test_detects_monthly_with_price_hike():
    d = detect_recurring(monthly("CLAUDE.AI SUBSCRIPTION", [1800, 1800, 1800, 1800, 2000, 2000]), TODAY)
    assert len(d) == 1
    r = d[0]
    assert r.cadence == "monthly" and r.expected_cents == 2000 and r.price_hike and [h["cents"] for h in r.price_history] == [1800, 2000]
    assert r.next_date >= TODAY

def test_biweekly_and_weekly():
    biw = [{"merchant": "Gym", "amount_cents": -3000, "date": date(2026, 9, 1) + timedelta(days=14 * i)} for i in range(5)]
    wk = [{"merchant": "Box", "amount_cents": -1200, "date": date(2026, 9, 1) + timedelta(days=7 * i)} for i in range(6)]
    d = {x.merchant: x for x in detect_recurring(biw + wk, TODAY)}
    assert d["Gym"].cadence == "biweekly" and d["Box"].cadence == "weekly"

def test_erratic_amounts_and_too_few_ignored():
    groceries = [{"merchant": "Whole Foods", "amount_cents": -a, "date": TODAY - timedelta(days=7 * i)} for i, a in enumerate([2000, 9000, 4000, 12000, 3000])]
    twice = monthly("Netflix", [1599, 1599])
    assert detect_recurring(groceries + twice, TODAY) == []

def test_income_and_same_day_duplicates():
    pay = [{"merchant": "Payroll", "amount_cents": 231000, "date": TODAY - timedelta(days=14 * i)} for i in range(5)]
    dup = monthly("Spotify", [1099, 1099, 1099, 1099]); dup += [dict(dup[-1])]
    d = detect_recurring(pay + dup, TODAY)
    assert [x.merchant for x in d] == ["Spotify"] and d[0].occurrences == 4

def test_no_hike_when_price_old():
    d = detect_recurring(monthly("Old", [1000, 1200, 1200, 1200, 1200, 1200], start=date(2025, 12, 5)), TODAY)
    assert d and not d[0].price_hike

def test_forgotten():
    d = detect_recurring(monthly("Headspace", [1299] * 5), TODAY)
    assert forgotten_subscriptions(d, set()) and not forgotten_subscriptions(d, {"Headspace"})

def test_weekly_summary_and_text():
    tx = [{"merchant": "Uber", "amount_cents": -2000, "date": TODAY - timedelta(days=2)}, {"merchant": "Chipotle", "amount_cents": -1500, "date": TODAY - timedelta(days=3)},
          {"merchant": "Uber", "amount_cents": -1000, "date": TODAY - timedelta(days=9)}]
    s = weekly_summary(tx, TODAY)
    assert s["spent_cents"] == 3500 and s["prev_cents"] == 1000 and s["top"][0] == ("Uber", 2000)
    assert "$35 out this week" in weekly_text_fallback(s)
    assert weekly_text_fallback(weekly_summary([], TODAY)).startswith("Quiet week")

def test_advice_fallback():
    assert advice_fallback(AdviceBody(total_cents=0, safe_cents=100, days_to_payday=1, captures=0)).startswith("Quiet")
    assert "past" in advice_fallback(AdviceBody(total_cents=1, safe_cents=-5, days_to_payday=1, captures=1)) or "ahead" in advice_fallback(AdviceBody(total_cents=1, safe_cents=-5, days_to_payday=1, captures=1))
    assert "$50 a day" in advice_fallback(AdviceBody(total_cents=1000, safe_cents=10000, days_to_payday=2, captures=2))
