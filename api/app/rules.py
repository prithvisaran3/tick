"""Person-aware categories: spot recurring person-to-person payments, turn them into category_rules, and create rules from a manual edit.
Matching and applying happen in SQL (tick_apply_category_rules). `detect` is pure."""
from __future__ import annotations

import math
import re
from dataclasses import dataclass
from datetime import date, datetime
from statistics import median
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, ConfigDict, Field

from .auth import current_user, user_limiter
from .db import rest

router = APIRouter()
ET = ZoneInfo("America/New_York")
BAND = 0.10
GAP = (25, 35)
UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")

@dataclass
class Recurring:
    person: str
    amount_cents: int
    day: int
    count: int
    last: date

def typical_day(days: list[int]) -> int:
    """Average day of the month round the month end: the 30th, 1st and 2nd average to about the 1st, not the 11th."""
    a = [2 * math.pi * (d - 1) / 31 for d in days]
    m = math.atan2(sum(map(math.sin, a)), sum(map(math.cos, a))) % (2 * math.pi)
    return round(m / (2 * math.pi) * 31) % 31 + 1

def chains(rows: list[dict]) -> list[list[dict]]:
    """Runs of similar payments about a month apart. A settle-up between two rent payments just isn't part of the run."""
    rows = sorted(rows, key=lambda r: str(r["day"]))
    out = []
    for i, seed in enumerate(rows):
        run = [seed]
        for r in rows[i + 1:]:
            gap = (_d(r["day"]) - _d(run[-1]["day"])).days
            if gap > GAP[1]:
                break
            if gap >= GAP[0] and abs(r["amount_cents"] - seed["amount_cents"]) <= seed["amount_cents"] * BAND:
                run.append(r)
        if len(run) >= 2:
            out.append(run)
    return out

def _d(v) -> date:
    return v if isinstance(v, date) else date.fromisoformat(str(v)[:10])

def detect(rows: list[dict], skip: set[str] = frozenset()) -> list[Recurring]:
    """rows: {person, amount_cents (positive), day}. The longest, latest run per person; people in [skip] already have an answer."""
    by: dict[str, list[dict]] = {}
    for r in rows:
        if r.get("person") and r["person"] not in skip:
            by.setdefault(r["person"], []).append(r)
    out = []
    for person, rs in by.items():
        runs = chains(rs)
        if runs:
            run = max(runs, key=lambda c: (len(c), str(c[-1]["day"])))
            out.append(Recurring(person, round(median(r["amount_cents"] for r in run)), typical_day([_d(r["day"]).day for r in run]), len(run), _d(run[-1]["day"])))
    return sorted(out, key=lambda x: -x.amount_cents)

def title(person: str) -> str:
    return " ".join(w.capitalize() for w in person.split())

def apply(user_id: str) -> int:
    return int(rest().rpc("tick_apply_category_rules", {"p_uid": user_id}) or 0)

def _cat(user_id: str, name: str) -> str:
    rows = rest().select("categories", user_id=f"eq.{user_id}", name=f"eq.{name}", select="id")
    if not rows:
        raise HTTPException(404, "category not found")
    return rows[0]["id"]

def _rules(user_id: str) -> list[dict]:
    return rest().select("category_rules", user_id=f"eq.{user_id}", select="id,person_key,aliases,amount_cents,day_of_month,category_id,ignored")

@router.get("/rules/suggestions")
def suggestions(user_id: str = Depends(current_user)):
    user_limiter.check(f"rules:{user_id}", 30, 60)
    known = {k for r in _rules(user_id) for k in [r["person_key"], *(r.get("aliases") or [])]}
    rows = [r for r in rest().rpc("tick_p2p_rows", {"p_uid": user_id, "p_days": 400}) if not r.get("edited")]
    return {"suggestions": [{"person": d.person, "name": title(d.person), "amount_cents": d.amount_cents, "day": d.day, "count": d.count} for d in detect(rows, known)]}

class AcceptBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    person: str = Field(min_length=1, max_length=120)
    amount_cents: int = Field(gt=0, lt=100_000_000)
    day: int = Field(ge=1, le=31)
    kind: str = Field(pattern="^(rent|bill|no)$")

