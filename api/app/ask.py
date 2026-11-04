"""Ask Tick: SSE chat. Gemini with tool calling (tools return compact results, never history dumps); a deterministic fallback answers the
suggested questions when Gemini is unavailable so the screen always works."""
from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone
from typing import Any, Iterator

from fastapi import APIRouter, Depends
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

from . import ai
from .auth import current_user
from .db import rest
from .intel import detect_recurring

router = APIRouter()

@dataclass
class Ledger:
    txns: list[dict]                     # {id, merchant, amount_cents, date, category, tags, account}
    recurring: list[dict] = field(default_factory=list)   # {merchant, cadence, expected_cents, next_date(date)}
    expected: list[dict] = field(default_factory=list)    # {label, kind, amount_cents, date}
    accounts: list[dict] = field(default_factory=list)    # {name, type, balance_cents, available_cents}
    budgets: list[dict] = field(default_factory=list)     # {category, cap_cents}
    payday: date | None = None
    today: date = field(default_factory=lambda: datetime.now(timezone.utc).date())

def money(c: int) -> str:
    return f"${abs(c) / 100:,.2f}".replace(".00", "") if abs(c) % 100 == 0 else f"${abs(c) / 100:,.2f}"

def _d(s: str | None, default: date) -> date:
    try:
        return date.fromisoformat(s) if s else default
    except ValueError:
        return default

# ----------------- tools (pure over Ledger) -----------------
class Tools:
    def __init__(self, l: Ledger) -> None:
        self.l = l

    def query_transactions(self, merchant: str = "", category: str = "", start: str = "", end: str = "", business_only: bool = False, limit: int = 8) -> dict:
        """Find transactions. Dates are YYYY-MM-DD. Returns up to `limit` newest matches plus count and total."""
        s, e = _d(start, date(2000, 1, 1)), _d(end, self.l.today)
        rows = [t for t in self.l.txns if s <= t["date"] <= e and (not merchant or merchant.lower() in t["merchant"].lower())
                and (not category or category.lower() == (t["category"] or "").lower()) and (not business_only or "business" in t["tags"])]
        rows.sort(key=lambda t: t["date"], reverse=True)
        return {"count": len(rows), "total_cents": sum(t["amount_cents"] for t in rows), "items": [{"id": t["id"], "merchant": t["merchant"], "cents": t["amount_cents"], "date": t["date"].isoformat()} for t in rows[:max(1, min(limit, 20))]]}

    def spend_by_category(self, start: str = "", end: str = "") -> dict:
        """Spending by category between two dates (default: this month)."""
        s, e = _d(start, self.l.today.replace(day=1)), _d(end, self.l.today)
        by: dict[str, int] = {}
        for t in self.l.txns:
            if s <= t["date"] <= e and t["amount_cents"] < 0 and t["category"] not in ("Transfer", "Income"):
                by[t["category"] or "Other"] = by.get(t["category"] or "Other", 0) - t["amount_cents"]
        return {"start": s.isoformat(), "end": e.isoformat(), "total_cents": sum(by.values()), "categories": sorted(({"name": k, "cents": v} for k, v in by.items()), key=lambda x: -x["cents"])[:8]}

    def compare_periods(self, a_start: str, a_end: str, b_start: str, b_end: str, category: str = "") -> dict:
        """Compare spending in period A vs period B (optionally one category)."""
        def tot(s: str, e: str) -> int:
            ss, ee = _d(s, self.l.today), _d(e, self.l.today)
            return -sum(t["amount_cents"] for t in self.l.txns if ss <= t["date"] <= ee and t["amount_cents"] < 0 and t["category"] not in ("Transfer",) and (not category or (t["category"] or "").lower() == category.lower()))
        a, b = tot(a_start, a_end), tot(b_start, b_end)
        return {"a_cents": a, "b_cents": b, "diff_cents": a - b, "pct": None if b == 0 else round((a - b) / b * 100, 1)}

    def list_upcoming(self, days: int = 14) -> dict:
        """Bills and subscriptions due in the next `days` days."""
        end = self.l.today + timedelta(days=days)
        items = sorted(({"merchant": r["merchant"], "cents": r["expected_cents"], "date": r["next_date"].isoformat()} for r in self.l.recurring if self.l.today <= r["next_date"] <= end), key=lambda x: x["date"])
        return {"total_cents": sum(i["cents"] for i in items), "items": items}

    def list_incoming(self, days: int = 30) -> dict:
        """Expected paychecks, refunds and money owed in the next `days` days."""
        end = self.l.today + timedelta(days=days)
        items = sorted(({"label": e["label"], "kind": e["kind"], "cents": e["amount_cents"], "date": e["date"].isoformat()} for e in self.l.expected if self.l.today <= e["date"] <= end), key=lambda x: x["date"])
        return {"total_cents": sum(i["cents"] for i in items), "items": items}

    def get_balances(self) -> dict:
        """Account balances."""
        return {"accounts": [{"name": a["name"], "type": a["type"], "balance_cents": a.get("balance_cents"), "available_cents": a.get("available_cents")} for a in self.l.accounts]}

    def get_budgets(self) -> dict:
        """Monthly category caps with spend so far this month."""
        sp = {c["name"]: c["cents"] for c in self.spend_by_category()["categories"]}
        return {"budgets": [{"category": b["category"], "cap_cents": b["cap_cents"], "spent_cents": sp.get(b["category"], 0)} for b in self.l.budgets]}

    def find_subscriptions(self) -> dict:
        """Recurring subscriptions and bills with next dates, flagging price increases."""
        det = detect_recurring([{"merchant": t["merchant"], "amount_cents": t["amount_cents"], "date": t["date"]} for t in self.l.txns], self.l.today)
        known = {r["merchant"] for r in self.l.recurring}
        items = [{"merchant": d.merchant, "cadence": d.cadence, "cents": d.expected_cents, "next": d.next_date.isoformat(), "price_hike": d.price_hike} for d in det]
        for r in self.l.recurring:
            if r["merchant"] not in {i["merchant"] for i in items}:
                items.append({"merchant": r["merchant"], "cadence": r["cadence"], "cents": r["expected_cents"], "next": r["next_date"].isoformat(), "price_hike": False})
        return {"count": len(items), "monthly_total_cents": sum(i["cents"] for i in items if i["cadence"] == "monthly"), "items": items[:12]}

    def business_total(self, month: str = "") -> dict:
        """Business-tagged spending for a month (YYYY-MM, default this month)."""
        y, m = (int(month[:4]), int(month[5:7])) if re.match(r"^\d{4}-\d{2}$", month or "") else (self.l.today.year, self.l.today.month)
        rows = [t for t in self.l.txns if t["date"].year == y and t["date"].month == m and "business" in t["tags"] and t["amount_cents"] < 0]
        return {"month": f"{y}-{m:02d}", "total_cents": -sum(t["amount_cents"] for t in rows), "count": len(rows), "items": [{"id": t["id"], "merchant": t["merchant"], "cents": t["amount_cents"]} for t in rows[:6]]}

