"""MONEY_RULES.md end to end on fixtures shaped like the real accounts: classify at ingest, pair transfers across institutions, and (in
supabase/tests/money_rules.sql, generated from the same fixture) the SQL totals. One fixture, two engines, same expectations."""
import json
import pathlib
from datetime import datetime, timezone

import pytest

from app import plaid as P, store, transfers as T
from app import audit as audit_mod
from tests.fakerest import FakeRest

FIX = json.loads((pathlib.Path(__file__).parent / "data" / "money_rules.json").read_text())
U = "11111111-1111-1111-1111-111111111111"
CATS = ["Groceries", "Restaurants", "Coffee", "Transfer", "Income", "Other", "Fees and interest", "Loan payment", "Shopping", "Software", "Rideshare", "Friends and family", "Rent", "Rent"]

def plaid_txn(r):
    return {"transaction_id": r["k"], "account_id": r["acct"], "amount": -r["cents"] / 100, "date": f"2026-10-{r['day']:02d}" if r["day"] > 15 else f"2026-11-{r['day']:02d}",
            "name": r["desc"], "pending": False, "personal_finance_category": {"primary": r["pfc"][0], "detailed": r["pfc"][1]}}

@pytest.fixture
def world(monkeypatch):
    f = FakeRest()
    for mod in (P, store, audit_mod):
        monkeypatch.setattr(mod, "rest", lambda: f)
    for n in CATS:
        f.insert("categories", {"user_id": U, "name": n, "kind": "transfer" if n == "Transfer" else "income" if n == "Income" else "spend"})
    f.insert("profiles", {"user_id": U, "display_name": FIX["me"]})
    ids = {}
    for key, a in FIX["accounts"].items():
        ids[key] = f.insert("accounts", {"user_id": U, "name": a["institution"] + " " + a["mask"], "type": a["type"], "institution": a["institution"], "mask": a["mask"]})[0]["id"]
    name_to_id, id_to_name = store.category_maps(U)
    accts = {k: {"id": ids[k], "mask": FIX["accounts"][k]["mask"], "type": FIX["accounts"][k]["type"]} for k in ids}
    for r in FIX["rows"]:
        cand, tags = P.plaid_candidate(plaid_txn(r), accts, {}, name_to_id)
        f.insert("transactions", {"user_id": U, "account_id": ids[r["acct"]], "amount_cents": cand.amount_cents, "occurred_at": cand.occurred_at.isoformat(),
                                  "merchant_raw": r["desc"], "merchant_clean": r["desc"], "category_id": cand.category_id, "flow": cand.flow, "tags": tags,
                                  "plaid_transaction_id": r["k"], "user_edited": []})
    P.apply_money_rules(U, f.rows("transactions"))
    names = {r["id"]: r["name"] for r in f.rows("categories")}
    byk = {t["plaid_transaction_id"]: t for t in f.rows("transactions")}
    return f, byk, names, ids

@pytest.mark.parametrize("row", FIX["rows"], ids=[r["k"] for r in FIX["rows"]])
def test_every_row_ends_with_the_expected_flow_and_category(world, row):
    f, byk, names, ids = world
    t = byk[row["k"]]
    assert t["flow"] == row["flow"], (row["desc"], t["flow"])
    assert names[t["category_id"]] == row["cat"], (row["desc"], names[t["category_id"]])

def test_chase_and_sofi_are_the_same_transfer_and_both_sides_are_excluded(world):
    f, byk, names, ids = world
    a, b = byk["chase_in"], byk["sofi_out"]
    assert a["flow"] == b["flow"] == "transfer" and a["transfer_pair_id"] == b["transfer_pair_id"] is not None
    assert names[b["category_id"]] == "Transfer"          # the SoFi side used to count as "Other" spending

def test_zelle_to_and_from_people_is_real_money_never_a_transfer(world):
    f, byk, names, ids = world
    for k in ("zelle_out", "zelle_in", "venmo_cashout"):
        assert byk[k]["flow"] is None and names[byk[k]["category_id"]] == "Friends and family", k
    for k in ("zelle_me_in", "zelle_me_out"):                      # money to MY OWN name is the internal move
        assert byk[k]["flow"] == "transfer"

