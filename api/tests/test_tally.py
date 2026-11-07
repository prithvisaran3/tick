"""Tally share links and the public page (Part 6): creation, hashing, expiry, revocation, rate limits, escaping, and "I paid"."""
import json
import pathlib
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from app import audit as audit_mod, tally as T
from app.auth import current_user, hash_token
from app.main import app
from tests.fakerest import FakeRest

U = "11111111-1111-1111-1111-111111111111"
OTHER = "22222222-2222-2222-2222-222222222222"
VECTORS = json.loads((pathlib.Path(__file__).parent / "data" / "tally_simplify.json").read_text())

class TallyRest(FakeRest):
    """FakeRest plus the one SQL function the page reads (tally_balances), computed from the fake tables the same way the SQL does."""
    def rpc(self, fn, args):
        if fn != "tally_balances":
            return super().rpc(fn, args)
        gid = args.get("p_group")
        net: dict = {}
        def add(p, c): net[p] = net.get(p, 0) + c
        for e in self.rows("tally_expenses"):
            if not e.get("deleted_at") and (gid is None or e["group_id"] == gid):
                add(e.get("paid_by_member"), e["amount_cents"])
                for s in self.rows("tally_shares"):
                    if s["expense_id"] == e["id"]:
                        add(s.get("member_id"), -s["owed_cents"])
        for st in self.rows("tally_settlements"):
            if not st.get("deleted_at") and st["status"] == "confirmed" and (gid is None or st["group_id"] == gid):
                add(st.get("from_member"), st["amount_cents"]); add(st.get("to_member"), -st["amount_cents"])
        return [{"group_id": gid, "member_id": p, "net_cents": c} for p, c in net.items() if c]

@pytest.fixture
def world(monkeypatch):
    monkeypatch.setenv("PUBLIC_BASE_URL", "https://tick.example")
    from app import config
    config.settings.cache_clear() if hasattr(config.settings, "cache_clear") else None
    f = TallyRest()
    for mod in (T, audit_mod):
        monkeypatch.setattr(mod, "rest", lambda: f)
    f.insert("profiles", {"user_id": U, "display_name": "Prithvi Saran Sathyasaran"})
    g = f.insert("tally_groups", {"user_id": U, "name": "Roommates <b>", "emoji": "🏠", "deleted_at": None})[0]
    me = f.insert("tally_members", {"group_id": g["id"], "user_id": U, "member_user_id": U, "name": "Prithvi Saran Sathyasaran", "role": "owner", "status": "active"})[0]
    k = f.insert("tally_members", {"group_id": g["id"], "user_id": U, "name": "Kaarthik Kumar", "role": "member", "status": "active"})[0]
    j = f.insert("tally_members", {"group_id": g["id"], "user_id": U, "name": "<script>alert(1)</script> Jo", "role": "member", "status": "active"})[0]
    e = f.insert("tally_expenses", {"user_id": U, "group_id": g["id"], "description": "Groceries", "amount_cents": 9000, "paid_by_member": me["id"]})[0]
    for m in (me, k, j):
        f.insert("tally_shares", {"expense_id": e["id"], "member_id": m["id"], "user_id": U, "owed_cents": 3000})
    return f, g, k, j

def mk_link(c, gid, days=30):
    r = c.post(f"/tally/groups/{gid}/links", json={"days": days})
    assert r.status_code == 200, r.text
    return r.json()

@pytest.fixture
def signed_in(world):
    from app.auth import user_limiter, ingest_limiter
    from app.security import ip_guard
    def reset():
        for lim in (T.view_limiter, T.paid_limiter, user_limiter, ingest_limiter):
            lim.hits.clear()
        ip_guard.hits.clear(); ip_guard.bad.clear(); ip_guard.blocked.clear()
    reset()
    app.dependency_overrides[current_user] = lambda: U
    yield TestClient(app)
    app.dependency_overrides.clear()
    reset()

