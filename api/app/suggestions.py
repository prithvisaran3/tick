"""Suggestions: at most two, on payday and once a week. Rules here pick them from the plan's own numbers (the same tools Ask Tick answers with);
the model only rewords them and must keep every dollar amount exactly, or the template is used. Accept and dismiss feed ask_memory, and a kind
dismissed twice rests for 30 days."""
from __future__ import annotations

import json
import re
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, ConfigDict

from . import ai
from . import ask_brain as B
from .auth import current_user, user_limiter
from .db import rest

router = APIRouter()
ET = ZoneInfo("America/New_York")
MAX = 2
REST_DAYS = 30
KINDS = ("over_plan", "goal_behind", "move_to_savings", "planned_soon", "room_to_spare")      # most urgent first
ROUTES = {"over_plan": "/planned", "goal_behind": "/savings", "move_to_savings": "/savings", "planned_soon": "/planned", "room_to_spare": "/savings"}

def _due(d) -> str:
    return f"{d:%b}\u00a0{d.day}"          # "Jan 1" never splits across lines

def candidates(l: B.Ledger) -> list[dict]:
    """Every suggestion the plan supports right now, most urgent first. {kind, facts, text}: text is the template, numbers from the tools."""
    t = B.Tools(l)
    parts = t._parts()
    safe, pay = parts["safe"], parts["payday"]
    goals = [(g, st) for g, st in t._goal_rows() if not g.get("paused")]
    out = []
    if safe < 0:
        out.append({"kind": "over_plan", "facts": {"gap": -safe}, "text": f"Your plan is {B.money(-safe)} over this pay period. Move a one-off or a goal date to make it fit."})
    behind = next(((g, st) for g, st in goals if st["status"] == "behind" and g.get("deadline")), None)
    if behind:
        g, st = behind
        out.append({"kind": "goal_behind", "facts": {"goal": g["name"], "behind": st["behind_by"], "per": st["per_paycheck"], "by": _due(g["deadline"])},
                    "text": f"{g['name']} is {B.money(st['behind_by'])} behind. {B.money(st['per_paycheck'])} a paycheck catches it up by {_due(g['deadline'])}."})
    if l.period and (l.today - l.period["period_start"]).days <= 1 and not l.goal_moved:
        move = sum(st["per_paycheck"] for _, st in goals if st["status"] != "done")
        if move > 0:
            out.append({"kind": "move_to_savings", "facts": {"cents": move}, "text": f"Payday: move {B.money(move)} to savings to keep your goals on time."})
    soon = sorted((p for p in l.planned if p.get("status", "planned") == "planned" and l.today <= B.PM._d(p["due"]) <= l.today + timedelta(days=7)), key=lambda p: B.PM._d(p["due"]))
    if soon:
        p = soon[0]
        out.append({"kind": "planned_soon", "facts": {"name": p["name"], "cents": int(p["cents"]), "due": _due(B.PM._d(p["due"]))},
                    "text": f"{p['name']}, {B.money(p['cents'])}, is planned for {_due(B.PM._d(p['due']))}. It's already set aside."})
    cushion = max(l.paycheck_cents // 4, 10000)
    spare = (safe - cushion) // 1000 * 1000
    target = next(((g, st) for g, st in goals if st["status"] == "on_track" and g.get("deadline")), None)
    if spare >= 2000 and target and not behind:
        g, _ = target
        out.append({"kind": "room_to_spare", "facts": {"goal": g["name"], "extra": spare}, "text": f"You have room this pay period. {B.money(spare)} more to {g['name']} still leaves {B.money(cushion)} safe to spend."})
    return out

def resting(memory: dict[str, dict], today: date) -> set[str]:
    """Kinds dismissed twice, the last time within 30 days. Accepting one resets its count."""
    out = set()
    for kind, v in memory.items():
        last = v.get("last_dismissed")
        if int(v.get("dismissed") or 0) >= 2 and last and (today - date.fromisoformat(last)).days < REST_DAYS:
            out.add(kind)
    return out

def pick(cands: list[dict], memory: dict[str, dict], today: date) -> list[dict]:
    rest_ = resting(memory, today)
    return [c for c in cands if c["kind"] not in rest_][:MAX]

def due_today(today: date, period: dict | None, last_day: date | None) -> bool:
    """Payday (or the day after), or a week since the last batch."""
    payday = period is not None and 0 <= (today - period["period_start"]).days <= 1
    return payday or last_day is None or (today - last_day).days >= 7

_MONEY = re.compile(r"\$\d[\d,]*(?:\.\d{2})?")

def word(user_id: str, picked: list[dict]) -> list[str]:
    """The model's wording, kept only when it carries every dollar amount the template does and nothing new. Otherwise the template."""
    texts = [c["text"] for c in picked]
    try:
        raw = ai.generate("plan_suggestion", user_id, json.dumps({"suggestions": texts}), json_out=True, max_tokens=300, cache=False,
                          system='Reword each suggestion as one plain sentence of at most 22 words. Sentence case, lead with the number, no exclamation marks, no jokes. '
                                 'Keep every dollar amount exactly as written and add no other numbers. JSON only: {"texts": [string, ...]} in the same order.')
        got = (json.loads(raw) or {}).get("texts") if raw else None
    except Exception:
        got = None
    if not isinstance(got, list) or len(got) != len(texts):
        return texts
    out = []
    for tmpl, new in zip(texts, got):
        ok = isinstance(new, str) and 0 < len(new) <= 240 and sorted(_MONEY.findall(new)) == sorted(_MONEY.findall(tmpl)) and len(re.findall(r"\d", re.sub(_MONEY, "", new))) <= len(re.findall(r"\d", re.sub(_MONEY, "", tmpl)))
        out.append(new.strip() if ok else tmpl)
    return out

def _memory(user_id: str) -> dict[str, dict]:
    return {m["key"]: m["value"] for m in rest().select("ask_memory", user_id=f"eq.{user_id}", kind="eq.suggestion", select="key,value")}

def today_ny() -> date:
    return datetime.now(timezone.utc).astimezone(ET).date()

@router.get("/plan/suggestions")
def get_suggestions(user_id: str = Depends(current_user)):
    """The current batch (made now if it's payday or a week has passed). Only ones I haven't answered."""
    from .ask import load_ledger
    user_limiter.check(f"plan-sug:{user_id}", 20, 60)
    today = today_ny()
    last = rest().select("plan_suggestions", user_id=f"eq.{user_id}", select="day", order="day.desc", limit="1")
    last_day = date.fromisoformat(last[0]["day"]) if last else None
    l = load_ledger(user_id)
    if due_today(today, l.period, last_day) and last_day != today:
        picked = pick(candidates(l), _memory(user_id), today)
        for c, text in zip(picked, word(user_id, picked)):
            rest().insert("plan_suggestions", {"user_id": user_id, "day": today.isoformat(), "kind": c["kind"], "facts": c["facts"], "text": text, "status": "shown"},
                          upsert_on="user_id,day,kind", ignore_duplicates=True, returning=False)
        last_day = today if picked else last_day
    if last_day is None or (today - last_day).days > 7:
        return {"suggestions": []}
    rows = rest().select("plan_suggestions", user_id=f"eq.{user_id}", day=f"eq.{last_day.isoformat()}", status="eq.shown", select="id,kind,text")
    rows.sort(key=lambda r: KINDS.index(r["kind"]))
    return {"suggestions": [{**r, "route": ROUTES[r["kind"]]} for r in rows[:MAX]]}

class AnswerBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    action: str

@router.post("/plan/suggestions/{sid}")
def answer(sid: str, body: AnswerBody, user_id: str = Depends(current_user)):
    """Accept (I acted on it) or dismiss. Either way it's recorded in the learning loop for its kind."""
    user_limiter.check(f"plan-sug-w:{user_id}", 30, 60)
    if body.action not in ("accept", "dismiss") or not re.fullmatch(r"[0-9a-f-]{36}", sid):
        raise HTTPException(404, "not found")
    row = rest().select("plan_suggestions", id=f"eq.{sid}", user_id=f"eq.{user_id}", select="id,kind,status")
    if not row:
        raise HTTPException(404, "not found")
    if row[0]["status"] != "shown":
        return {"saved": True}
    rest().update("plan_suggestions", {"id": sid, "user_id": user_id}, {"status": "accepted" if body.action == "accept" else "dismissed"})
    kind = row[0]["kind"]
    v = _memory(user_id).get(kind) or {}
    if body.action == "accept":
        v = {**v, "accepted": int(v.get("accepted") or 0) + 1, "dismissed": 0}
    else:
        v = {**v, "dismissed": int(v.get("dismissed") or 0) + 1, "last_dismissed": today_ny().isoformat()}
    rest().insert("ask_memory", {"user_id": user_id, "kind": "suggestion", "key": kind, "value": v}, upsert_on="user_id,kind,key")
    return {"saved": True}