# ----------------- deterministic fallback -----------------
FOOD = {"Groceries", "Restaurants", "Coffee"}

def week_bars(l: Ledger, cats: set[str] | None = None) -> dict:
    start = l.today.replace(day=1)
    n_weeks = (l.today.day - 1) // 7 + 1
    vals = []
    for w in range(n_weeks):
        a, b = start + timedelta(days=7 * w), start + timedelta(days=7 * w + 6)
        c = -sum(t["amount_cents"] for t in l.txns if a <= t["date"] <= min(b, l.today) and t["amount_cents"] < 0 and (cats is None or t["category"] in cats))
        vals.append({"label": f"Wk {w + 1}" if w < n_weeks - 1 else "Now", "cents": c})
    return {"kind": "bars", "values": vals}

def fallback_answer(q: str, l: Ledger) -> tuple[str, list[dict]]:
    t = Tools(l)
    ql = q.lower()
    first = l.today.replace(day=1)
    prev_end = first - timedelta(days=1)
    if re.search(r"\b(food|eat|restaurant|grocer|coffee|dining)\b", ql):
        rows = [x for x in l.txns if x["category"] in FOOD and x["amount_cents"] < 0 and x["date"] >= first]
        tot = -sum(x["amount_cents"] for x in rows)
        prev = t.compare_periods(prev_end.replace(day=1).isoformat(), (prev_end.replace(day=1) + timedelta(days=l.today.day - 1)).isoformat(), first.isoformat(), l.today.isoformat())  # a=last month same days, b=this month
        diff = tot - prev["a_cents"]
        txt = f"{money(tot)} on food so far this month." + (f" That's {money(abs(diff))} {'over' if diff > 0 else 'under'} last month at this point." if prev["a_cents"] else "")
        big = sorted(rows, key=lambda x: x["amount_cents"])[:3]
        return txt, [week_bars(l, FOOD), {"kind": "txns", "ids": [x["id"] for x in big]}]
    if re.search(r"\b(due|bills?|upcoming|owe)\b", ql):
        r = t.list_upcoming(7)
        if not r["items"]:
            return "$0 due in the next 7 days. Nothing to pay this week.", []
        return f"{money(r['total_cents'])} due in the next 7 days: " + ", ".join(f"{i['merchant']} {money(i['cents'])}" for i in r["items"][:4]) + ".", []
    if "business" in ql:
        r = t.business_total()
        return f"{money(r['total_cents'])} of Business spending this month across {r['count']} purchases.", [{"kind": "txns", "ids": [i["id"] for i in r["items"][:4]]}] if r["items"] else []
    if re.search(r"subscri", ql):
        r = t.find_subscriptions()
        hikes = [i["merchant"] for i in r["items"] if i["price_hike"]]
        txt = f"{money(r['monthly_total_cents'])} a month across {r['count']} recurring charges."
        return txt + (f" {', '.join(hikes)} went up recently." if hikes else ""), []
    m = re.search(r"afford\s+\$?(\d[\d,]*(?:\.\d\d)?)", ql)
    if m:
        want = round(float(m.group(1).replace(",", "")) * 100)
        bills = t.list_upcoming(max(1, ((l.payday or l.today + timedelta(days=7)) - l.today).days))["total_cents"]
        cash = sum((a.get("available_cents") or a.get("balance_cents") or 0) for a in l.accounts if a["type"] in ("checking", "cash"))
        safe = cash - bills
        return (f"Yes. {money(want)} leaves {money(safe - want)} safe to spend." if safe >= want else f"Not comfortably. Safe to spend is {money(max(safe, 0))}, so {money(want)} runs {money(want - max(safe, 0))} past it."), []
    cats = t.spend_by_category()
    if cats["categories"]:
        top = cats["categories"][0]
        return f"{money(cats['total_cents'])} spent this month. Biggest category: {top['name']} at {money(top['cents'])}.", []
    return "Nothing spent yet this month.", []

