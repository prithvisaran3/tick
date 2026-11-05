from datetime import datetime, timedelta, timezone

from app.reconcile import Txn, total_spend
from app.transfers import Row, pair

T0 = datetime(2026, 11, 10, 15, 0, tzinfo=timezone.utc)
TYPES = {"chase": "checking", "sofi_chk": "checking", "sofi_sav": "savings", "loan": "loan", "disc": "credit", "boa": "credit", "cap1": "credit"}

def r(id, acct, cents, days=0, merchant="", flow=None, cat=None, pair_id=None, edited=False):
    return Row(id, acct, cents, T0 + timedelta(days=days), merchant, flow, cat, pair_id, edited)

def test_card_payment_pairs_with_payment_received_and_both_become_transfers():
    rows = [r("p", "chase", -45000, 0, "DISCOVER E-PAYMENT", flow="transfer", cat="Transfer"),
            r("q", "disc", 45000, 1, "INTERNET PAYMENT - THANK YOU", flow="transfer")]
    out = pair(rows, TYPES)
    assert out["p"] == {"flow": "transfer", "transfer_pair_id": "p"} and out["q"] == {"flow": "transfer", "transfer_pair_id": "p"}

def test_partial_payments_pair_by_closest_date_not_crosswise():
    rows = [r("p1", "chase", -10000, 0, "BOA CARD PAYMENT"), r("p2", "chase", -10000, 14, "BOA CARD PAYMENT"),
            r("q2", "boa", 10000, 15, "PAYMENT RECEIVED"), r("q1", "boa", 10000, 2, "PAYMENT RECEIVED")]
    out = pair(rows, TYPES)
    assert out["q1"]["transfer_pair_id"] == "p1" and out["q2"]["transfer_pair_id"] == "p2"

def test_one_payment_covering_two_cards():
    rows = [r("p", "chase", -50000, 0, "ONLINE PAYMENT CARDS"),
            r("d", "disc", 30000, 1, "PAYMENT - THANK YOU"), r("b", "boa", 20000, 2, "PAYMENT RECEIVED"),
            r("noise", "cap1", 12000, 1, "PAYMENT RECEIVED")]
    out = pair(rows, TYPES)
    assert out["d"]["transfer_pair_id"] == "p" and out["b"]["transfer_pair_id"] == "p" and "noise" not in out
    assert out["p"]["flow"] == "transfer"

def test_unmatched_card_payment_stays_a_transfer_but_a_random_purchase_does_not():
    rows = [r("apple", "chase", -25000, 0, "APPLECARD GSBANK PAYMENT"), r("shop", "chase", -2500, 0, "PAYMENT SOLUTIONS LLC")]
    out = pair(rows, TYPES)
    assert out["apple"] == {"flow": "transfer"} and "shop" not in out

def test_chase_to_sofi_transfer_pairs_and_counts_as_neither_spending_nor_income():
    rows = [r("out", "chase", -100000, 0, "ONLINE TRANSFER TO SOFI", cat="Transfer"),
            r("in", "sofi_sav", 100000, 2, "TRANSFER FROM CHASE", cat="Transfer")]
    out = pair(rows, TYPES)
    assert out["out"]["flow"] == "transfer" and out["in"] == {"flow": "transfer", "transfer_pair_id": "out"}

def test_loan_payment_is_a_bill_on_checking_and_a_transfer_on_the_loan():
    rows = [r("pay", "chase", -40000, 0, "SOFI LOAN PMT", flow="bill", cat="Loan payment"), r("rcv", "loan", 40000, 1, "PAYMENT RECEIVED")]
    out = pair(rows, TYPES)
    assert out["pay"] == {"flow": "bill", "transfer_pair_id": "pay"} and out["rcv"]["flow"] == "transfer"
    alone = pair([r("pay2", "chase", -40000, 0, "SOFI LOAN PMT", cat="Loan payment")], TYPES)
    assert alone["pay2"] == {"flow": "bill"}

def test_card_refund_is_never_mistaken_for_a_payment():
    rows = [r("p", "chase", -3000, 0, "DISCOVER PAYMENT", flow="transfer"), r("refund", "disc", 3000, 1, "AMAZON MKTPL")]
    out = pair(rows, TYPES)
    assert out == {}                                  # refund untouched; the payment already was a transfer (nothing to change)

def test_zelle_to_a_friend_is_left_alone_and_zelle_to_myself_pairs():
    assert pair([r("z", "chase", -2000, 0, "Zelle payment to Sam")], TYPES) == {}
    out = pair([r("z", "chase", -2000, 0, "Zelle transfer to me"), r("zi", "sofi_chk", 2000, 0, "Zelle transfer from me")], TYPES)
    assert out["zi"]["transfer_pair_id"] == "z"

def test_too_far_apart_wrong_amount_already_paired_or_edited_never_pair():
    rows = [r("p", "chase", -5000, 0, "CAPITAL ONE PAYMENT", flow="transfer"), r("late", "cap1", 5000, 9, "PAYMENT"),
            r("off", "cap1", 4999, 1, "PAYMENT"), r("taken", "cap1", 5000, 1, "PAYMENT", pair_id="x"),
            r("mine", "cap1", 5000, 1, "PAYMENT", edited=True)]
    out = pair(rows, TYPES)
    assert out == {}

def test_pairing_is_idempotent():
    rows = [r("p", "chase", -45000, 0, "DISCOVER E-PAYMENT", flow="transfer"), r("q", "disc", 45000, 1, "PAYMENT")]
    first = pair(rows, TYPES)
    for x in rows:
        x.flow, x.pair = first[x.id]["flow"], first[x.id].get("transfer_pair_id")
    assert pair(rows, TYPES) == {}

def test_total_spend_ignores_internal_transfers():
    txns = [Txn("a", -5000, T0), Txn("b", -45000, T0, flow="transfer"), Txn("c", -40000, T0, flow="bill")]
    assert total_spend(txns) == 45000


def test_savings_transfer_does_not_steal_a_card_payment_credit():
    from datetime import datetime, timezone
    from app import transfers as T
    def r(i, acct, cents, merchant, day):
        return T.Row(id=i, account_id=acct, amount_cents=cents, occurred_at=datetime(2026, 11, day, 15, tzinfo=timezone.utc), merchant=merchant, flow=None, category=None, pair=None)
    rows = [r("o1", "chk", -50000, "ONLINE TRANSFER TO SAV", 2), r("o2", "chk", -50000, "CHASE CREDIT CRD AUTOPAY", 3),
            r("i2", "card", 50000, "AUTOMATIC PAYMENT - THANK YOU", 3), r("i1", "sav", 50000, "ONLINE TRANSFER FROM CHK", 4)]
    p = T.pair(rows, {"chk": "checking", "sav": "savings", "card": "credit"})
    assert p["o1"]["transfer_pair_id"] and p["i1"]["flow"] == "transfer"          # savings deposit is a transfer, not income
    assert p["o2"]["flow"] == "transfer" and p["i2"]["flow"] == "transfer"
