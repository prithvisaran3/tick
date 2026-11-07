"""Splitwise group export -> a Tally group. The fixture's shape is assumed (docs/TALLY_V2.md); imports/splitwise/ had no real sample."""
import pathlib

import pytest
from fastapi.testclient import TestClient

from app import audit as audit_mod, imports as I, splitwise as SW
from app.auth import current_user
from app.main import app
from tests.fakerest import FakeRest

RAW = (pathlib.Path(__file__).parent / "data" / "splitwise_roommates.csv").read_bytes()
U = "11111111-1111-1111-1111-111111111111"
ME = "Prithvi Saran"

def test_recognised_and_other_statements_are_not():
    assert SW.looks_like(RAW)
    assert not SW.looks_like(b"Date,Description,Amount\n2026-01-01,x,1\n")

def test_parses_members_rows_and_skips_the_total():
    ex = SW.parse(RAW)
    assert ex.members == [ME, "Asha Rao", "Kaarthik Kumar"]
    assert len(ex.items) == 5 + 1 and ex.unreadable == 2
    assert all(sum(i.nets.values()) == 0 for i in ex.items)

def test_two_identical_rows_stay_two():
    refs = [i.ref for i in SW.parse(RAW).items]
    assert len(set(refs)) == len(refs)

def test_refs_are_stable_across_parses():
    assert [i.ref for i in SW.parse(RAW).items] == [i.ref for i in SW.parse(RAW).items]

def test_single_payer_keeps_the_cost_and_their_own_share():
    it = next(i for i in SW.parse(RAW).items if i.description == "Groceries")
    e = SW.expenses_of(it)
    assert e == [{"payer": ME, "amount_cents": 9000, "shares": {"Asha Rao": 3000, "Kaarthik Kumar": 3000, ME: 3000}}]

def test_multi_payer_becomes_one_expense_per_payer_and_balances_stay_exact():
    it = next(i for i in SW.parse(RAW).items if i.description == "Trip fuel")
    es = SW.expenses_of(it)
    assert sorted((e["payer"], e["amount_cents"]) for e in es) == [("Asha Rao", 2000), (ME, 3000)]
    net = {}
    for e in es:
        net[e["payer"]] = net.get(e["payer"], 0) + e["amount_cents"]
        for m, c in e["shares"].items():
            net[m] = net.get(m, 0) - c
    assert {k: v for k, v in net.items() if v} == it.nets

def test_payment_row_is_a_settlement_from_the_payer():
    it = next(i for i in SW.parse(RAW).items if i.payment)
    assert SW.settlements_of(it) == [{"from": "Asha Rao", "to": ME, "amount_cents": 3000}]

def test_payload_uses_null_for_me():
    p = SW.payload(SW.parse(RAW), ME, "Roommates", set())
    assert p["people"] == ["Asha Rao", "Kaarthik Kumar"]
    assert p["expenses"][0]["paid_by"] is None and {"person": None, "owed_cents": 3000} in p["expenses"][0]["shares"]
    assert p["settlements"][0]["to"] is None and p["settlements"][0]["from"] == "Asha Rao"

def test_balances_equal_the_files_total_row():
    b = SW.parse(RAW).balances
    assert b == {ME: 7666, "Asha Rao": 7667, "Kaarthik Kumar": -15333}

def test_guess_me():
    assert SW.guess_me(["Prithvi Saran", "Asha Rao"], "Prithvi Saran Sathyasaran") == "Prithvi Saran"
    assert SW.guess_me(["Sam A", "Sam B"], "Sam") is None

class Rest(FakeRest):
    def rpc(self, fn, args):
        assert fn == "tally_import_splitwise"
        for e in args["p"]["expenses"]:
            self.insert("tally_expenses", {"user_id": args["p_uid"], "external_ref": e["ref"], "import_batch_id": args["p_batch"]})
        for s in args["p"]["settlements"]:
            self.insert("tally_settlements", {"user_id": args["p_uid"], "external_ref": s["ref"], "import_batch_id": args["p_batch"]})
        return {"group_id": "g1"}

@pytest.fixture
def api(monkeypatch):
    f = Rest()
    for m in (I, audit_mod):
        monkeypatch.setattr(m, "rest", lambda: f)
    f.insert("profiles", {"user_id": U, "display_name": "Prithvi Saran Sathyasaran"})
    app.dependency_overrides[current_user] = lambda: U
    yield f, TestClient(app)
    app.dependency_overrides.clear()

def post(c, **form):
    return c.post("/import/statement", files={"file": ("Roommates_2026.csv", RAW, "text/csv")}, data=form)

def test_preview_writes_nothing(api):
    f, c = api
    j = post(c).json()
    assert j["source"] == "splitwise" and j["new"] == 6 and j["me_guess"] == ME and j["group_name"] == "Roommates 2026"
    assert f.rows("import_batches") == []

def test_commit_needs_to_know_who_i_am(api):
    _, c = api
    assert post(c, mode="commit").status_code == 422

def test_commit_then_reimport_adds_nothing(api):
    f, c = api
    assert post(c, mode="commit", me_member=ME).json()["imported"] == 6
    n = len(f.rows("tally_expenses"))
    j = post(c, mode="commit", me_member=ME).json()
    assert j["imported"] == 0 and j["already_imported"] == 6 and len(f.rows("tally_expenses")) == n and len(f.rows("import_batches")) == 1

def test_undo_removes_the_batch(api):
    f, c = api
    b = post(c, mode="commit", me_member=ME).json()["batch_id"]
    assert c.post(f"/import/{b}/undo").json()["removed"] > 0
    assert f.rows("tally_expenses") == [] and f.rows("tally_settlements") == []
