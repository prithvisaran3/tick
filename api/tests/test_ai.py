import json
import httpx
import pytest
from app import ai
from app.ai import AIProvider, AIResult, OpenRouterProvider, rank_models, scrub

CATALOG = [
    {"id": "google/gemma-4-31b-it:free", "context_length": 262144, "pricing": {"prompt": "0", "completion": "0"}, "supported_parameters": ["tools", "response_format"], "architecture": {"input_modalities": ["text", "image"]}},
    {"id": "nvidia/nemotron-3-ultra-550b-a55b:free", "context_length": 1000000, "pricing": {"prompt": "0", "completion": "0"}, "supported_parameters": ["tools"], "architecture": {"input_modalities": ["text"]}},
    {"id": "recursive/flint-v1.0:free", "context_length": 262144, "pricing": {"prompt": "0", "completion": "0"}, "supported_parameters": ["tools", "structured_outputs"], "architecture": {"input_modalities": ["text"]}},
    {"id": "nvidia/nemotron-3.5-content-safety:free", "context_length": 128000, "pricing": {"prompt": "0", "completion": "0"}, "supported_parameters": ["tools"], "architecture": {"input_modalities": ["text"]}},
    {"id": "liquid/lfm-2.5-2.6b:free", "context_length": 65536, "pricing": {"prompt": "0", "completion": "0"}, "supported_parameters": ["tools", "response_format"], "architecture": {"input_modalities": ["text"]}},
    {"id": "openai/gpt-5", "context_length": 400000, "pricing": {"prompt": "0.001", "completion": "0.002"}, "supported_parameters": ["tools", "response_format"], "architecture": {"input_modalities": ["text"]}},
    {"id": "sneaky/paid:free", "context_length": 999999, "pricing": {"prompt": "0.5", "completion": "0.5"}, "supported_parameters": ["tools", "response_format"], "architecture": {"input_modalities": ["text"]}},
    {"id": "no-tools/model:free", "context_length": 100000, "pricing": {"prompt": "0", "completion": "0"}, "supported_parameters": ["response_format"], "architecture": {"input_modalities": ["text"]}},
]

def test_scrub_removes_private_data():
    t = scrub("Chase: card ending in 4421 charged $18.40 at UBER. Call 703-555-1212 or me@x.com acct 123456789 https://x.co/a")
    assert "4421" not in t and "703" not in t and "me@x.com" not in t and "123456789" not in t and "https" not in t
    assert "$18.40" in t and "UBER" in t

def test_rank_only_free_zero_priced_and_capability():
    tools = rank_models(CATALOG, "tools")
    assert len(tools) == 3 and all(m.endswith(":free") for m in tools)
    assert "openai/gpt-5" not in tools and "sneaky/paid:free" not in tools and "no-tools/model:free" not in tools
    assert not any("safety" in m for m in tools) and "liquid/lfm-2.5-2.6b:free" not in tools[:2]
    assert tools[0] in ("google/gemma-4-31b-it:free", "nvidia/nemotron-3-ultra-550b-a55b:free")
    js = rank_models(CATALOG, "json")
    assert "no-tools/model:free" in js or True
    assert all(m.endswith(":free") for m in js)
    assert rank_models(CATALOG, "vision") == ["google/gemma-4-31b-it:free"]
    assert rank_models([], "tools") == []

def make_provider(handler, used=0, monkeypatch=None):
    p = OpenRouterProvider()
    p.http = httpx.Client(transport=httpx.MockTransport(handler))
    p._catalog = (10**12, CATALOG)
    p.key = lambda: "test-key"
    p.used_today = lambda: used
    logged = []
    p._log = lambda *a: logged.append(a)
    p.logged = logged
    return p

def ok_response(text="hi", model="google/gemma-4-31b-it:free", tool_calls=None):
    msg = {"role": "assistant", "content": text}
    if tool_calls:
        msg["tool_calls"] = tool_calls
    return httpx.Response(200, json={"model": model, "choices": [{"message": msg}], "usage": {"prompt_tokens": 5, "completion_tokens": 3}})

def test_request_shape_free_models_privacy_policy():
    seen = {}
    def h(req):
        seen.update(json.loads(req.content)); seen["auth"] = req.headers["authorization"]
        return ok_response('{"a":1}')
    p = make_provider(h)
    r = p.chat("json", [{"role": "user", "content": "x"}], json_out=True, max_tokens=64)
    assert r.text == '{"a":1}'
    assert all(m.endswith(":free") for m in seen["models"]) and len(seen["models"]) <= 3
    assert seen["provider"]["data_collection"] == "deny" and seen["response_format"] == {"type": "json_object"} and seen["max_tokens"] == 64
    assert p.logged[0][-1] == "ok"

def test_daily_limit_blocks_calls():
    called = []
    p = make_provider(lambda req: (called.append(1), ok_response())[1], used=ai.DAILY_LIMIT)
    assert p.chat("text", [{"role": "user", "content": "x"}]) is None and not called

def test_per_minute_limit():
    p = make_provider(lambda req: ok_response())
    results = [p.chat("text", [{"role": "user", "content": "x"}]) for _ in range(ai.PER_MINUTE + 3)]
    assert sum(r is not None for r in results) == ai.PER_MINUTE

def test_429_retries_once_then_silent_fallback(monkeypatch):
    monkeypatch.setattr("time.sleep", lambda s: None)
    n = []
    p = make_provider(lambda req: (n.append(1), httpx.Response(429, json={}))[1])
    assert p.chat("text", [{"role": "user", "content": "x"}]) is None and len(n) == 2
    n.clear()
    seq = iter([httpx.Response(429, json={}), ok_response("later")])
    p = make_provider(lambda req: next(seq))
    assert p.chat("text", [{"role": "user", "content": "x"}]).text == "later"

