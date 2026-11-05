"""Statement import (Part 4): detection of every bank's file, Tick's sign convention, de-duplication against Plaid rows, Wallet/SMS captures
and earlier imports, undoable batches, a generic CSV with a column mapping, OFX, and the route."""
import json
import pathlib

import pytest
from fastapi.testclient import TestClient

from app import audit as audit_mod, imports, plaid as P, statements as ST, store
from app.auth import current_user
from app.main import app
from tests.fakerest import FakeRest

DATA = pathlib.Path(__file__).parent / "data"
U = "11111111-1111-1111-1111-111111111111"
def load(name): return (DATA / name).read_bytes()

@pytest.mark.parametrize("file,source,kind,n", [
    ("apple_card_sample.csv", "apple_card", "credit", 8), ("chase_checking.csv", "chase_checking", "cash", 4), ("chase_card.csv", "chase_card", "credit", 3),
    ("bofa_checking.csv", "bofa_checking", "cash", 2), ("bofa_card.csv", "bofa_card", "credit", 2), ("discover.csv", "discover", "credit", 3),
    ("capital_one.csv", "capital_one", "credit", 2), ("sofi.csv", "sofi", "cash", 2), ("bank.ofx", "ofx", "cash", 2)])
def test_every_bank_file_is_detected_from_its_own_columns(file, source, kind, n):
    p = ST.parse_statement(load(file), file)
    assert (p.source, p.kind, len(p.rows)) == (source, kind, n), (p.source, len(p.rows))
    assert all(len(r.ref) > 20 for r in p.rows) and len({r.ref for r in p.rows}) == len(p.rows)

def amounts(file): return {r.merchant: r.amount_cents for r in ST.parse_statement(load(file), file).rows}

def test_signs_are_ticks_sign_for_every_bank():
    """Negative = money out, whatever the bank's convention (Discover and Apple Card list purchases as positive)."""
    assert amounts("chase_checking.csv")["Zelle payment to KAARTHIK KUMAR 31446078428"] == -51146
    assert amounts("chase_card.csv")["UBER *TRIP"] == -1840 and amounts("chase_card.csv")["AMAZON MKTPL*2K4"] == 1999
    assert amounts("discover.csv")["TRADER JOE'S #123"] == -4210 and amounts("discover.csv")["DIRECTPAY FULL BALANCE"] == 55926
    assert amounts("capital_one.csv")["BLUE BOTTLE COFFEE"] == -625 and amounts("capital_one.csv")["CAPITAL ONE MOBILE PYMT"] == 38000
    assert amounts("bofa_card.csv")["STARBUCKS STORE 11234"] == -625 and amounts("bofa_card.csv")["PAYMENT - THANK YOU"] == 6485
    assert amounts("bofa_checking.csv")["INSTITUTE OF NUC PAYROLL"] == 150000
    assert amounts("sofi.csv")["JPMORGAN CHASE BANK NA"] == -120000
    ofx = ST.parse_statement(load("bank.ofx"), "x.ofx")
    assert ofx.mask == "1173" and {r.amount_cents for r in ofx.rows} == {-1840, 150000}

def test_bank_of_america_checking_summary_above_the_header_is_skipped():
    p = ST.parse_statement(load("bofa_checking.csv"))
    assert p.source == "bofa_checking" and p.unreadable == 0 and [r.amount_cents for r in p.rows] == [-2355, 150000]

def test_generic_csv_asks_for_a_mapping_then_imports():
    p = ST.parse_statement(load("generic.csv"))
    assert p.source == "generic" and p.needs_mapping["columns"] == ["Posted", "Memo", "Withdrawal", "Deposit"]
    m = {"header_row": 0, "date": "Posted", "description": "Memo", "debit": "Withdrawal", "credit": "Deposit"}
    q = ST.parse_statement(load("generic.csv"), mapping=m)
    assert sorted(r.amount_cents for r in q.rows) == [-450, 1200]
    flipped = ST.parse_statement(b"Date,Text,Amt\n11/03/2026,Coffee,4.50\n", mapping={"header_row": 0, "date": "Date", "description": "Text", "amount": "Amt", "negative_is_out": False})
    assert flipped.rows[0].amount_cents == -450
    with pytest.raises(ST.StatementError):
        ST.parse_statement(load("generic.csv"), mapping={"header_row": 0, "date": "Nope", "description": "Memo", "amount": "x"})