def token_of(url): return url.rsplit("/", 1)[1]

@pytest.mark.parametrize("v", VECTORS, ids=[v["name"] for v in VECTORS])
def test_simplify_matches_the_shared_vectors(v):
    net = {None if k == "me" else k: c for k, c in v["net"].items()}
    got = [("me" if a is None else a, "me" if b is None else b, c) for a, b, c in T.simplify(net)]
    assert got == [tuple(x) for x in v["transfers"]]
    for p in net:                                                                  # applying the transfers settles everyone
        moved = sum(c for a, b, c in T.simplify(net) if b == p) - sum(c for a, b, c in T.simplify(net) if a == p)
        assert moved == net[p]

def test_link_is_minted_once_hashed_expiring_and_audited(world, signed_in):
    f, g, k, j = world
    r = mk_link(signed_in, g["id"], days=7)
    tok = token_of(r["url"])
    assert len(tok) == 43 and "/t/" in r["url"]
    row = f.rows("tally_links")[0]
    assert row["token_hash"] == hash_token(tok) and tok not in json.dumps(f.t)
    exp = datetime.fromisoformat(row["expires_at"]); assert timedelta(days=6) < exp - datetime.now(timezone.utc) < timedelta(days=7, hours=1)
    assert "tally_share" in {e["event"] for e in f.rows("audit_log")}
    assert tok not in json.dumps(signed_in.get(f"/tally/groups/{g['id']}/links").json())
    assert signed_in.post(f"/tally/groups/{g['id']}/links", json={"days": 400}).status_code == 422
    assert signed_in.post(f"/tally/groups/{g['id']}/links", json={"days": 5, "x": 1}).status_code == 422

def test_only_five_live_links_per_group_and_only_my_groups(world, signed_in):
    f, g, k, j = world
    for _ in range(5): mk_link(signed_in, g["id"])
    assert signed_in.post(f"/tally/groups/{g['id']}/links", json={}).status_code == 409
    other = f.insert("tally_groups", {"user_id": OTHER, "name": "Theirs", "deleted_at": None})[0]
    assert signed_in.post(f"/tally/groups/{other['id']}/links", json={}).status_code == 404
    assert signed_in.post("/tally/groups/not-a-uuid/links", json={}).status_code == 404

def test_public_page_shows_first_names_and_amounts_only_and_escapes_everything(world, signed_in):
    f, g, k, j = world
    tok = token_of(mk_link(signed_in, g["id"])["url"])
    pub = TestClient(app)
    r = pub.get(f"/t/{tok}")
    assert r.status_code == 200
    body = r.text
    assert "Kaarthik" in body and "$30.00" in body and "Prithvi" in body
    assert "Sathyasaran" not in body and "Kumar" not in body                        # first names only
    assert "<script>alert" not in body and "&lt;script&gt;" in body and "&lt;b&gt;" in body        # names are escaped, never executed
    assert k["id"] in body                                                           # the form needs the person id...
    assert "9000" not in body and "Groceries" not in body                            # ...but no expense detail, totals or ids beyond that
    assert r.headers["x-robots-tag"].startswith("noindex") and "noindex" in body and r.headers["cache-control"] == "no-store"
    assert "default-src 'none'" in r.headers["content-security-policy"] and "frame-ancestors 'none'" in r.headers["content-security-policy"]
    assert f.rows("tally_links")[0]["views"] == 1

