"""Apple Card CSV import (Part 4): parsing, de-duplication against live Wallet captures, idempotent re-import, the route."""
import pathlib

import pytest
from fastapi.testclient import TestClient

from app import applecard as AC
from app import audit as audit_mod
from app import imports, plaid as P, store
from app.auth import current_user
from app.main import app
from tests.fakerest import FakeRest

SAMPLE = (pathlib.Path(__file__).parent / "data" / "apple_card_sample.csv").read_bytes()
U = "11111111-1111-1111-1111-111111111111"

def test_parse_signs_kinds_and_categories():
    rows, bad = AC.parse(SAMPLE)
    assert bad == 1 and len(rows) == 8
    by = {(r.merchant, r.kind): r for r in rows}
    assert by[("Uber", "purchase")].amount_cents == -1840 and by[("Uber", "purchase")].category == "Rideshare"
    assert by[("Amazon", "credit")].amount_cents == 1999                       # refund: money back, not income
    pay = by[("Apple Card", "payment")]
    assert pay.amount_cents == 45000 and pay.category == "Transfer"
    assert by[("Apple", "purchase")].amount_cents == -4158                      # installment counts as a purchase
    assert next(r for r in rows if r.kind == "interest").category == "Fees and interest"
    coffees = [r for r in rows if r.merchant == "Blue Bottle Coffee"]
    assert len(coffees) == 2 and coffees[0].ref != coffees[1].ref               # two identical coffees are two purchases

def test_rejects_files_that_are_not_apple_card_exports():
    for raw in (b"", b"date,amount\n1,2\n", b"\xff\xfe\x00bad", b"x" * (AC.MAX_BYTES + 1)):
        with pytest.raises(AC.ImportError_):
            AC.parse(raw)

def test_live_captures_are_never_imported_twice():
    rows, _ = AC.parse(SAMPLE)
    live = [
        {"id": "w1", "amount_cents": -625, "occurred_at": "2026-11-03T23:10:00+00:00", "merchant_clean": "Blue Bottle Coffee"},   # Wallet capture
        {"id": "w2", "amount_cents": -1840, "occurred_at": "2026-11-04T01:00:00+00:00", "merchant_clean": "Uber"},                # next day UTC, same day NY
        {"id": "w3", "amount_cents": -4218, "occurred_at": "2026-11-05T20:00:00+00:00", "merchant_clean": "Whole Foods"},         # 4 days later: different
        {"id": "x", "amount_cents": -1840, "occurred_at": "2026-11-02T20:00:00+00:00", "merchant_clean": "Lyft"},                 # same amount, other merchant
    ]
    p = AC.plan_import(rows, live, set())
    assert sorted(t for _, t in p.duplicates) == ["w1", "w2"]                   # one coffee matched, the second coffee is new
    assert len(p.inserts) == 6
    again = AC.plan_import(rows, live, {r.ref for r in p.inserts})
    assert again.already_imported == 6 and not again.inserts                   # re-importing the file is a no-op

@pytest.fixture
def db(monkeypatch):
    f = FakeRest()
    for mod in (P, store, imports, audit_mod):
        monkeypatch.setattr(mod, "rest", lambda: f)
    for n in ["Restaurants", "Rideshare", "Groceries", "Shopping", "Transfer", "Fees and interest", "Other", "Coffee"]:
        f.insert("categories", {"user_id": U, "name": n})
    class Resp:
        def __init__(self, rows): self.rows = rows
        def raise_for_status(self): pass
        def json(self): return self.rows
    class C:
        def get(self, url, headers=None, params=None):
            return Resp([t for t in f.rows("transactions") if t["user_id"] == U])
    f.c, f.base, f.h = C(), "http://fake", {}
    return f

def test_route_imports_and_reports_counts(db):
    db.insert("transactions", {"user_id": U, "amount_cents": -625, "occurred_at": "2026-11-03T23:10:00+00:00", "merchant_clean": "Blue Bottle Coffee", "external_ref": None})
    app.dependency_overrides[current_user] = lambda: U
    try:
        c = TestClient(app)
        r = c.post("/import/apple-card", files={"file": ("statement.csv", SAMPLE, "text/csv")})
        assert r.status_code == 200
        assert r.json() == {"imported": 7, "skipped_duplicates": 1, "already_imported": 0, "unreadable": 1}
        r2 = c.post("/import/apple-card", files={"file": ("statement.csv", SAMPLE, "text/csv")})
        assert r2.json()["imported"] == 0 and r2.json()["already_imported"] == 7
        assert c.post("/import/apple-card", files={"file": ("x.csv", b"hello", "text/csv")}).status_code == 422
    finally:
        app.dependency_overrides.clear()
    apple = [a for a in db.rows("accounts") if a["provider_account_id"] == AC.APPLE_CARD_ACCOUNT_REF]
    assert len(apple) == 1 and apple[0]["type"] == "credit"
    inserted = [t for t in db.rows("transactions") if t.get("external_ref")]
    assert all(t["account_id"] == apple[0]["id"] for t in inserted)
    assert any(t["flow"] == "transfer" for t in inserted)                       # the payment is an internal transfer

def test_import_requires_sign_in():
    assert TestClient(app).post("/import/apple-card", files={"file": ("s.csv", SAMPLE, "text/csv")}).status_code == 401

def test_wallet_card_name_maps_to_the_apple_card_account(db):
    a = store.card_account(U, "Apple Card")
    assert a == store.card_account(U, "  apple card ") and len(db.rows("accounts")) == 1
    db.insert("accounts", {"user_id": U, "provider_account_id": "p1", "type": "credit", "institution": "Discover", "name": "Discover it", "mask": "1234"})
    assert store.card_account(U, "Discover It Card") == db.rows("accounts")[1]["id"]
    assert store.card_account(U, "Some Debit Card") is None
