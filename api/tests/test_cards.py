"""Cards, loans and the Plaid sign convention (Part 3)."""
from datetime import datetime, timedelta, timezone

import pytest

from app import plaid as P
from app.reconcile import Candidate, plan_and_apply
from tests.fakerest import FakeRest

IDS = {n: f"c-{n}" for n in ["Groceries", "Restaurants", "Transfer", "Income", "Other", "Loan payment", "Fees and interest", "Shopping", "Rideshare"]}
ACCTS = {"chk": {"id": "A-chk", "mask": "1173", "type": "checking"}, "disc": {"id": "A-disc", "mask": "1234", "type": "credit"},
         "loan": {"id": "A-loan", "mask": "9001", "type": "loan"}}

def tx(acct, amount, name, primary="", detailed="", **kw):
    return {"transaction_id": f"t-{name}-{amount}", "account_id": acct, "amount": amount, "date": "2026-11-03", "name": name,
            "personal_finance_category": {"primary": primary, "detailed": detailed}, **kw}

def cand(t):
    return P.plaid_candidate(t, ACCTS, {}, IDS)

def test_card_purchase_is_spending_with_the_card_mask():
    c, _ = cand(tx("disc", 42.10, "TRADER JOE'S", "FOOD_AND_DRINK", "FOOD_AND_DRINK_GROCERIES"))
    assert c.amount_cents == -4210 and c.flow is None and c.card_last4 == "1234" and c.category_id == "c-Groceries"

def test_card_payment_both_sides_are_transfers_not_income_or_spending():
    out, _ = cand(tx("chk", 450.00, "DISCOVER E-PAYMENT", "LOAN_PAYMENTS", "LOAN_PAYMENTS_CREDIT_CARD_PAYMENT"))
    rcv, _ = cand(tx("disc", -450.00, "INTERNET PAYMENT - THANK YOU", "LOAN_PAYMENTS", "LOAN_PAYMENTS_CREDIT_CARD_PAYMENT"))
    assert out.amount_cents == -45000 and out.flow == "transfer" and out.category_id == "c-Transfer"
    assert rcv.amount_cents == 45000 and rcv.flow == "transfer" and rcv.category_id == "c-Transfer"

def test_card_refund_lowers_spending_and_is_never_income():
    c, tags = cand(tx("disc", -19.99, "AMAZON MKTPL", "GENERAL_MERCHANDISE", "GENERAL_MERCHANDISE_ONLINE_MARKETPLACES"))
    assert c.amount_cents == 1999 and c.category_id != "c-Income" and c.flow is None and "refund" in tags

def test_student_loan_payment_is_a_bill_and_the_loan_side_a_transfer():
    pay, tags = cand(tx("chk", 400.00, "SOFI LOAN PMT", "LOAN_PAYMENTS", "LOAN_PAYMENTS_STUDENT_LOAN_PAYMENT"))
    assert pay.flow == "bill" and pay.category_id == "c-Loan payment" and "business" not in tags
    rcv, _ = cand(tx("loan", -400.00, "PAYMENT RECEIVED", "LOAN_PAYMENTS", "LOAN_PAYMENTS_STUDENT_LOAN_PAYMENT"))
    assert rcv.flow == "transfer" and rcv.amount_cents == 40000

def test_fees_and_interest_get_their_own_category():
    for t in (tx("disc", 31.20, "INTEREST CHARGE ON PURCHASES", "BANK_FEES", "BANK_FEES_INTEREST_CHARGE"),
              tx("disc", 39.00, "LATE FEE"), tx("loan", 12.00, "INTEREST")):
        c, _ = cand(t)
        assert c.category_id == "c-Fees and interest" and c.amount_cents < 0

def test_paycheck_on_checking_is_income():
    c, _ = cand(tx("chk", -2310.00, "ACME PAYROLL", "INCOME", "INCOME_WAGES"))
    assert c.category_id == "c-Income" and c.amount_cents == 231000

def test_pending_to_posted_card_purchase_is_one_row():
    pend, _ = cand({**tx("disc", 18.40, "UBER *TRIP", "TRANSPORTATION"), "transaction_id": "p1", "pending": True})
    post, _ = cand({**tx("disc", 18.40, "UBER *TRIP", "TRANSPORTATION"), "transaction_id": "t1", "pending_transaction_id": "p1"})
    ledger = []
    plan_and_apply(ledger, pend, "row-1")
    plan_and_apply(ledger, post, "row-2")
    assert len(ledger) == 1 and ledger[0].status == "posted" and ledger[0].plaid_transaction_id == "t1"