def test_the_apple_card_payment_is_not_spending_even_though_apple_card_is_not_on_plaid(world):
    f, byk, names, ids = world
    assert byk["apple_pay_chase"]["flow"] == "transfer" and byk["apple_buy"]["flow"] is None

def test_student_loan_payment_is_a_bill_and_the_loan_side_is_excluded(world):
    f, byk, names, ids = world
    assert byk["loan_pay"]["flow"] == "bill" and byk["loan_rcv"]["flow"] == "transfer"

def test_rerunning_the_rules_changes_nothing(world):
    f, byk, names, ids = world
    assert P.apply_money_rules(U, f.rows("transactions")) == 0

def test_a_flow_the_person_set_by_hand_is_never_overridden(world):
    f, byk, names, ids = world
    t = byk["zelle_out"]
    f.update("transactions", {"id": t["id"]}, {"user_edited": ["flow"], "flow": None})
    P.apply_money_rules(U, f.rows("transactions"))
    assert byk["zelle_out"]["flow"] is None

def test_rows_before_the_fix_get_repaired(world, monkeypatch):
    """The live data was classified by the old rules (Zelle as Transfer, SoFi side as Other). repairs.reclassify fixes it."""
    f, byk, names, ids = world
    from app import repairs
    monkeypatch.setattr(repairs, "rest", lambda: f)
    transfer = next(i for i, n in names.items() if n == "Transfer")
    other = next(i for i, n in names.items() if n == "Other")
    f.update("transactions", {"plaid_transaction_id": "zelle_out"}, {"category_id": transfer, "flow": None})
    f.update("transactions", {"plaid_transaction_id": "sofi_out"}, {"category_id": other, "flow": None, "transfer_pair_id": None})
    f.update("transactions", {"plaid_transaction_id": "chase_in"}, {"flow": None, "transfer_pair_id": None})
    dry = repairs.reclassify(U, apply=False)
    assert dry["changed"] >= 3 and byk["zelle_out"]["flow"] is None and names[byk["zelle_out"]["category_id"]] == "Transfer"     # dry run wrote nothing
    repairs.reclassify(U, apply=True)
    assert names[byk["zelle_out"]["category_id"]] == "Friends and family" and byk["sofi_out"]["flow"] == byk["chase_in"]["flow"] == "transfer"
    assert repairs.reclassify(U, apply=False)["changed"] == 0

def test_p2p_and_institution_helpers():
    assert T.is_p2p("Zelle payment to Sam") and T.is_p2p("VENMO CASHOUT") and not T.is_p2p("Whole Foods")
    assert T.inst_keys("JPMORGAN CHASE BANK, NA") == {"chase"} and "sofi" in T.inst_keys("SoFi Bank TRANSFER") and T.inst_keys("Trader Joe's") == set()
    names = T.name_tokens("Prithvi Saran Sathyasaran")
    assert T.mentions_me("Zelle payment from Prithvi Saran Sathyasaran 0PE0", names) and T.mentions_me("SoFi Bank TRANSFER PSathyasaran", names)
    assert not T.mentions_me("Zelle payment to KAARTHIK KUMAR", names)

def test_the_generated_sql_fixture_is_fresh():
    import subprocess, sys
    r = subprocess.run([sys.executable, str(pathlib.Path(__file__).parents[2] / "tools/gen_money_sql.py"), "--check"], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr


def test_wallet_refund_is_not_income(monkeypatch):
    import datetime
    from app import ingest
    from app.parsers import ParsedAlert
    monkeypatch.setattr(ingest.store, "category_maps", lambda u: ({"Income": "c-inc", "Shopping": "c-shop"}, {}))
    monkeypatch.setattr(ingest.store, "learned_rules", lambda u: [])
    p = ParsedAlert(merchant_raw="Apple Store", amount_cents=4000, confidence=0.9, card_last4=None)
    cand, tags = ingest.build_candidate("u", "applepay", "r1", p, datetime.datetime.now())
    assert "refund" in tags and cand.category_id != "c-inc"
    cand, tags = ingest.build_candidate("u", "sms", "r2", p, datetime.datetime.now())
    assert cand.category_id == "c-inc"
