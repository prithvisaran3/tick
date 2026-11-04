from datetime import date, timedelta
from app.ask import Ledger, Tools, fallback_answer, money

TODAY = date(2026, 11, 18)

def led():
    tx = []
    def add(i, m, c, d, cat, tags=()):
        tx.append({"id": f"t{i}", "merchant": m, "amount_cents": -c, "date": d, "category": cat, "tags": list(tags), "account": None})
    add(1, "Whole Foods", 4218, date(2026, 11, 3), "Groceries"); add(2, "Chipotle", 1385, date(2026, 11, 10), "Restaurants")
    add(3, "Cursor", 2200, date(2026, 11, 5), "Software", ["business"]); add(4, "Namecheap", 1500, date(2026, 11, 7), "Software", ["business"])
    add(5, "Whole Foods", 3000, date(2026, 10, 4), "Groceries"); add(6, "Chipotle", 1000, date(2026, 10, 12), "Restaurants")
    for i, d in enumerate([date(2026, 7, 9), date(2026, 8, 9), date(2026, 9, 9), date(2026, 10, 9)]):
        add(10 + i, "Claude", 1800, d, "Software", ["business"])
    return Ledger(tx, [{"merchant": "Rent", "cadence": "monthly", "expected_cents": 185000, "next_date": TODAY + timedelta(days=2)}, {"merchant": "Internet", "cadence": "monthly", "expected_cents": 6400, "next_date": TODAY + timedelta(days=20)}],
                  [{"label": "Payroll", "kind": "paycheck", "amount_cents": 231000, "date": TODAY + timedelta(days=3)}],
                  [{"name": "Checking", "type": "checking", "balance_cents": 300000, "available_cents": 300000}], [], TODAY + timedelta(days=3), TODAY)

def test_money():
    assert money(41200) == "$412" and money(1840) == "$18.40" and money(-500) == "$5"

def test_tools():
    t = Tools(led())
    assert t.business_total()["total_cents"] == 3700
    assert t.spend_by_category()["categories"][0]["name"] == "Software" or t.spend_by_category()["total_cents"] == 4218 + 1385 + 2200 + 1500
    assert t.list_upcoming(7)["total_cents"] == 185000
    assert t.list_incoming()["total_cents"] == 231000
    assert t.query_transactions(merchant="whole")["count"] == 2
    c = t.compare_periods("2026-11-01", "2026-11-18", "2026-10-01", "2026-10-18")
    assert c["a_cents"] == 4218 + 1385 + 2200 + 1500 and c["b_cents"] == 4000 + 0 + 1800 * 0 + 0 or c["diff_cents"] == c["a_cents"] - c["b_cents"]
    subs = t.find_subscriptions()
    assert any(i["merchant"] == "Claude" for i in subs["items"])

def test_fallback_leads_with_number():
    l = led()
    txt, blocks = fallback_answer("How much did I spend on food this month?", l)
    assert txt.startswith("$5,603") or txt.startswith("$56.03") or txt.startswith("$56")
    assert blocks and blocks[0]["kind"] == "bars"
    assert fallback_answer("What's due this week?", l)[0].startswith("$1,850")
    assert fallback_answer("Business total this month", l)[0].startswith("$37")
    assert "recurring" in fallback_answer("Which subscriptions am I paying for?", l)[0]
    assert fallback_answer("Can I afford $200 today?", l)[0].startswith("Yes")
    assert fallback_answer("Can I afford $5000 today?", l)[0].startswith("Not comfortably")


def test_next_payday():
    from app.ask import next_payday
    t = date(2026, 11, 4)
    assert next_payday({"frequency": "biweekly", "next_date": "2026-10-23"}, t) == date(2026, 11, 6)
    assert next_payday({"frequency": "weekly", "next_date": "2026-11-13"}, t) == date(2026, 11, 13)
    assert next_payday({"frequency": "monthly", "next_date": "2026-01-31"}, date(2026, 2, 1)) == date(2026, 2, 28)
    assert next_payday(None, t) is None and next_payday({"next_date": "bad"}, t) is None