@pytest.mark.parametrize("order", ["wallet_first", "plaid_first"])
def test_wallet_capture_and_plaid_card_purchase_are_one_row(order):
    at = datetime(2026, 11, 3, 23, 12, tzinfo=timezone.utc)
    wallet = Candidate("applepay", "wallet-1", -1260, at, "Blue Bottle Coffee", "Blue Bottle Coffee", None, "posted", confidence=0.95)
    plaid, _ = cand({**tx("disc", 12.60, "BLUE BOTTLE COFFEE", "FOOD_AND_DRINK"), "datetime": (at + timedelta(minutes=3)).isoformat()})
    ledger = []
    for i, c in enumerate([wallet, plaid] if order == "wallet_first" else [plaid, wallet]):
        plan_and_apply(ledger, c, f"row-{i}")
    assert len(ledger) == 1 and ledger[0].amount_cents == -1260 and {s["source"] for s in ledger[0].sources} == {"applepay", "plaid"}

def test_accounts_store_owed_as_negative_and_only_masks(monkeypatch):
    f = FakeRest()
    monkeypatch.setattr(P, "rest", lambda: f)
    accts = [{"account_id": "x1", "name": "Discover it", "mask": "1234", "type": "credit", "subtype": "credit card",
              "balances": {"current": 812.40, "available": 4187.60, "limit": 5000}},
             {"account_id": "x2", "name": "Student loan", "mask": "9001", "type": "loan", "subtype": "student", "balances": {"current": 18250.00}},
             {"account_id": "x3", "name": "SoFi Savings", "mask": "7781", "type": "depository", "subtype": "savings", "balances": {"current": 3000}}]
    out = P._ensure_accounts("U", "conn", accts, "Discover")
    assert out["x1"]["balance_cents"] == -81240 and out["x1"]["credit_limit_cents"] == 500000 and out["x1"]["type"] == "credit"
    assert out["x2"]["type"] == "loan" and out["x2"]["balance_cents"] == -1825000 and not out["x2"]["include_in_safe"]
    assert out["x3"]["type"] == "savings" and out["x1"]["institution"] == "Discover"
    assert all(set(r) & {"account_number", "routing", "numbers"} == set() for r in f.rows("accounts"))
    P.apply_liabilities("U", {"credit": [{"account_id": "x1", "last_statement_balance": 640.12, "minimum_payment_amount": 35, "next_payment_due_date": "2026-11-21",
                                          "last_statement_issue_date": "2026-10-25", "aprs": [{"apr_type": "purchase_apr", "apr_percentage": 24.99}]}],
                                "student": [{"account_id": "x2", "interest_rate_percentage": 5.5, "minimum_payment_amount": 400, "next_payment_due_date": "2026-11-28"}]}, out)
    card = next(r for r in f.rows("accounts") if r["provider_account_id"] == "x1")
    loan = next(r for r in f.rows("accounts") if r["provider_account_id"] == "x2")
    assert card["statement_balance_cents"] == 64012 and card["minimum_payment_cents"] == 3500 and card["apr_bps"] == 2499 and card["next_payment_due_date"] == "2026-11-21"
    assert loan["interest_rate_bps"] == 550 and loan["next_payment_cents"] == 40000

def test_link_token_asks_for_liabilities_optionally_and_falls_back(monkeypatch):
    sent = []
    class Http:
        def post(self, path, json):
            sent.append(dict(json))
            if "optional_products" in json:
                return type("R", (), {"status_code": 400, "json": lambda self: {"error_code": "INVALID_PRODUCT", "error_type": "INVALID_INPUT"}})()
            return type("R", (), {"status_code": 200, "json": lambda self: {"link_token": "link-x"}})()
    prov = P.PlaidProvider("cid", "sec", "sandbox", "https://x/webhooks/plaid")
    prov.http = Http()
    assert prov.create_link_token("U")["link_token"] == "link-x"
    assert sent[0]["optional_products"] == ["liabilities"] and "optional_products" not in sent[1] and sent[1]["products"] == ["transactions"]
    sent.clear()
    prov.create_link_token("U", access_token="access-sandbox-x")             # update mode: never adds products
    assert len(sent) == 1 and "products" not in sent[0] and "optional_products" not in sent[0]
