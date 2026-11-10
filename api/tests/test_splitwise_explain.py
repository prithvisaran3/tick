"""What a Splitwise row most likely was, "Not this one", tags, and what a Zelle could settle."""
from app import splitwise_explain as X

def tx(cents, on="2026-10-10", text="Dishoom", i="t"):
    return {"id": i, "amount_cents": cents, "occurred_at": f"{on}T16:00:00+00:00", "merchant_raw": text, "merchant_clean": text}

def ex(i, cents, on="2026-10-10", mine=True, share=0, by="Me", g="g1", desc="Dinner", txn=None):
    return {"id": i, "group_id": g, "group_name": "Flat", "description": desc, "amount_cents": cents, "spent_on": on, "paid_by_me": mine, "paid_by_name": by,
            "my_share_cents": share, "transaction_id": txn}

def test_a_card_charge_is_the_tally_expense_i_paid_that_day():
    got = X.explain(tx(-9000), [], [ex("e1", 9000), ex("e2", 9000, on="2026-10-13")], [], None, set())
    assert [c["ref"] for c in got] == ["e1", "e2"] and got[0]["confidence"] == 0.9 and got[1]["confidence"] == 0.75

def test_a_linked_expense_wins():
    assert X.explain(tx(-9000), [], [ex("e1", 9000), ex("e9", 4000, txn="t")], [], None, set())[0]["ref"] == "e9"

def test_a_splitwise_email_counts_when_gmail_has_it():
    ev = [{"id": "s1", "kind": "expense", "description": "Groceries", "total_cents": 9000, "occurred_on": "2026-10-10"}]
    got = X.explain(tx(-9000), ev, [], [], None, set())
    assert got[0]["source"] == "splitwise" and got[0]["confidence"] == 0.92

def test_not_this_one_shows_the_next():
    got = X.explain(tx(-9000), [], [ex("e1", 9000), ex("e2", 9000, on="2026-10-13")], [], None, {"e1"})
    assert [c["ref"] for c in got] == ["e2"]

def test_a_zelle_out_pays_what_i_owe():
    b = [{"group_id": "g1", "group_name": "Flat", "name": "Asha Rao", "cents": -4000}]
    got = X.explain(tx(-4000, text="Zelle payment to ASHA RAO"), [], [], b, None, set())
    assert got[0]["source"] == "balance" and got[0]["confidence"] == 0.85 and got[0]["label"] == "You owed Asha"
    assert X.explain(tx(-2500, text="Zelle payment to ASHA RAO"), [], [], b, None, set())[0]["confidence"] == 0.6
    assert X.explain(tx(-9000, text="Zelle payment to ASHA RAO"), [], [], b, None, set()) == []    # more than I owe isn't it
    assert X.explain(tx(4000, text="Zelle payment from ASHA RAO"), [], [], b, None, set()) == []    # wrong direction

def test_the_tag_moves_the_matching_answer_up():
    exs = [ex("e1", 9000, g="g1"), ex("e2", 9000, g="g2")]
    got = X.explain(tx(-9000), [], exs, [], {"group_id": "g2"}, set())
    assert got[0]["ref"] == "e2" and got[0]["confidence"] == 0.95 and got[1]["confidence"] == 0.54

def test_a_zelle_lists_what_it_could_settle_exactly():
    exs = [ex("a", 6000, on="2026-10-01", mine=False, share=2000, by="Asha Rao", desc="Wi-Fi"), ex("b", 9000, on="2026-10-05", mine=False, share=3000, by="Asha Rao", desc="Dinner"),
           ex("c", 9000, on="2026-09-01", mine=False, share=3000, by="Jo Lee")]
    got = X.could_settle(tx(-5000, text="Zelle payment to ASHA RAO"), exs)
    assert got["exact"] and [i["label"] for i in got["items"]] == ["Dinner", "Wi-Fi"] and got["total_cents"] == 5000
    loose = X.could_settle(tx(-4000, text="Zelle payment to ASHA RAO"), exs)
    assert not loose["exact"] and len(loose["items"]) == 2
    assert X.could_settle(tx(-5000), exs) is None and X.could_settle(tx(5000, text="Zelle payment from ASHA RAO"), exs) is None