@router.post("/rules/accept")
def accept(body: AcceptBody, user_id: str = Depends(current_user)):
    """Rent / Other bill / Not recurring on the "Looks like rent" card."""
    user_limiter.check(f"rules-w:{user_id}", 30, 60)
    row = {"user_id": user_id, "person_key": body.person, "display_name": title(body.person), "amount_cents": body.amount_cents, "day_of_month": body.day, "source": "suggested"}
    if body.kind == "no":
        rest().insert("category_rules", {**row, "ignored": True}, returning=False)
        return {"applied": 0}
    rest().insert("category_rules", {**row, "category_id": _cat(user_id, "Rent" if body.kind == "rent" else "Other")}, returning=False)
    return {"applied": apply(user_id)}

class RuleEdit(BaseModel):
    model_config = ConfigDict(extra="forbid")
    amount_cents: int = Field(gt=0, lt=100_000_000)

def _own(user_id: str, rule_id: str) -> dict:
    if not UUID.fullmatch(rule_id):
        raise HTTPException(404, "not found")
    rows = rest().select("category_rules", id=f"eq.{rule_id}", user_id=f"eq.{user_id}")
    if not rows:
        raise HTTPException(404, "not found")
    return rows[0]

@router.post("/rules/{rule_id}/amount")
def edit_rule(rule_id: str, body: RuleEdit, user_id: str = Depends(current_user)):
    """Profile > Category rules: about how much. Re-applies, so rows move in or out of the rule at once."""
    user_limiter.check(f"rules-w:{user_id}", 30, 60)
    _own(user_id, rule_id)
    rest().update("category_rules", {"id": rule_id, "user_id": user_id}, {"amount_cents": body.amount_cents})
    return {"applied": apply(user_id)}

@router.post("/rules/{rule_id}/delete")
def delete_rule(rule_id: str, user_id: str = Depends(current_user)):
    """Returns the rule so Undo can put it back exactly."""
    user_limiter.check(f"rules-w:{user_id}", 30, 60)
    row = _own(user_id, rule_id)
    rest().delete("category_rules", {"id": rule_id, "user_id": user_id})
    apply(user_id)
    return {"rule": row}

class RestoreBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    rule: dict

@router.post("/rules/restore")
def restore_rule(body: RestoreBody, user_id: str = Depends(current_user)):
    user_limiter.check(f"rules-w:{user_id}", 30, 60)
    keep = {"person_key", "aliases", "display_name", "amount_cents", "band_pct", "day_of_month", "day_window", "keywords", "category_id", "priority", "ignored", "source"}
    row = {k: v for k, v in body.rule.items() if k in keep}
    if not row.get("person_key") or (row.get("category_id") and not rest().select("categories", id=f"eq.{row['category_id']}", user_id=f"eq.{user_id}", select="id")):
        raise HTTPException(422, "Check the details and try again.")
    rest().insert("category_rules", {**row, "user_id": user_id}, returning=False)
    return {"applied": apply(user_id)}

class FromTxnBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    txn_id: str
    category_id: str

@router.post("/rules/from-txn")
def from_txn(body: FromTxnBody, user_id: str = Depends(current_user)):
    """"Always for Kaarthik around $X?" after a manual change: create the rule, or move the one this person has for that category."""
    user_limiter.check(f"rules-w:{user_id}", 30, 60)
    if not UUID.fullmatch(body.txn_id) or not UUID.fullmatch(body.category_id):
        raise HTTPException(404, "not found")
    t = next((r for r in rest().rpc("tick_p2p_rows", {"p_uid": user_id, "p_days": 800}) if r["id"] == body.txn_id), None)
    if not rest().select("categories", id=f"eq.{body.category_id}", user_id=f"eq.{user_id}", select="id") or t is None or not t.get("person"):
        raise HTTPException(404, "not found")
    patch = {"amount_cents": t["amount_cents"], "day_of_month": _d(t["day"]).day}
    same = next((r for r in _rules(user_id) if r["person_key"] == t["person"] and r.get("category_id") == body.category_id), None)
    if same:
        rest().update("category_rules", {"id": same["id"], "user_id": user_id}, patch)
    else:
        rest().insert("category_rules", {"user_id": user_id, "person_key": t["person"], "display_name": title(t["person"]), "category_id": body.category_id, "source": "manual", **patch}, returning=False)
    return {"applied": apply(user_id), "person": title(t["person"])}
