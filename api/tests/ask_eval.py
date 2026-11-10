#!/usr/bin/env python3
"""Ask Tick's eval: 50 questions over a seeded year, expected numbers worked out here from the raw rows, per-path accuracy.
Rules and learned must be 100%. The cloud path runs only with a key, and reports. Run: python3 api/tests/ask_eval.py"""
import pathlib, sys
from datetime import date, timedelta
ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT)); sys.path.insert(0, str(ROOT / "tests" / "data"))
from app import ask_brain as B
import ask_seed as D

PERIOD = {"period_start": date(2026, 10, 30), "period_end": date(2026, 11, 12), "next_payday": date(2026, 11, 13)}
PREV = {"period_start": date(2026, 10, 16), "period_end": date(2026, 10, 29), "next_payday": date(2026, 10, 30)}

def ledger() -> B.Ledger:
    rec = [{"merchant": "Netflix", "cadence": "monthly", "expected_cents": 1599, "next_date": date(2026, 11, 5 + 3)}, {"merchant": "Comcast", "cadence": "monthly", "expected_cents": 6400, "next_date": date(2026, 11, 20)}]
    acc = [{"name": "Chase Checking", "type": "checking", "balance_cents": 500000, "available_cents": 480000, "include_in_safe": True}, {"name": "SoFi Savings", "type": "savings", "balance_cents": 1200000},
           {"name": "Discover", "type": "credit", "balance_cents": 90000, "statement_balance_cents": 60000, "due_date": date(2026, 11, 10)}]
    stubs = [{"pay_date": date(2026, 10, 30), "gross": 373500, "net": 247707, "taxes": 87883, "deductions": 37910, "lines": [{"kind": "deduction", "label": "401(K)", "cents": 22410}, {"kind": "deduction", "label": "Medical", "cents": 9500}]},
             {"pay_date": date(2026, 10, 16), "gross": 373500, "net": 247707, "taxes": 87883, "deductions": 37910, "lines": [{"kind": "deduction", "label": "401(K)", "cents": 22410}]},
             {"pay_date": date(2025, 12, 31), "gross": 300000, "net": 200000, "taxes": 70000, "deductions": 30000, "lines": [{"kind": "deduction", "label": "401(K)", "cents": 18000}]}]
    return B.Ledger(D.rows(), D.TODAY, rec, acc, 10000, PERIOD, PREV, 231000, [{"name": "Asha Rao", "cents": 4000}, {"name": "Jo Lee", "cents": -2500}], ["Kaarthik Roshan", "Asha Rao", "Jo Lee"], {c: f"id-{c}" for c in D.CATS}, stubs)

R = D.rows()
def s(pred) -> int:
    return sum(-t["amount_cents"] for t in R if t["amount_cents"] < 0 and pred(t))
def counted(pred) -> int:
    return sum(t["out_cents"] for t in R if pred(t))
def between(a, b):
    return lambda t: a <= t["date"] <= b
OCT = between(date(2026, 10, 1), date(2026, 10, 31))
NOV = between(date(2026, 11, 1), D.TODAY)
YEAR = between(date(2026, 1, 1), D.TODAY)
PAYP = between(date(2026, 10, 30), D.TODAY)
cat = lambda *c: (lambda t: t["category"] in c)
both = lambda *p: (lambda t: all(x(t) for x in p))
kr = lambda t: "kaarthik" in (t["person"] or "").split()
SAFE = 480000 - 1599 - 60000 - 10000

