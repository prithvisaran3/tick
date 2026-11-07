"""Recurring shared bills and the split-a-card-charge pairing."""
from datetime import date, datetime, timezone

import pytest

from app import paybacks as P, tally as T, tally_bills as B
from tests.fakerest import FakeRest

U = "11111111-1111-1111-1111-111111111111"
BILL = {"id": "b1", "description": "Comcast Wifi", "match_text": "Comcast", "amount_cents": 6000, "next_on": "2026-11-15", "paid_by_member": "m1"}

def charge(i, cents, day, text="COMCAST CABLE 800", flow=None):
    return {"id": f"t{i}", "amount_cents": cents, "occurred_at": f"2026-11-{day:02d}T16:00:00+00:00", "merchant_raw": text, "merchant_clean": text, "flow": flow}

def test_matches_the_charge_by_name_amount_and_date():
    assert B.match_charge(BILL, [charge(1, -6000, 14)])["id"] == "t1"

@pytest.mark.parametrize("row", [charge(1, -6400, 15), charge(1, 6000, 15), charge(1, -6000, 25), charge(1, -6000, 15, "NETFLIX"), charge(1, -6000, 15, flow="transfer")])
def test_what_does_not_match(row):
    assert B.match_charge(BILL, [row]) is None

def test_a_small_change_in_price_still_matches_and_the_closest_date_wins():
    assert B.match_charge(BILL, [charge(1, -6200, 11), charge(2, -6100, 16)])["id"] == "t2"

class Rest(FakeRest):
    def __init__(self):
        super().__init__(); self.posts = []
    def rpc(self, fn, args):
        assert fn == "tally_post_recurring"
        self.posts.append(args)
        return "e1"

@pytest.fixture
def world(monkeypatch):
    f = Rest()
    monkeypatch.setattr(B, "rest", lambda: f)
    f.insert("tally_members", {"id": "m1", "member_user_id": U})
    f.insert("tally_recurring", {**BILL, "active": True})
    return f

def test_not_due_and_no_charge_waits(world):
    assert B.run(date(2026, 11, 12)) == 0 and world.posts == []

def test_due_posts_on_schedule_without_a_charge(world):
    assert B.run(date(2026, 11, 15)) == 1 and world.posts[0]["p_txn"] is None

def test_a_charge_posts_early_and_links(world):
    world.insert("transactions", {**charge(1, -6000, 12), "user_id": U, "occurred_at": datetime.now(timezone.utc).replace(year=2026, month=11, day=12).isoformat()})
    w = world.rows("transactions")[0]
    w["occurred_at"] = datetime.now(timezone.utc).isoformat()
    world.rows("tally_recurring")[0]["next_on"] = datetime.now(B.ET).date().isoformat()
    assert B.run(date.fromordinal(datetime.now(B.ET).date().toordinal() - 3)) == 1 and world.posts[0]["p_txn"] == "t1"

def test_a_charge_already_used_by_a_bill_is_not_used_again(world):
    world.insert("transactions", {**charge(1, -6000, 15), "user_id": U, "occurred_at": datetime.now(timezone.utc).isoformat()})
    world.insert("tally_expenses", {"transaction_id": "t1", "external_ref": "recurring:b0:2026-10-15"})
    world.rows("tally_recurring")[0]["next_on"] = datetime.now(B.ET).date().isoformat()
    B.run(date.fromordinal(datetime.now(B.ET).date().toordinal() - 3))
    assert world.posts == []

def test_clean_items_keeps_only_usable_lines():
    got = T.clean_items({"merchant": "Dishoom", "items": [{"name": "Naan", "price": 4.5}, {"name": "Bad", "price": "x"}, {"name": "Free", "price": 0}, "junk"], "tax": 1.25, "tip": None})
    assert got == {"merchant": "Dishoom", "items": [{"name": "Naan", "cents": 450}], "tax_cents": 125, "tip_cents": 0}

@pytest.mark.parametrize("raw", [None, [], {}, {"items": "no"}, {"items": []}, {"items": [{"name": "x", "price": -1}]}])
def test_clean_items_gives_up_cleanly(raw):
    assert T.clean_items(raw) is None

class PayRest(FakeRest):
    def __init__(self):
        super().__init__(); self.links = []
    def rpc(self, fn, args):
        self.links.append(args)
        return {}

@pytest.fixture
def split(monkeypatch):
    f = PayRest()
    monkeypatch.setattr(P, "rest", lambda: f)
    f.insert("tally_members", {"id": "me", "group_id": "g", "member_user_id": U, "name": "Me", "status": "active"})
    f.insert("tally_members", {"id": "a", "group_id": "g", "name": "Asha Rao", "status": "active"})
    f.insert("tally_expenses", {"id": "e", "group_id": "g", "transaction_id": "buy", "deleted_at": None})
    f.insert("tally_shares", [{"expense_id": "e", "member_id": "a", "owed_cents": 4000}, {"expense_id": "e", "member_id": "me", "owed_cents": 4000}])
    return f

def credit(f, cents, text="Zelle payment from ASHA RAO"):
    f.insert("transactions", {"id": "in", "user_id": U, "amount_cents": cents, "merchant_raw": text})

def test_accepting_the_friends_exact_share_settles_them_too(split):
    credit(split, 4000)
    assert P.settle_split(U, "buy", "in")
    s = split.rows("tally_settlements")[0]
    assert (s["from_member"], s["to_member"], s["amount_cents"], s["transaction_id"]) == ("a", "me", 4000, "in")

@pytest.mark.parametrize("cents,text", [(3999, "Zelle payment from ASHA RAO"), (4000, "Zelle payment from JO LEE")])
def test_a_different_amount_or_person_settles_nothing(split, cents, text):
    credit(split, cents, text)
    assert not P.settle_split(U, "buy", "in") and split.rows("tally_settlements") == []

def test_an_exact_settlement_also_nets_the_split_purchase(split):
    split.insert("transactions", {"id": "buy", "user_id": U, "amount_cents": -8000})
    P._net_the_purchase(U, {"group_id": "g", "from_member": "a", "amount_cents": 4000}, {"id": "in"})
    assert split.links[0]["p_purchase"] == "buy" and split.links[0]["p_source"] == "settlement"