def test_unknown_expired_revoked_and_malformed_links_are_the_same_calm_404(world, signed_in):
    f, g, k, j = world
    ok = mk_link(signed_in, g["id"]); tok = token_of(ok["url"])
    pub = TestClient(app)
    gone = pub.get("/t/" + "A" * 43)
    assert gone.status_code == 404 and "isn't working" in gone.text
    assert pub.get("/t/short").text == gone.text and pub.get("/t/" + "!" * 43).status_code == 404
    f.rows("tally_links")[0]["expires_at"] = (datetime.now(timezone.utc) - timedelta(minutes=1)).isoformat()
    assert pub.get(f"/t/{tok}").text == gone.text
    f.rows("tally_links")[0]["expires_at"] = (datetime.now(timezone.utc) + timedelta(days=1)).isoformat()
    assert pub.get(f"/t/{tok}").status_code == 200
    assert signed_in.post(f"/tally/links/{ok['id']}/revoke").json() == {"revoked": True}
    assert pub.get(f"/t/{tok}").text == gone.text
    assert signed_in.post(f"/tally/links/{'0' * 8}-0000-0000-0000-{'0' * 12}/revoke").status_code == 404

def test_page_views_are_rate_limited(world, signed_in):
    f, g, k, j = world
    tok = token_of(mk_link(signed_in, g["id"])["url"])
    pub = TestClient(app)
    codes = [pub.get(f"/t/{tok}").status_code for _ in range(45)]
    assert codes.count(429) >= 3 and codes[0] == 200

def test_i_paid_creates_a_pending_settlement_and_never_changes_a_balance(world, signed_in):
    f, g, k, j = world
    tok = token_of(mk_link(signed_in, g["id"])["url"])
    pub = TestClient(app)
    before = {r["member_id"]: r["net_cents"] for r in f.rpc("tally_balances", {"p_uid": U, "p_group": g["id"]})}
    r = pub.post(f"/t/{tok}/paid", data={"person": k["id"], "amount": "3000"})
    assert r.status_code == 200 and "Thanks" in r.text and "Nothing was paid from here" in r.text
    st = f.rows("tally_settlements")[0]
    assert (st["status"], st["from_member"], st["amount_cents"]) == ("pending", k["id"], 3000) and st["to_member"] == next(m["id"] for m in f.rows("tally_members") if m["role"] == "owner")
    assert {r["member_id"]: r["net_cents"] for r in f.rpc("tally_balances", {"p_uid": U, "p_group": g["id"]})} == before        # pending is not money

def test_i_paid_is_validated_and_capped(world, signed_in):
    f, g, k, j = world
    tok = token_of(mk_link(signed_in, g["id"])["url"])
    pub = TestClient(app)
    assert pub.post(f"/t/{tok}/paid", data={"person": k["id"], "amount": "3001"}).status_code == 409           # more than they owe
    assert pub.post(f"/t/{tok}/paid", data={"person": "someone-else", "amount": "100"}).status_code == 409      # not a member
    assert pub.post(f"/t/{tok}/paid", data={"person": k["id"], "amount": "-5"}).status_code == 422
    assert pub.post(f"/t/{tok}/paid", data={"person": k["id"]}).status_code == 422
    assert pub.post("/t/" + "A" * 43 + "/paid", data={"person": k["id"], "amount": "100"}).status_code == 404
    for _ in range(3):
        assert pub.post(f"/t/{tok}/paid", data={"person": k["id"], "amount": "100"}).status_code == 200
    assert pub.post(f"/t/{tok}/paid", data={"person": k["id"], "amount": "100"}).status_code == 429               # no flooding the owner's inbox
    assert len(f.rows("tally_settlements")) == 3

def test_all_square_shows_the_checkmark(world, signed_in):
    f, g, k, j = world
    f.rows("tally_expenses")[0]["deleted_at"] = "2026-11-01T00:00:00+00:00"
    tok = token_of(mk_link(signed_in, g["id"])["url"])
    assert "All square" in TestClient(app).get(f"/t/{tok}").text

def test_authenticated_tally_routes_require_sign_in():
    app.dependency_overrides.clear()
    c = TestClient(app)
    assert c.post("/tally/groups/x/links", json={}).status_code == 401
    assert c.get("/tally/groups/x/links").status_code == 401
    assert c.post("/tally/links/x/revoke").status_code == 401
