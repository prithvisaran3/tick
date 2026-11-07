"""Payback pairing: what gets suggested, what never does, and the routes. The SQL side (links, the cap, the money rule) is in supabase/tests/money_rules.sql."""
from datetime import datetime, timedelta, timezone

import httpx
import pytest
from fastapi.testclient import TestClient

from app import paybacks as P
from app.auth import current_user
from app.main import app
from tests.fakerest import FakeRest

U = "11111111-1111-1111-1111-111111111111"
CHK, CARD = "acct-chk", "acct-card"
TYPES = {CHK: "checking", CARD: "credit"}
NOW = datetime(2026, 11, 5, 16, 0, tzinfo=timezone.utc)

def uid(n: int) -> str:
    return f"00000000-0000-4000-8000-{n:012d}"

def row(n, cents, days_ago, text, acct=CHK, flow=None, reimbursed=0):
    return {"id": uid(n), "account_id": acct, "amount_cents": cents, "occurred_at": (NOW - timedelta(days=days_ago)).isoformat(), "merchant_raw": text, "merchant_clean": text, "flow": flow, "reimbursed_cents": reimbursed}

def test_suggests_a_payback_inside_the_window():
    s = P.suggest([row(1, -8000, 10, "Dishoom", CARD), row(2, 4000, 2, "Zelle payment from ASHA RAO 3140")], TYPES, set())
    assert len(s) == 1 and s[0]["payback_id"] == uid(2) and s[0]["from"] == "Asha Rao"
    assert s[0]["candidates"][0]["purchase_id"] == uid(1) and s[0]["candidates"][0]["merchant"] == "Dishoom"

@pytest.mark.parametrize("gap,hit", [(0, True), (21, True), (22, False), (-1, False)])
def test_window_is_21_days_after_the_purchase(gap, hit):
    s = P.suggest([row(1, -8000, 5 + gap, "Dishoom", CARD), row(2, 4000, 5, "Venmo from Asha")], TYPES, set())
    assert bool(s) is hit

def test_a_credit_bigger_than_the_purchase_is_not_suggested():
    assert P.suggest([row(1, -3000, 5, "Dishoom", CARD), row(2, 3001, 1, "Venmo from Asha")], TYPES, set()) == []

def test_equal_to_the_purchase_is_allowed():
    assert P.suggest([row(1, -3000, 5, "Dishoom", CARD), row(2, 3000, 1, "Cash App from Asha")], TYPES, set())

def test_what_is_left_counts_after_earlier_paybacks():
    rows = [row(1, -9000, 5, "Dishoom", CARD, reimbursed=6000), row(2, 3001, 1, "Venmo from Jo"), row(3, 3000, 1, "PayPal from Sam")]
    s = P.suggest(rows, TYPES, set())
    assert [x["payback_id"] for x in s] == [uid(3)] and s[0]["candidates"][0]["left_cents"] == 3000

def test_an_even_share_beats_a_closer_date():
    rows = [row(1, -5000, 2, "Closer", CARD), row(2, -9000, 15, "Dinner for three", CARD), row(3, 3000, 1, "Zelle from Asha")]
    assert [c["purchase_id"] for c in P.suggest(rows, TYPES, set())[0]["candidates"]] == [uid(2), uid(1)]

def test_candidates_are_capped():
    rows = [row(i, -5000, i, f"Shop {i}", CARD) for i in range(1, 8)] + [row(50, 1000, 0, "Zelle from Asha")]
    assert len(P.suggest(rows, TYPES, set())[0]["candidates"]) == P.MAX_CANDIDATES

@pytest.mark.parametrize("credit", [row(2, 4000, 1, "VENMO CASHOUT"), row(2, 4000, 1, "Payroll"), row(2, 4000, 1, "Zelle from Me", flow="transfer"), row(2, 4000, 1, "Zelle from Asha", CARD)])
def test_only_money_from_a_person_into_cash_counts(credit):
    assert P.suggest([row(1, -8000, 5, "Dishoom", CARD), credit], TYPES, set()) == []

@pytest.mark.parametrize("purchase", [row(1, -8000, 5, "Zelle payment to Jo"), row(1, -8000, 5, "Card payment", flow="transfer")])
def test_transfers_and_p2p_are_not_purchases(purchase):
    assert P.suggest([purchase, row(2, 4000, 1, "Zelle from Asha")], TYPES, set()) == []

def test_not_a_payback_is_never_asked_again():
    assert P.suggest([row(1, -8000, 5, "Dishoom", CARD), row(2, 4000, 1, "Zelle from Asha")], TYPES, {uid(2)}) == []

class PaybackRest(FakeRest):
    def rpc(self, fn, args):
        assert fn == "tick_payback_link"
        if args["p_payback"] == uid(9):
            req = httpx.Request("POST", "http://fake")
            raise httpx.HTTPStatusError("400", request=req, response=httpx.Response(400, request=req, text='{"message":"more than the purchase"}'))
        self.insert("txn_paybacks", {"user_id": args["p_uid"], "purchase_id": args["p_purchase"], "payback_id": args["p_payback"]})
        return {"purchase_id": args["p_purchase"]}

