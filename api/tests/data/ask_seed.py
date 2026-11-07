"""A year of money for Ask Tick's eval. today = 2026-11-06, a biweekly payday anchored on Nov 13. Rent to Kaarthik Roshan by Zelle, settle-ups to him, another Kaarthik, the lot."""
from datetime import date, timedelta

TODAY = date(2026, 11, 6)
CATS = ["Groceries", "Restaurants", "Food delivery", "Coffee", "Rideshare", "Travel", "Shopping", "Subscriptions", "Software", "Rent", "Utilities", "Fun", "Friends and family", "Fees and interest", "Income", "Other", "Splitwise"]

def rows() -> list[dict]:
    out = []
    def add(i, merchant, cents, d, cat, person=None, counted=True):
        out.append({"id": f"t{i}", "merchant": merchant, "amount_cents": cents, "date": d, "category": cat, "tags": [], "person": person,
                    "out_cents": (-cents if cents < 0 else 0) if counted else 0, "in_cents": (cents if cents > 0 else 0) if counted else 0})
    n = 0
    for m in range(1, 12):
        d = date(2026, m, 1)
        n += 1; add(n, "Zelle payment to KAARTHIK ROSHAN", -120000, d, "Rent", "kaarthik roshan")
        n += 1; add(n, "Whole Foods", -8000 - m * 100, d + timedelta(days=2), "Groceries")
        if m < 11 or d + timedelta(days=4) <= TODAY:
            n += 1; add(n, "Chipotle", -1500, d + timedelta(days=3), "Restaurants")
        n += 1; add(n, "Netflix", -1599, d + timedelta(days=4), "Subscriptions") if m < 11 else None
    for i, (d, c) in enumerate([(date(2026, 3, 12), -4500), (date(2026, 7, 20), -9000), (date(2026, 10, 18), -3300)]):
        n += 1; add(n, "Zelle payment to KAARTHIK ROSHAN", c, d, "Friends and family", "kaarthik roshan", counted=False)
    n += 1; add(n, "Zelle payment to KAARTHIK KUMAR", -7000, date(2026, 9, 9), "Friends and family", "kaarthik kumar", counted=False)
    n += 1; add(n, "Zelle payment from ASHA RAO", 5000, date(2026, 10, 25), "Friends and family", "asha rao", counted=False)
    for d, c in [(date(2026, 10, 2), 231000), (date(2026, 10, 16), 231000), (date(2026, 10, 30), 231000)]:
        n += 1; add(n, "Institute Payroll", c, d, "Income")
    n += 1; add(n, "Delta", -42000, date(2026, 10, 12), "Travel")
    n += 1; add(n, "Uber", -1840, date(2026, 11, 5), "Rideshare")
    n += 1; add(n, "Uber", -2210, date(2026, 10, 31), "Rideshare")
    n += 1; add(n, "DoorDash", -2600, date(2026, 10, 28), "Food delivery")
    n += 1; add(n, "Blue Bottle", -575, date(2026, 11, 4), "Coffee")
    return out