CASES = [
 ("how much rent did I pay this year", s(both(YEAR, cat("Rent")))),
 ("how much did I send Kaarthik that wasn't rent this year", s(both(YEAR, kr, lambda t: t["category"] != "Rent"))),
 ("how much did I send Kaarthik this year", s(both(YEAR, kr))),
 ("how much did I send Kaarthik last month", s(both(OCT, kr))),
 ("what did I pay in rent in March", 120000),
 ("rent in October", 120000),
 ("how much on groceries last month", counted(both(OCT, cat("Groceries")))),
 ("how much did I spend on groceries this year", counted(both(YEAR, cat("Groceries")))),
 ("how much did I spend on food in October", counted(both(OCT, cat("Groceries", "Restaurants", "Coffee", "Food delivery")))),
 ("how much did I spend eating out last month", counted(both(OCT, cat("Restaurants", "Food delivery")))),
 ("how much at Chipotle this year", counted(both(YEAR, lambda t: t["merchant"] == "Chipotle"))),
 ("how much did I spend at Uber last 30 days", counted(both(between(date(2026, 10, 8), D.TODAY), lambda t: t["merchant"] == "Uber"))),
 ("how much did I spend on rideshare this month", counted(both(NOV, cat("Rideshare")))),
 ("how much did I spend yesterday", counted(between(date(2026, 11, 5), date(2026, 11, 5)))),
 ("how much did I spend this week", counted(between(date(2026, 11, 2), D.TODAY))),
 ("how much did I spend last week", counted(between(date(2026, 10, 26), date(2026, 11, 1)))),
 ("how much did I spend this month", counted(NOV)),
 ("how much did I spend last month", counted(OCT)),
 ("how much did I spend in October", counted(OCT)),
 ("how much have I spent since payday", counted(PAYP)),
 ("spending this pay period", counted(PAYP)),
 ("how much did I spend last pay period", counted(between(date(2026, 10, 16), date(2026, 10, 29)))),
 ("total spent this year", counted(YEAR)),
 ("how much on subscriptions in October", counted(both(OCT, cat("Subscriptions")))),
 ("how much did I spend on travel last month", 42000),
 ("how much did I spend, excluding rent, last month", counted(both(OCT, lambda t: t["category"] != "Rent"))),
 ("how much did I earn last month", sum(t["in_cents"] for t in R if OCT(t))),
 ("income this year", sum(t["in_cents"] for t in R if YEAR(t))),
 ("what's my biggest category last month", 120000),
 ("where did my money go in October", 120000),
 ("top merchants last month", 120000),
 ("what was my biggest purchase in October", 120000),
 ("spending this month vs last month", counted(NOV)),
 ("did I spend more than last month", counted(NOV)),
 ("groceries in October compared to September", counted(both(OCT, cat("Groceries")))),
 ("what's my balance", 1700000),
 ("how much money do I have", 1700000),
 ("what's due this week", 1599),
 ("upcoming bills", 1599),
 ("how much are my subscriptions", None),
 ("what's safe to spend", SAFE),
 ("how much can I spend", SAFE),
 ("can I afford $200", SAFE - 20000),
 ("what if I spend $5000", SAFE - 500000),
 ("when's payday", None),
 ("who owes me", 4000),
 ("how much does Asha owe me", 4000),
 ("how much do I owe Jo", -2500),
 ("show me zelle payments to Kaarthik last month", None),
 ("how much did I spend on friends and family last month", s(both(OCT, cat("Friends and family")))),
 ("how much tax have I paid this year", 87883 * 2),
 ("what was my last net pay", 247707),
 ("how much went to 401k", 22410 * 2),
 ("what was my gross pay last year", 300000),
]

def main() -> int:
    l = ledger()
    assert len(CASES) == 54, len(CASES)
    paths: dict = {}
    wrong = []
    for q, want in CASES:
        r, slots = B.route(q, l)
        res = B.run(r.tool, r.params, slots, l) if r.tool else None
        got = res.numbers.get("cents") if res else None
        ok = res is not None and (want is None or got == want)
        p = paths.setdefault(r.path, [0, 0]); p[1] += 1; p[0] += ok
        if not ok:
            wrong.append((q, r.path, r.tool, got, want))
    # learned: paraphrases the rules don't catch, answered after one thumbs up on another wording
    docs = [{"normalised": B.normalise(x, l), "tool": t, "params": {}} for x, t in [("hit me with my runway to next pay", "safe_to_spend"), ("tell me how long till the next pay cheque lands", "payday_info")]]
    m = B.Matcher(docs)
    for q, tool in [("hit me with the runway till my next pay", "safe_to_spend"), ("tell me how long until next pay cheque lands", "payday_info")]:
        r, _ = B.route(q, l, matcher=m)
        ok = r.path == "learned" and r.tool == tool
        p = paths.setdefault("learned", [0, 0]); p[1] += 1; p[0] += ok
        if not ok:
            wrong.append((q, r.path, r.tool, None, tool))
    for path, (a, b) in sorted(paths.items()):
        print(f"{path}: {a}/{b}")
    for w in wrong:
        print("WRONG", w)
    import os
    if os.environ.get("OPENROUTER_API_KEY"):
        print("cloud: key present; run tools/ai_smoke.py for the live routing check (reported, not gating)")
    else:
        print("cloud: skipped, no key")
    return 1 if wrong else 0

if __name__ == "__main__":
    sys.exit(main())