@pytest.fixture
def api(monkeypatch):
    f = PaybackRest()
    monkeypatch.setattr(P, "rest", lambda: f)
    monkeypatch.setattr(P, "user_limiter", type("L", (), {"check": lambda *a, **k: None})())
    now = datetime.now(timezone.utc)
    f.insert("accounts", [{"id": CHK, "user_id": U, "type": "checking"}, {"id": CARD, "user_id": U, "type": "credit"}])
    for n, c, d, t, a in [(1, -8000, 6, "Dishoom", CARD), (2, 4000, 2, "Zelle payment from ASHA RAO", CHK)]:
        f.insert("transactions", {**row(n, c, 0, t, a), "occurred_at": (now - timedelta(days=d)).isoformat(), "user_id": U})
    app.dependency_overrides[current_user] = lambda: U
    yield f, TestClient(app)
    app.dependency_overrides.clear()

def test_routes_suggest_link_unlink_dismiss(api):
    f, c = api
    assert len(c.get("/paybacks/suggestions").json()["suggestions"]) == 1
    assert c.post("/paybacks/link", json={"purchase_id": uid(1), "payback_id": uid(2)}).status_code == 200
    assert c.get("/paybacks/suggestions").json()["suggestions"] == []
    assert c.post("/paybacks/unlink", json={"payback_id": uid(2)}).json() == {"unlinked": True}
    assert len(c.get("/paybacks/suggestions").json()["suggestions"]) == 1
    assert c.post("/paybacks/dismiss", json={"payback_id": uid(2)}).status_code == 200
    assert c.get("/paybacks/suggestions").json()["suggestions"] == []

def test_over_the_purchase_is_a_clear_conflict(api):
    _, c = api
    r = c.post("/paybacks/link", json={"purchase_id": uid(1), "payback_id": uid(9)})
    assert r.status_code == 409 and "more than" in r.json()["detail"]

def test_bad_ids_and_other_peoples_rows_are_404(api):
    f, c = api
    assert c.post("/paybacks/link", json={"purchase_id": "x", "payback_id": uid(2)}).status_code == 404
    assert c.post("/paybacks/dismiss", json={"payback_id": uid(77)}).status_code == 404

def settle(f, cents, on, person="p1", status="confirmed", **kw):
    return f.insert("tally_settlements", {"user_id": U, "group_id": "g", "from_member": person, "to_member": "mine", "amount_cents": cents, "status": status, "transaction_id": None, "deleted_at": None, "settled_on": on, **kw})[0]

def members(f, *names):
    f.insert("tally_members", {"id": "mine", "group_id": "g", "member_user_id": U, "name": "Me", "status": "active"})
    for i, n in enumerate(names, 1):
        f.insert("tally_members", {"id": f"p{i}", "group_id": "g", "name": n, "status": "active"})

def test_auto_link_only_on_an_exact_settlement(api):
    f, _ = api
    members(f, "Asha Rao")
    today = datetime.now(timezone.utc).date().isoformat()
    exact, other = settle(f, 4000, today), settle(f, 3999, today)
    assert P.auto_link(U) == 1
    rows = {s["id"]: s for s in f.rows("tally_settlements")}
    assert rows[exact["id"]]["transaction_id"] == uid(2) and rows[other["id"]]["transaction_id"] is None

def test_auto_link_needs_the_friends_name_and_one_candidate(api):
    f, _ = api
    members(f, "Asha Rao", "Jo Lee")
    today = datetime.now(timezone.utc).date().isoformat()
    settle(f, 4000, today, person="p2")
    assert P.auto_link(U) == 0
    f.insert("transactions", {**row(3, 4000, 2, "Zelle payment from ASHA R"), "user_id": U, "occurred_at": datetime.now(timezone.utc).isoformat()})
    settle(f, 4000, today, person="p1")
    assert P.auto_link(U) == 0                # two credits fit: a person decides

def test_a_pending_i_paid_that_landed_is_offered_as_received(api):
    f, c = api
    members(f, "Asha Rao")
    s = settle(f, 4000, "2026-11-01", status="pending")
    settle(f, 1234, "2026-11-01", status="pending")
    got = c.get("/paybacks/suggestions").json()["settlements"]
    assert [x["settlement_id"] for x in got] == [s["id"]] and got[0]["from"] == "Asha Rao"
    assert c.post("/paybacks/received", json={"settlement_id": s["id"], "payback_id": uid(2)}).status_code == 200
    row = next(x for x in f.rows("tally_settlements") if x["id"] == s["id"])
    assert (row["status"], row["transaction_id"]) == ("confirmed", uid(2))