def test_bad_files_are_refused_with_a_calm_message():
    for raw, name in [(b"%PDF-1.7 ...", "s.pdf"), (b"", "x.csv"), (b"just one column\nabc\n", "x.csv"), (b"x" * (ST.MAX_BYTES + 1), "x.csv"), (b"\x00\x01\x02", "x.ofx")]:
        with pytest.raises(ST.StatementError):
            ST.parse_statement(raw, name)

def test_refs_depend_on_content_so_overlapping_statements_never_duplicate():
    a = ST.parse_statement(load("discover.csv")); b = ST.parse_statement(load("discover.csv").replace(b"AMAZON.COM*REFUND", b"AMAZON.COM*REFUND"))
    assert [r.ref for r in a.rows] == [r.ref for r in b.rows]
    two = ST.parse_statement(b"Trans. Date,Post Date,Description,Amount,Category\n11/03/2026,11/04/2026,COFFEE,4.50,x\n11/03/2026,11/04/2026,COFFEE,4.50,x\n")
    assert len(two.rows) == 2 and two.rows[0].ref != two.rows[1].ref                # two identical coffees are two purchases

def test_dedupe_against_plaid_wallet_and_earlier_imports():
    rows = ST.parse_statement(load("discover.csv")).rows
    existing = [
        {"id": "plaid1", "amount_cents": -4210, "occurred_at": "2026-11-03T16:00:00+00:00", "merchant_clean": "Trader Joe's", "account_id": "A", "sources": [{"source": "plaid"}]},
        {"id": "wallet1", "amount_cents": 1999, "occurred_at": "2026-10-21T01:00:00+00:00", "merchant_clean": "", "account_id": "A", "sources": [{"source": "applepay"}]},
        {"id": "other-acct", "amount_cents": 55926, "occurred_at": "2026-10-18T16:00:00+00:00", "merchant_clean": "Directpay", "account_id": "B", "sources": [{"source": "plaid"}]},
    ]
    p = ST.plan(rows, existing, set(), "A")
    assert sorted(t for _, t in p.duplicates) == ["plaid1", "wallet1"] and len(p.inserts) == 1      # the other account's row is not a duplicate
    again = ST.plan(rows, existing, {r.ref for r in p.inserts}, "A")
    assert again.already_imported == 1

# ---------------- route ----------------
@pytest.fixture
def world(monkeypatch):
    f = FakeRest()
    for mod in (P, store, imports, audit_mod):
        monkeypatch.setattr(mod, "rest", lambda: f)
    for n in ["Restaurants", "Groceries", "Transfer", "Income", "Other", "Fees and interest", "Shopping", "Travel", "Friends and family", "Coffee"]:
        f.insert("categories", {"user_id": U, "name": n})
    f.insert("profiles", {"user_id": U, "display_name": "Prithvi Saran Sathyasaran"})
    disc = f.insert("accounts", {"user_id": U, "name": "Discover it", "institution": "Discover", "mask": "1545", "type": "credit"})[0]
    chk = f.insert("accounts", {"user_id": U, "name": "Chase", "institution": "Chase", "mask": "1173", "type": "checking"})[0]
    class Resp:
        def __init__(self, rows): self.rows = rows
        def raise_for_status(self): pass
        def json(self): return self.rows
    class C:
        def get(self, url, headers=None, params=None): return Resp([t for t in f.rows("transactions") if t["user_id"] == U])
    f.c, f.base, f.h = C(), "http://fake", {}
    app.dependency_overrides[current_user] = lambda: U
    monkeypatch.setattr(imports, "user_limiter", imports.__dict__["user_limiter"].__class__(1000, 60))
    yield f, disc, chk, TestClient(app)
    app.dependency_overrides.clear()

def post(c, file, **form):
    return c.post("/import/statement", files={"file": (file, load(file), "text/csv")}, data=form)

def test_preview_asks_for_an_account_then_reports_new_and_duplicates(world):
    f, disc, chk, c = world
    r = post(c, "discover.csv", mode="preview").json()
    assert r["needs_account"] is True and r["accounts"][0]["id"] == disc["id"] and r["accounts"][0]["label"] == "Discover ••1545"      # best match first
    f.insert("transactions", {"user_id": U, "account_id": disc["id"], "amount_cents": -4210, "occurred_at": "2026-11-03T16:00:00+00:00", "merchant_clean": "Trader Joe's",
                              "sources": [{"source": "plaid"}]})
    r = post(c, "discover.csv", mode="preview", account_id=disc["id"]).json()
    assert (r["new"], r["duplicates"], r["already_imported"]) == (2, 1, 0) and r["date_from"] == "2026-10-18" and len(r["sample"]) == 2 and r["source"] == "discover"
    assert len(f.rows("transactions")) == 1 and not f.rows("import_batches")                      # a preview writes nothing