# ----------------- route -----------------
class AskBody(BaseModel):
    question: str
    history: list[dict] = []

def load_ledger(user_id: str) -> Ledger:
    today = datetime.now(timezone.utc).date()
    since = (today - timedelta(days=400)).isoformat()
    cats = {c["id"]: c["name"] for c in rest().select("categories", user_id=f"eq.{user_id}", select="id,name")}
    r = rest().c.get(f"{rest().base}/transactions", headers=rest().h, params=[("user_id", f"eq.{user_id}"), ("occurred_at", f"gte.{since}"), ("select", "id,merchant_clean,merchant_raw,amount_cents,occurred_at,category_id,tags,account_id"), ("limit", "5000")])
    r.raise_for_status()
    txns = [{"id": x["id"], "merchant": x["merchant_clean"] or x["merchant_raw"] or "", "amount_cents": x["amount_cents"], "date": datetime.fromisoformat(x["occurred_at"].replace("Z", "+00:00")).date(),
             "category": cats.get(x["category_id"]), "tags": x["tags"] or [], "account": x["account_id"]} for x in r.json()]
    rec = [{"merchant": x["merchant"], "cadence": x["cadence"], "expected_cents": x["expected_cents"], "next_date": date.fromisoformat(x["next_date"])} for x in rest().select("recurring", user_id=f"eq.{user_id}", status="eq.active")]
    exp = [{"label": x["label"], "kind": x["kind"], "amount_cents": x["amount_cents"], "date": date.fromisoformat(x["expected_date"])} for x in rest().select("expected", user_id=f"eq.{user_id}", status="eq.expected")]
    acc = rest().select("accounts", user_id=f"eq.{user_id}", select="name,type,balance_cents,available_cents")
    bud = [{"category": cats.get(x["category_id"], "Other"), "cap_cents": x["monthly_cap_cents"]} for x in rest().select("budgets", user_id=f"eq.{user_id}")]
    st = rest().select("settings", user_id=f"eq.{user_id}", select="payday_rule")
    payday = None
    if st and st[0].get("payday_rule") and st[0]["payday_rule"].get("next_date"):
        payday = date.fromisoformat(st[0]["payday_rule"]["next_date"])
    return Ledger(txns, rec, exp, acc, bud, payday, today)