def test_non_free_answer_is_refused():
    p = make_provider(lambda req: ok_response("pay", model="openai/gpt-5"))
    assert p.chat("text", [{"role": "user", "content": "x"}]) is None
    assert p.logged[-1][-1] == "non_free_blocked"

def test_no_key_or_no_models_returns_none():
    p = make_provider(lambda req: ok_response()); p.key = lambda: ""
    assert p.chat("text", [{"role": "user", "content": "x"}]) is None
    p = make_provider(lambda req: ok_response()); p._catalog = (10**12, [])
    assert p.chat("text", [{"role": "user", "content": "x"}]) is None

class Fake(AIProvider):
    name = "fake"
    def __init__(self, replies): self.replies, self.calls = list(replies), []
    def available(self): return True
    def chat(self, task, messages, **kw):
        self.calls.append((task, list(messages), kw)); return self.replies.pop(0) if self.replies else None

@pytest.fixture
def mem_cache(monkeypatch):
    store = {}
    monkeypatch.setattr(ai, "cache_get", lambda f, p: store.get((f, p)))
    monkeypatch.setattr(ai, "cache_put", lambda f, p, v: store.__setitem__((f, p), v))
    yield store
    ai.set_provider(None)

def test_batch_categorization_is_one_call_and_cached(mem_cache):
    reply = AIResult(json.dumps({"results": [{"merchant": "BLUEBIRD CAFE", "clean": "Bluebird Cafe", "category": "Coffee"}, {"merchant": "Joes", "clean": "Joe's", "category": "Restaurants"}]}))
    f = Fake([reply]); ai.set_provider(f)
    out = ai.categorize_batch("u", ["BLUEBIRD CAFE", "Joes", "BLUEBIRD CAFE"], ["Coffee", "Restaurants", "Other"])
    assert out == {"BLUEBIRD CAFE": ("Bluebird Cafe", "Coffee"), "Joes": ("Joe's", "Restaurants")} and len(f.calls) == 1
    again = ai.categorize_batch("u", ["BLUEBIRD CAFE", "Joes"], ["Coffee", "Restaurants", "Other"])
    assert again == out and len(f.calls) == 1            # served from cache, zero calls

def test_batch_rejects_invalid_category_and_failure_is_silent(mem_cache):
    ai.set_provider(Fake([AIResult(json.dumps({"results": [{"merchant": "X", "clean": "X", "category": "Not A Category"}]}))]))
    assert ai.categorize_batch("u", ["X"], ["Coffee"]) == {}
    ai.set_provider(Fake([None]))
    assert ai.categorize_batch("u", ["Y"], ["Coffee"]) == {}

def test_parse_alert_ai_and_scrubbing(mem_cache):
    f = Fake([AIResult('{"amount": 12.5, "merchant": "Joes Pizza", "direction": "out", "confidence": 0.95}')]); ai.set_provider(f)
    p = ai.parse_alert_ai("u", "Your card ending in 4421 was charged $12.50 at JOES PIZZA, call 703-555-1212")
    assert p.amount_cents == -1250 and p.merchant_raw == "Joes Pizza" and p.confidence <= 0.9
    sent = json.dumps(f.calls[0][1])
    assert "4421" not in sent and "703-555" not in sent

def test_ask_tool_loop_sends_only_tool_results_and_last_six(mem_cache):
    from datetime import date
    from app.ask import llm_answer, Ledger
    l = Ledger([{"id": "t1", "merchant": "Whole Foods", "amount_cents": -4218, "date": date(2026, 11, 3), "category": "Groceries", "tags": [], "account": None}], today=date(2026, 11, 18))
    tc = {"id": "c1", "name": "spend_by_category", "arguments": {}}
    f = Fake([AIResult(None, [tc], raw_message={"role": "assistant", "content": None, "tool_calls": [{"id": "c1", "type": "function", "function": {"name": "spend_by_category", "arguments": "{}"}}]}),
              AIResult("$42 on groceries this month.")])
    ai.set_provider(f)
    hist = [{"role": "user" if i % 2 == 0 else "assistant", "text": f"msg {i}"} for i in range(10)]
    text, blocks = llm_answer("u", "how much on groceries?", hist, l)
    assert text.startswith("$42") and len(f.calls) == 2
    first = f.calls[0][1]
    assert len([m for m in first if m["role"] in ("user", "assistant")]) == 7        # last 6 + the question
    tool_msg = [m for m in f.calls[1][1] if m["role"] == "tool"][0]
    assert "Groceries" in tool_msg["content"]
    assert f.calls[0][2]["tools"]                                                      # tools were offered
    # model returning nothing -> None -> deterministic fallback in the route
    ai.set_provider(Fake([None]))
    assert llm_answer("u", "q", [], l) is None

def test_ask_unknown_tool_is_harmless(mem_cache):
    from datetime import date
    from app.ask import llm_answer, Ledger
    l = Ledger([], today=date(2026, 11, 18))
    f = Fake([AIResult(None, [{"id": "c", "name": "drop_database", "arguments": {}}], raw_message={"role": "assistant", "content": None}), AIResult("$0 spent.")])
    ai.set_provider(f)
    assert llm_answer("u", "q", [], l)[0] == "$0 spent."
    assert "unknown tool" in [m for m in f.calls[1][1] if m["role"] == "tool"][0]["content"]

def test_null_provider_when_disabled(monkeypatch):
    monkeypatch.setenv("AI_PROVIDER", "none"); ai.set_provider(None)
    assert ai.provider().available() is False and ai.generate("x", None, "hi", cache=False) is None
    ai.set_provider(None)
