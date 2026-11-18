"""Ask Tick as a planner: the four tools and the what-if, on a plain Ledger (no database)."""
from datetime import date, timedelta

from app import ask_brain as B

TODAY = date(2026, 11, 6)
PERIOD = {"period_start": date(2026, 10, 30), "period_end": date(2026, 11, 12), "next_payday": date(2026, 11, 13)}
PAYDAYS = [date(2026, 10, 16) + timedelta(days=14 * i) for i in range(6)]

def ledger(**k) -> B.Ledger:
    acc = [{"name": "Chase", "type": "checking", "balance_cents": 100000, "available_cents": 100000, "include_in_safe": True}]
    goal = {"name": "Emergency fund", "mode": "save_more", "target": 400000, "start_cents": 1100000, "linked_cents": 1200000, "start_date": date(2026, 10, 1),
            "deadline": date(2027, 1, 1), "paydays": PAYDAYS, "paused": False}
    base = dict(goals=[goal], planned=[], savings=[])
    base.update(k)
    return B.Ledger([], TODAY, [], acc, 0, PERIOD, None, 231000, **base)

def ask(q, l):
    r, s = B.route(q, l)
    return r.tool, B.run(r.tool, r.params, s, l)

def test_safe_to_spend_takes_out_the_goal_move_and_planned_one_offs():
    assert ask("what's safe to spend", ledger())[1].numbers["cents"] == 100000 - 75000
    l = ledger(planned=[{"name": "Gift", "cents": 5000, "due": date(2026, 11, 8), "status": "planned"}, {"name": "Later", "cents": 9000, "due": date(2026, 11, 20), "status": "planned"},
                        {"name": "Bought", "cents": 7000, "due": date(2026, 11, 2), "status": "matched"}])
    assert ask("what's safe to spend", l)[1].numbers["cents"] == 100000 - 75000 - 5000
    assert ask("what's safe to spend", ledger(goal_moved=True))[1].numbers["cents"] == 100000          # moved this payday: nothing more set aside
    relief = ledger(planned=[{"name": "Gift", "cents": 30000, "due": date(2026, 11, 8), "status": "matched", "resolution": "catch_up", "shortfall_cents": 20000}])
    assert ask("what's safe to spend", relief)[1].numbers["cents"] == 100000 - 55000                    # I chose: this paycheck's move shrinks by the shortfall

def test_what_if_beyond_safe_says_what_the_goal_would_give_up_and_saves_nothing():
    l = ledger()
    before = (list(l.planned), list(l.goals))
    tool, r = ask("What if I spend $400 on a gift this month?", l)
    assert tool == "what_if" and r.numbers == {"cents": -15000, "goal_short": 15000}
    assert "Emergency fund would get $600 instead of $750" in r.text and "Nothing changes until you plan it" in r.text
    assert (l.planned, l.goals) == before
    tool, r = ask("can I afford $2000", l)
    assert r.text.startswith("Not comfortably.") and r.numbers["cents"] == 25000 - 200000

def test_goal_status_says_on_track_behind_done_and_paused():
    assert ask("Am I on track for my savings goal?", ledger())[1].text.startswith("Not quite. Emergency fund is $333.34 behind.")
    g = dict(ledger().goals[0], linked_cents=1250000)
    assert ask("am I on track", ledger(goals=[g]))[1].text.startswith("Yes. Emergency fund is on track")
    done = dict(g, linked_cents=1600000)
    assert ask("how's my savings goal", ledger(goals=[done]))[1].text.startswith("Yes. Emergency fund is done")
    assert ask("goal progress", ledger(goals=[]))[1].text.startswith("No savings goal yet")

def test_paycheck_plan_planned_and_savings_trend():
    assert ask("where does my next paycheck go", ledger())[1].numbers == {"cents": 75000, "net": 231000, "left": 156000}
    assert ask("what have I planned", ledger())[1].text.startswith("Nothing planned")
    tool, r = ask("are my savings growing", ledger(savings=[{"name": "SoFi", "balance": 1200000, "month_start": None}]))
    assert tool == "savings_trend" and "starts tracking" in r.text
    r = ask("did my savings go down", ledger(savings=[{"name": "SoFi", "balance": 1150000, "month_start": 1200000}]))[1]
    assert r.text == "$11,500 in savings, down $500 this month."
