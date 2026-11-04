"""Recurring detection, price-hike detection, weekly insight, morning advice. Pure logic + thin DB glue."""
from __future__ import annotations

import statistics
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field

from . import ai, store
from .auth import current_user, require_cron
from .db import rest
from .merchants import clean_merchant

router = APIRouter()

@dataclass
class Detected:
    merchant: str
    cadence: str                  # weekly | biweekly | monthly | yearly
    expected_cents: int           # positive magnitude (latest price)
    next_date: date
    price_history: list[dict] = field(default_factory=list)   # [{date, cents}] distinct price changes, oldest first
    price_hike: bool = False
    occurrences: int = 0

CADENCES = [("weekly", 7, 2), ("biweekly", 14, 3), ("monthly", 30, 5), ("yearly", 365, 14)]

def _cadence(gaps: list[int]) -> tuple[str, int] | None:
    med = statistics.median(gaps)
    for name, days, tol in CADENCES:
        if abs(med - days) <= tol and sum(1 for g in gaps if abs(g - days) <= tol * 2) >= max(1, int(len(gaps) * 0.7)):
            return name, days
    return None

def detect_recurring(txns: list[dict], today: date, *, min_occurrences: int = 3) -> list[Detected]:
    """txns: [{merchant, amount_cents(neg=out), date(date)}]. Groups outgoing spend by cleaned merchant."""
    groups: dict[str, list[tuple[date, int]]] = {}
    for t in txns:
        if t["amount_cents"] >= 0:
            continue
        m = clean_merchant(t["merchant"]) or t["merchant"]
        groups.setdefault(m, []).append((t["date"], -t["amount_cents"]))
    out: list[Detected] = []
    for m, rows in groups.items():
        rows.sort()
        # collapse same-day duplicates
        rows = [r for i, r in enumerate(rows) if i == 0 or r[0] != rows[i - 1][0]]
        if len(rows) < min_occurrences:
            continue
        amts = [a for _, a in rows]
        med = statistics.median(amts)
        stable = [a for a in amts if abs(a - med) <= med * 0.35]
        if len(stable) < max(min_occurrences, int(len(amts) * 0.7)):
            continue                                    # amounts too erratic (groceries, rideshare)
        gaps = [(rows[i][0] - rows[i - 1][0]).days for i in range(1, len(rows))]
        c = _cadence(gaps)
        if not c:
            continue
        name, days = c
        last_date, last_amt = rows[-1]
        nxt = last_date + timedelta(days=days)
        if name == "monthly":
            y, mo = (last_date.year + (last_date.month // 12), last_date.month % 12 + 1)
            import calendar
            nxt = date(y, mo, min(last_date.day, calendar.monthrange(y, mo)[1]))
        while nxt < today and name != "yearly":
            nxt += timedelta(days=days)
        hist: list[dict] = []
        for d, a in rows:
            if not hist or abs(a - hist[-1]["cents"]) > max(50, hist[-1]["cents"] * 0.02):
                hist.append({"date": d.isoformat(), "cents": a})
        hike = len(hist) >= 2 and hist[-1]["cents"] > hist[-2]["cents"] * 1.03 and (today - date.fromisoformat(hist[-1]["date"])).days <= 62
        out.append(Detected(m, name, last_amt, nxt, hist, hike, len(rows)))
    return sorted(out, key=lambda d: d.next_date)

def forgotten_subscriptions(detected: list[Detected], used_recently: set[str]) -> list[Detected]:
    return [d for d in detected if d.cadence in ("monthly", "yearly") and d.merchant not in used_recently and d.expected_cents >= 500]

def weekly_summary(txns: list[dict], today: date) -> dict:
    start = today - timedelta(days=7)
    prev = start - timedelta(days=7)
    cur = [t for t in txns if start <= t["date"] < today and t["amount_cents"] < 0]
    old = [t for t in txns if prev <= t["date"] < start and t["amount_cents"] < 0]
    spent = -sum(t["amount_cents"] for t in cur)
    spent_prev = -sum(t["amount_cents"] for t in old)
    by_m: dict[str, int] = {}
    for t in cur:
        by_m[t["merchant"]] = by_m.get(t["merchant"], 0) - t["amount_cents"]
    top = sorted(by_m.items(), key=lambda kv: -kv[1])[:3]
    return {"spent_cents": spent, "prev_cents": spent_prev, "top": top, "count": len(cur)}

def fmt(c: int) -> str:
    return f"${c / 100:,.0f}"

def weekly_text_fallback(s: dict) -> str:
    if s["count"] == 0:
        return "Quiet week. Your wallet says thanks."
    delta = s["spent_cents"] - s["prev_cents"]
    cmp = "about the same as the week before" if s["prev_cents"] == 0 or abs(delta) < s["prev_cents"] * 0.05 else (f"{fmt(abs(delta))} {'more' if delta > 0 else 'less'} than the week before")
    top = ", ".join(f"{m} {fmt(c)}" for m, c in s["top"][:2])
    return f"{fmt(s['spent_cents'])} out this week, {cmp}. Biggest: {top}."

class AdviceBody(BaseModel):
    total_cents: int = Field(ge=0, le=10**10)
    safe_cents: int = Field(ge=-(10**10), le=10**10)
    days_to_payday: int = Field(ge=0, le=400)
    captures: int = Field(ge=0, le=10000)
    top_merchant: str | None = Field(default=None, max_length=80)

def advice_fallback(b: AdviceBody) -> str:
    if b.captures == 0:
        return "Quiet day. Your wallet says thanks."
    if b.safe_cents < 0:
        return "Bills and goals are ahead of your cash. Hold off on extras until payday."
    per = b.safe_cents // max(1, b.days_to_payday)
    if b.total_cents > per * 1.5 and per > 0:
        return f"A bigger day than your pace. About {fmt(per)} a day keeps you on track."
    return f"You are on pace. About {fmt(per)} a day keeps it that way."

ET = ZoneInfo("America/New_York")

def et_today() -> date:
    return datetime.now(ET).date()

@router.post("/intel/advice")
def advice(body: AdviceBody, user_id: str = Depends(current_user)):
    """Never calls AI on app open: returns the line the daily job stored, else a local template."""
    rows = rest().select("insights", user_id=f"eq.{user_id}", kind="eq.morning_advice", period=f"eq.{et_today().isoformat()}", select="body", order="created_at.desc", limit="1")
    if rows:
        return {"text": rows[0]["body"], "source": "stored"}
    return {"text": advice_fallback(body), "source": "fallback"}

ADVICE_SYSTEM = ("You are Tick, a friend who is great with money. Write ONE plain sentence of advice, under 22 words, lead with a number or action, "
                 "no emoji, no jokes about money problems.")

@router.post("/jobs/daily-advice", dependencies=[Depends(require_cron)])
def daily_advice_job():
    """Once a day (about 7-8am Eastern): one AI call per user, stored; the app reads it, never calls AI on open."""
    n = 0
    today = et_today()
    for u in rest().select("settings", select="user_id"):
        uid = u["user_id"]
        try:
            if rest().select("insights", user_id=f"eq.{uid}", kind="eq.morning_advice", period=f"eq.{today.isoformat()}", select="id"):
                continue
            tx = _txns_for(uid, 9)
            y = today - timedelta(days=1)
            ys = [t for t in tx if t["date"] == y and t["amount_cents"] < 0]
            total = -sum(t["amount_cents"] for t in ys)
            week = [t for t in tx if y - timedelta(days=7) <= t["date"] < y and t["amount_cents"] < 0]
            avg = -sum(t["amount_cents"] for t in week) // 7
            top = max(ys, key=lambda t: -t["amount_cents"])["merchant"] if ys else None
            b = AdviceBody(total_cents=total, safe_cents=0, days_to_payday=1, captures=len(ys), top_merchant=top)
            text = None
            if ys:
                ctx = f"Yesterday spending {fmt(total)} over {len(ys)} purchases (largest merchant: {top}). Daily average last week {fmt(avg)}."
                text = ai.generate("advice", uid, ctx, system=ADVICE_SYSTEM, max_tokens=60)
                text = (text or "").strip().split("\n")[0] or None
            rest().insert("insights", {"user_id": uid, "kind": "morning_advice", "body": text or advice_fallback(b), "payload": {"ai": bool(text)}, "period": today.isoformat()})
            n += 1
        except Exception:
            continue
    return {"users": n}

@router.get("/ai/status")
def ai_status(user_id: str = Depends(current_user)):
    return ai.provider().status()

def _txns_for(user_id: str, days: int) -> list[dict]:
    since = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
    r = rest().c.get(f"{rest().base}/transactions", headers=rest().h, params=[("user_id", f"eq.{user_id}"), ("occurred_at", f"gte.{since}"), ("select", "merchant_clean,merchant_raw,amount_cents,occurred_at"), ("limit", "5000")])
    r.raise_for_status()
    return [{"merchant": x["merchant_clean"] or x["merchant_raw"] or "", "amount_cents": x["amount_cents"], "date": datetime.fromisoformat(x["occurred_at"].replace("Z", "+00:00")).astimezone(ET).date()} for x in r.json()]

def refresh_recurring(user_id: str) -> int:
    today = datetime.now(timezone.utc).date()
    det = detect_recurring(_txns_for(user_id, 420), today)
    existing = {r["merchant"]: r for r in rest().select("recurring", user_id=f"eq.{user_id}")}
    for d in det:
        row = {"user_id": user_id, "merchant": d.merchant, "cadence": d.cadence, "expected_cents": d.expected_cents, "next_date": d.next_date.isoformat(),
               "price_history": d.price_history, "last_seen": today.isoformat(), "status": "active"}
        cur = existing.get(d.merchant)
        if cur and cur.get("is_manual"):
            row.pop("cadence"); row.pop("expected_cents")        # a manual entry's cadence/price stay as the user set them
        rest().insert("recurring", row, upsert_on="user_id,merchant")
    return len(det)

@router.post("/intel/refresh")
def refresh(user_id: str = Depends(current_user)):
    return {"recurring": refresh_recurring(user_id)}

@router.post("/jobs/weekly-insights", dependencies=[Depends(require_cron)])
def weekly_job():
    users = rest().select("settings", select="user_id")
    n = 0
    for u in users:
        uid = u["user_id"]
        try:
            wk = (datetime.now(timezone.utc).date() - timedelta(days=5)).isoformat()
            if rest().select("insights", user_id=f"eq.{uid}", kind="eq.weekly", period=f"gte.{wk}", select="id"):
                continue
            s = weekly_summary(_txns_for(uid, 16), datetime.now(timezone.utc).date())
            ctx = f"This week: spent {fmt(s['spent_cents'])} over {s['count']} purchases; last week {fmt(s['prev_cents'])}; top: " + ", ".join(f"{m} {fmt(c)}" for m, c in s["top"])
            text = ai.generate("weekly_insight", uid, ctx, system="You are Tick. Write the weekly review in at most 2 short plain sentences. Lead with the number. No emoji.", max_tokens=100)
            rest().insert("insights", {"user_id": uid, "kind": "weekly", "body": (text or weekly_text_fallback(s)).strip(), "payload": s, "period": datetime.now(timezone.utc).date().isoformat()})
            refresh_recurring(uid)
            n += 1
        except Exception:
            continue
    return {"users": n}
