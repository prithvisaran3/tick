"""Finding people: the route shape, rate limits and handle rules. What search can and can't match is in supabase/tests/tally_shared.sql."""
import pytest
from fastapi.testclient import TestClient

from app import people as P
from app.auth import current_user, user_limiter
from app.main import app
from tests.fakerest import FakeRest

U = "11111111-1111-1111-1111-111111111111"
V = "22222222-2222-2222-2222-222222222222"

class Rest(FakeRest):
    def rpc(self, fn, args):
        assert fn == "tally_search_people" and args["p_caller"] == U
        return [{"user_id": V, "display_name": "Asha", "handle": f"asha{i}", "avatar_url": None, "email": "leak@x.y", "phone": "+1555"} for i in range(9)]

@pytest.fixture
def api(monkeypatch):
    f = Rest()
    monkeypatch.setattr(P, "rest", lambda: f)
    user_limiter.hits.clear()
    f.insert("profiles", [{"user_id": U, "display_name": "Prithvi Saran", "handle": None, "discoverable": True}, {"user_id": V, "display_name": "Asha", "handle": "asha", "discoverable": True}])
    app.dependency_overrides[current_user] = lambda: U
    yield f, TestClient(app)
    app.dependency_overrides.clear()
    user_limiter.hits.clear()

def test_search_caps_at_five_and_leaks_nothing_else(api):
    _, c = api
    people = c.get("/people/search", params={"q": "asha"}).json()["people"]
    assert len(people) == 5 and set(people[0]) == {"user_id", "display_name", "handle", "avatar_url"}

def test_search_is_rate_limited(api):
    _, c = api
    for _ in range(20):
        assert c.get("/people/search", params={"q": "asha"}).status_code == 200
    assert c.get("/people/search", params={"q": "asha"}).status_code == 429

def test_search_needs_a_query_and_a_session(api):
    _, c = api
    assert c.get("/people/search", params={"q": ""}).status_code == 422
    app.dependency_overrides.clear()
    assert c.get("/people/search", params={"q": "asha"}).status_code == 401

def test_suggestion_from_the_name_skips_what_is_taken(api):
    f, c = api
    assert c.get("/people/handle").json()["suggestion"] == "prithvi_saran"
    f.rows("profiles")[1]["handle"] = "prithvi_saran"
    assert c.get("/people/handle").json()["suggestion"] == "prithvi_saran2"

@pytest.mark.parametrize("h,code", [("@New_One", 200), ("ab", 422), ("has space", 422), ("asha", 409), ("admin", 409)])
def test_handle_rules(api, h, code):
    f, c = api
    assert c.post("/people/handle", json={"handle": h}).status_code == code
    if code == 200:
        assert f.rows("profiles")[0]["handle"] == "new_one"

def test_handle_check_as_you_type(api):
    f, c = api
    assert c.get("/people/handle/check", params={"h": "asha"}).json() == {"available": False}
    assert c.get("/people/handle/check", params={"h": "@Free_One"}).json() == {"available": True}
    assert c.get("/people/handle/check", params={"h": "ab"}).json() == {"available": False}
    assert c.get("/people/handle/check", params={"h": "admin"}).json() == {"available": False}