TOOL_SPECS = [
    {"name": "query_transactions", "description": "Find transactions. Dates are YYYY-MM-DD. Returns up to `limit` newest matches plus count and total (cents).",
     "parameters": {"type": "object", "properties": {"merchant": {"type": "string"}, "category": {"type": "string"}, "start": {"type": "string"}, "end": {"type": "string"}, "business_only": {"type": "boolean"}, "limit": {"type": "integer"}}}},
    {"name": "spend_by_category", "description": "Spending by category between two dates (default this month). Amounts in cents.",
     "parameters": {"type": "object", "properties": {"start": {"type": "string"}, "end": {"type": "string"}}}},
    {"name": "compare_periods", "description": "Compare spending in period A vs period B, optionally one category. Amounts in cents.",
     "parameters": {"type": "object", "properties": {"a_start": {"type": "string"}, "a_end": {"type": "string"}, "b_start": {"type": "string"}, "b_end": {"type": "string"}, "category": {"type": "string"}}, "required": ["a_start", "a_end", "b_start", "b_end"]}},
    {"name": "list_upcoming", "description": "Bills and subscriptions due in the next N days.", "parameters": {"type": "object", "properties": {"days": {"type": "integer"}}}},
    {"name": "list_incoming", "description": "Expected paychecks, refunds and money owed in the next N days.", "parameters": {"type": "object", "properties": {"days": {"type": "integer"}}}},
    {"name": "get_balances", "description": "Account balances (cents).", "parameters": {"type": "object", "properties": {}}},
    {"name": "get_budgets", "description": "Monthly category caps with spend so far.", "parameters": {"type": "object", "properties": {}}},
    {"name": "find_subscriptions", "description": "Recurring subscriptions and bills, flagging price increases.", "parameters": {"type": "object", "properties": {}}},
    {"name": "business_total", "description": "Business-tagged spending for a month (YYYY-MM, default this month).", "parameters": {"type": "object", "properties": {"month": {"type": "string"}}}},
]
OR_TOOLS = [{"type": "function", "function": t} for t in TOOL_SPECS]
MAX_AI_CALLS = 3

SYSTEM = ("You are Tick, a friend who is great with money, inside a personal finance app. Answer in plain sentences. LEAD WITH THE NUMBER (for example "
          "'$412 on food this month.'). Use the tools for facts; never invent figures. Tool money amounts are in cents: convert to dollars. Keep answers under 60 words. "
          "No emoji. If something looks wrong with money, stay calm and practical. Today is {today}.")

def llm_answer(user_id: str, q: str, history: list[dict], l: Ledger) -> tuple[str, list[dict]] | None:
    """Tool-calling chat on free OpenRouter models. Sends only tool results and the last 6 messages. None -> deterministic fallback."""
    prov = ai.provider()
    if not prov.available():
        return None
    tools = Tools(l)
    blocks: list[dict] = []
    msgs: list[dict] = [{"role": "system", "content": SYSTEM.format(today=l.today.isoformat())}]
    for h in history[-6:]:
        if h.get("role") in ("user", "assistant") and h.get("text"):
            msgs.append({"role": h["role"], "content": ai.scrub(str(h["text"]))})
    msgs.append({"role": "user", "content": ai.scrub(q)})
    for _ in range(MAX_AI_CALLS):
        r = ai._chat("tools", msgs, user_id, "ask", tools=OR_TOOLS, max_tokens=300)
        if r is None:
            return None
        if not r.tool_calls:
            text = (r.text or "").strip()
            return (text, blocks[:2]) if text else None
        msgs.append(r.raw_message or {"role": "assistant", "content": r.text or "", "tool_calls": []})
        for tc in r.tool_calls:
            fn = getattr(tools, tc["name"], None) if tc["name"] in {t["name"] for t in TOOL_SPECS} else None
            try:
                res = fn(**{k: v for k, v in tc["arguments"].items()}) if fn else {"error": "unknown tool"}
            except Exception:
                res = {"error": "bad arguments"}
            if isinstance(res, dict) and res.get("items") and isinstance(res["items"][0], dict) and "id" in res["items"][0]:
                blocks.append({"kind": "txns", "ids": [i["id"] for i in res["items"][:4]]})
            msgs.append({"role": "tool", "tool_call_id": tc["id"], "content": json.dumps(res)[:3000]})
    return None

def sse(events: Iterator[dict]) -> Iterator[str]:
    for e in events:
        yield f"data: {json.dumps(e)}\n\n"

@router.post("/ask")
def ask(body: AskBody, user_id: str = Depends(current_user)):
    q = body.question.strip()[:500]
    def gen() -> Iterator[dict]:
        l = load_ledger(user_id)
        res = llm_answer(user_id, q, body.history, l) or fallback_answer(q, l)
        text, blocks = res
        words = re.findall(r"\S+\s*", text)
        for i in range(0, len(words), 3):
            yield {"type": "token", "text": "".join(words[i:i + 3])}
        for b in blocks:
            yield {"type": "block", "block": b}
        yield {"type": "done"}
    return StreamingResponse(sse(gen()), media_type="text/event-stream", headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})
