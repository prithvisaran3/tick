"""Splitwise emails (format assumed), matching, and the Likely Splitwise classifier."""
import json
import pathlib
from datetime import date

import pytest

from app import splitwise_mail as M

MAIL = json.loads((pathlib.Path(__file__).parent / "data" / "splitwise_emails.json").read_text())

@pytest.mark.parametrize("m", MAIL, ids=[m["id"] for m in MAIL])
def test_parse(m):
    e = M.parse_email(m["id"], m["subject"], m["text"], date.fromisoformat(m["on"]))
    if m["want"] is None:
        assert e is None
    else:
        assert {k: getattr(e, k) for k in m["want"]} == m["want"] and e.gmail_id == m["id"]

def test_the_body_is_never_kept():
    e = M.parse_email("x", 'A added "Dinner"', "Total: $9.00 You owe $3.00. Secret stuff here", date(2026, 1, 1))
    assert "Secret" not in json.dumps(e.__dict__, default=str)

def ev(i, kind, on="2026-10-10", **k):
    return {"id": i, "kind": kind, "occurred_on": on, "matched_txn": None, **k}

def tx(i, cents, on="2026-10-10", text="Dishoom", **k):
    return {"id": i, "amount_cents": cents, "occurred_at": f"{on}T16:00:00+00:00", "merchant_raw": text, "merchant_clean": text, **k}

def test_my_card_charge_counts_only_my_share():
    got = M.match([ev("e", "expense", description="Dinner", total_cents=9000, my_share_cents=3000)], [tx("t", -9000)])
    assert got == [{"event": "e", "txn": "t", "kind": "expense", "shared_cents": 6000, "note": "Splitwise: Dinner"}]

def test_a_zelle_out_is_the_settle_up_and_lists_what_it_covered():
    got = M.match([ev("a", "expense", on="2026-10-01", description="Wi-Fi", total_cents=6000, my_share_cents=2000), ev("s", "settle_out", person="Asha R.", total_cents=2000)],
                  [tx("t", -2000, text="Zelle payment to ASHA RAO 1")])
    assert got[0]["kind"] == "settle" and got[0]["covers"] == ["Wi-Fi"] and "Wi-Fi" in got[0]["note"]

def test_rent_rules_win_over_a_splitwise_match():
    assert M.match([ev("s", "settle_out", person="Kaarthik R.", total_cents=120000)], [tx("t", -120000, text="Zelle payment to KAARTHIK ROSHAN", category_rule_id="r1")]) == []

def test_manual_edits_win_and_wrong_people_or_dates_do_not_match():
    e = [ev("s", "settle_out", person="Asha R.", total_cents=2000)]
    assert M.match(e, [tx("t", -2000, text="Zelle payment to ASHA RAO", user_edited=["category"])]) == []
    assert M.match(e, [tx("t", -2000, text="Zelle payment to JO LEE")]) == []
    assert M.match(e, [tx("t", -2000, on="2026-11-10", text="Zelle payment to ASHA RAO")]) == []

def test_each_row_is_used_once():
    e = [ev("a", "expense", description="x", total_cents=100, my_share_cents=50), ev("b", "expense", description="y", total_cents=100, my_share_cents=50)]
    assert len(M.match(e, [tx("t", -100)])) == 1

def base(i, cents, text, **k):
    return {**tx(i, cents, on="2026-10-20", text=text), "account_id": "chk", "flow": None, "reimbursed_cents": 0, **k}

TYPES = {"chk": "checking", "card": "credit"}

def test_money_with_a_tally_friend_is_likely_splitwise():
    got = M.likely([base("t", -4500, "Zelle payment to ASHA RAO")], TYPES, ["Asha Rao"], set())
    assert got[0]["txn_id"] == "t" and got[0]["reason"] == "friend"

def test_rent_and_rejected_rows_are_left_alone():
    assert M.likely([base("t", -4500, "Zelle payment to ASHA RAO", category_rule_id="r")], TYPES, ["Asha Rao"], set()) == []
    assert M.likely([base("t", -4500, "Zelle payment to ASHA RAO")], TYPES, ["Asha Rao"], {"t"}) == []

def test_a_shared_looking_charge_that_got_paid_back_is_likely():
    rows = [{**base("c", -9000, "Dishoom", account_id="card", cat_name="Restaurants"), "occurred_at": "2026-10-10T16:00:00+00:00"}, base("z", 3000, "Zelle payment from JO LEE")]
    assert any(o["txn_id"] == "c" and o["reason"] == "paid_back" for o in M.likely(rows, TYPES, [], set()))