# ---------- routes ----------
import pytest
from fastapi.testclient import TestClient

from app.auth import current_user
from app.main import app
from tests.fakerest import FakeRest

U, OTHER = "11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222"
T1, T2, G = "aaaaaaaa-0000-0000-0000-000000000001", "aaaaaaaa-0000-0000-0000-000000000002", "bbbbbbbb-0000-0000-0000-000000000001"

class Rest(FakeRest):
    def rpc(self, fn, args):
        return [] if fn == "tally_balances" else super().rpc(fn, args)

@pytest.fixture
def api(monkeypatch):
    f = Rest()
    monkeypatch.setattr(X, "rest", lambda: f)
    monkeypatch.setattr(X, "user_limiter", type("L", (), {"check": lambda *a, **k: None})())
    f.insert("transactions", [{"id": T1, "user_id": U, "amount_cents": -9000, "occurred_at": "2026-10-10T16:00:00+00:00", "merchant_raw": "Dishoom", "merchant_clean": "Dishoom"},
                              {"id": T2, "user_id": OTHER, "amount_cents": -9000, "occurred_at": "2026-10-10T16:00:00+00:00", "merchant_raw": "Dishoom", "merchant_clean": "Dishoom"}])
    f.insert("tally_groups", {"id": G, "name": "Flat", "deleted_at": None})
    f.insert("tally_members", [{"id": "m1", "group_id": G, "name": "Me", "member_user_id": U, "status": "active"}, {"id": "m2", "group_id": G, "name": "Asha Rao", "member_user_id": None, "status": "active"}])
    f.insert("tally_expenses", [{"id": "e1", "group_id": G, "description": "Dinner", "amount_cents": 9000, "spent_on": "2026-10-10", "paid_by_member": "m1", "transaction_id": None, "deleted_at": None},
                                {"id": "e2", "group_id": G, "description": "Cab", "amount_cents": 9000, "spent_on": "2026-10-12", "paid_by_member": "m1", "transaction_id": None, "deleted_at": None}])
    app.dependency_overrides[current_user] = lambda: U
    yield f, TestClient(app)
    app.dependency_overrides.clear()

def test_explain_tag_and_not_this_one(api):
    f, c = api
    j = c.get(f"/splitwise/explain/{T1}").json()
    assert j["best"]["ref"] == "e1" and j["more"] == 1 and j["gmail_connected"] is False and j["tag"] is None
    assert c.get("/splitwise/options").json() == {"groups": [{"id": G, "name": "Flat"}], "friends": ["Asha Rao"]}
    assert c.post("/splitwise/tag", json={"txn_id": T1, "group_id": G}).status_code == 200
    assert c.post("/splitwise/tag", json={"txn_id": T1, "person": "Asha Rao"}).status_code == 200
    assert [e["person"] for e in f.rows("splitwise_events") if e["kind"] == "tag"] == ["Asha Rao"]       # one tag per row
    assert c.get(f"/splitwise/explain/{T1}").json()["tag"] == "Asha Rao"
    assert c.post("/splitwise/not", json={"txn_id": T1, "ref": "e1"}).status_code == 200
    j = c.get(f"/splitwise/explain/{T1}").json()
    assert j["best"]["ref"] == "e2" and j["more"] == 0

def test_other_peoples_rows_and_groups_are_404(api):
    _, c = api
    assert c.get(f"/splitwise/explain/{T2}").status_code == 404
    assert c.post("/splitwise/tag", json={"txn_id": T2, "person": "Asha"}).status_code == 404
    assert c.post("/splitwise/tag", json={"txn_id": T1, "group_id": "bbbbbbbb-0000-0000-0000-000000000009"}).status_code == 404
    assert c.post("/splitwise/not", json={"txn_id": T1, "ref": "x;drop"}).status_code == 422