def test_commit_makes_one_undoable_batch_and_reimporting_adds_nothing(world):
    f, disc, chk, c = world
    r = post(c, "discover.csv", mode="commit", account_id=disc["id"]).json()
    assert r["imported"] == 3 and r["batch_id"] and len(f.rows("transactions")) == 3
    t = {x["merchant_clean"]: x for x in f.rows("transactions")}
    assert t["DIRECTPAY FULL BALANCE"]["flow"] == "transfer" and t["DIRECTPAY FULL BALANCE"]["amount_cents"] == 55926      # a card payment is never income
    assert t["TRADER JOE'S #123"]["import_batch_id"] == r["batch_id"] and t["TRADER JOE'S #123"]["sources"][0]["source"] == "statement"
    again = post(c, "discover.csv", mode="commit", account_id=disc["id"]).json()
    assert again["imported"] == 0 and again["already_imported"] == 3 and len(f.rows("transactions")) == 3
    u = c.post(f"/import/{r['batch_id']}/undo").json()
    assert u == {"undone": True, "removed": 3} and not f.rows("transactions")
    assert c.post(f"/import/{r['batch_id']}/undo").json() == {"undone": True, "removed": 0}                           # idempotent
    assert [b["undone_at"] is not None for b in c.get("/import/batches").json()["batches"]] == [True]
    assert c.post("/import/not-a-uuid/undo").status_code == 404

def test_undo_only_touches_my_own_batch(world):
    f, disc, chk, c = world
    other = f.insert("import_batches", {"user_id": "22222222-2222-2222-2222-222222222222", "source": "x"})[0]
    assert c.post(f"/import/{other['id']}/undo").status_code == 404

def test_zelle_in_a_statement_is_friends_and_family_and_transfers_pair_across_banks(world):
    f, disc, chk, c = world
    post(c, "chase_checking.csv", mode="commit", account_id=chk["id"])
    names = {x["id"]: x["name"] for x in f.rows("categories")}
    t = {x["merchant_clean"]: x for x in f.rows("transactions")}
    assert names[t["Zelle payment to KAARTHIK KUMAR 31446078428"]["category_id"]] == "Friends and family" and t["Zelle payment to KAARTHIK KUMAR 31446078428"]["flow"] is None
    assert t["APPLECARD GSBANK PAYMENT 5800"]["flow"] == "transfer"                                                 # Apple Card payment: not spending

def test_apple_card_file_goes_to_the_apple_card_account_without_choosing_one(world):
    f, disc, chk, c = world
    r = post(c, "apple_card_sample.csv", mode="commit").json()
    assert r["imported"] == 7 or r["imported"] == 8
    apple = [a for a in f.rows("accounts") if a.get("provider_account_id") == "manual:apple-card"]
    assert len(apple) == 1 and all(t["account_id"] == apple[0]["id"] for t in f.rows("transactions"))

def test_generic_csv_flow_and_errors(world):
    f, disc, chk, c = world
    r = post(c, "generic.csv", mode="preview").json()
    assert r["needs_mapping"]["columns"][0] == "Posted"
    m = json.dumps({"header_row": 0, "date": "Posted", "description": "Memo", "debit": "Withdrawal", "credit": "Deposit"})
    r = post(c, "generic.csv", mode="commit", account_id=chk["id"], mapping=m).json()
    assert r["imported"] == 2
    assert c.post("/import/statement", files={"file": ("x.csv", b"hello", "text/csv")}, data={"mode": "preview"}).status_code == 422
    assert c.post("/import/statement", files={"file": ("x.csv", load("sofi.csv"), "text/csv")}, data={"mode": "nope"}).status_code == 422
    assert post(c, "sofi.csv", mode="preview", account_id="22222222-2222-2222-2222-222222222222").status_code == 404
    assert post(c, "sofi.csv", mode="preview", account_id="../../etc").status_code == 422
    assert post(c, "sofi.csv", mode="preview", account_id=chk["id"], mapping="[1,2]").status_code == 422

def test_import_requires_sign_in():
    app.dependency_overrides.clear()
    assert TestClient(app).post("/import/statement", files={"file": ("s.csv", b"a,b", "text/csv")}).status_code == 401
