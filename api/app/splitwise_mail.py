"""The Splitwise category. Two sources feed it.

Source A: Splitwise notification emails, read only with the owner's consent. `parse_email` keeps parsed fields, never the body. The email format is ASSUMED, from memory of
what those emails say; there's no real sample in this repo (docs/POLISH_V3.md has the OAuth setup and what to check). It fails soft: an email it can't read is skipped.
Source B: `likely` suggests rows that look like Splitwise, for one-tap confirm or reject.
Rent rules always win: a row a category rule claimed is never touched here."""
from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import date, datetime, timedelta

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, ConfigDict

from .auth import current_user, user_limiter
from .db import rest
from .paybacks import is_person_credit, is_purchase, name_score, payer_name, suggest

router = APIRouter()
MATCH_DAYS = 3
SETTLE_DAYS = 5
_MONEY = r"\$([\d,]+(?:\.\d{2})?)"

@dataclass
class Event:
    gmail_id: str
    kind: str                 # expense | settle_out | settle_in
    occurred_on: date
    description: str | None = None
    total_cents: int | None = None
    my_share_cents: int | None = None
    person: str | None = None

def _cents(s: str) -> int:
    return round(float(s.replace(",", "")) * 100)

def parse_email(gmail_id: str, subject: str, text: str, on: date) -> Event | None:
    """None for anything that isn't clearly an expense or a settle-up."""
    try:
        s, t = subject or "", " ".join((text or "").split())
        m = re.search(rf"(.+?) (?:paid|settled up with) you {_MONEY}|(.+?) paid you {_MONEY}", s + " " + t)
        if m and "you paid" not in s.lower():
            return Event(gmail_id, "settle_in", on, person=(m.group(1) or m.group(3)).strip(), total_cents=_cents(m.group(2) or m.group(4)))
        m = re.search(rf"You paid ([A-Z][\w.' -]+?) {_MONEY}", s + " " + t)
        if m:
            return Event(gmail_id, "settle_out", on, person=m.group(1).strip(), total_cents=_cents(m.group(2)))
        m = re.search(r"added [\"“](.+?)[\"”]", s) or re.search(r"[\"“](.+?)[\"”]", s)
        total = re.search(rf"(?:Total|total|costs?|for)[: ]+{_MONEY}", t) or re.search(_MONEY, t)
        if not m or not total:
            return None
        cost = _cents(total.group(1))
        back = re.search(rf"You get back {_MONEY}", t)
        owe = re.search(rf"You owe {_MONEY}", t)
        if not back and not owe:
            return None
        return Event(gmail_id, "expense", on, description=m.group(1)[:120], total_cents=cost, my_share_cents=cost - _cents(back.group(1)) if back else _cents(owe.group(1)))
    except (ValueError, AttributeError, IndexError):
        return None

def _d(v) -> date:
    return v if isinstance(v, date) else datetime.fromisoformat(str(v).replace("Z", "+00:00")).date()

def match(events: list[dict], rows: list[dict]) -> list[dict]:
    """Which bank row each event is. Only rows with no rule and no manual category: rent stays rent. Each row is used once.
    An expense matches a charge I fronted (others' part is back out of spending); a settle-up matches Zelle in or out, and lists what it covered."""
    used: set[str] = set()
    out = []
    open_expenses = [e for e in events if e["kind"] == "expense"]
    free = [r for r in rows if not r.get("category_rule_id") and "category" not in (r.get("user_edited") or [])]
    for e in sorted(events, key=lambda x: str(x.get("occurred_on"))):
        if e.get("matched_txn"):
            used.add(e["matched_txn"]); continue
        on, cents = _d(e["occurred_on"]), e.get("total_cents") or 0
        if e["kind"] == "expense":
            hit = next((r for r in free if r["id"] not in used and r["amount_cents"] == -cents and abs((_d(r["occurred_at"]) - on).days) <= MATCH_DAYS), None)
            if hit and (e.get("my_share_cents") or 0) < cents:
                used.add(hit["id"])
                out.append({"event": e["id"], "txn": hit["id"], "kind": "expense", "shared_cents": cents - e["my_share_cents"], "note": f"Splitwise: {e.get('description') or 'expense'}"})
        elif e["kind"] in ("settle_out", "settle_in"):
            sign = -1 if e["kind"] == "settle_out" else 1
            hit = next((r for r in free if r["id"] not in used and r["amount_cents"] == sign * cents and abs((_d(r["occurred_at"]) - on).days) <= SETTLE_DAYS
                        and name_score(e.get("person"), r.get("merchant_raw") or r.get("merchant_clean") or "")), None)
            if hit:
                used.add(hit["id"])
                covered = [x["description"] for x in open_expenses if _d(x["occurred_on"]) <= on and x.get("description")][-5:]
                out.append({"event": e["id"], "txn": hit["id"], "kind": "settle", "covers": covered, "note": "Splitwise settlement" + (f": {', '.join(covered)}"[:200] if covered else "")})
    return out

def ingest(user_id: str, events: list[Event]) -> int:
    """Stores parsed events, once per Gmail message, then matches. Called by whatever fetches the mail."""
    for e in events:
        rest().insert("splitwise_events", {"user_id": user_id, "gmail_id": e.gmail_id, "kind": e.kind, "description": e.description, "total_cents": e.total_cents, "my_share_cents": e.my_share_cents,
                                           "person": e.person, "occurred_on": e.occurred_on.isoformat()}, upsert_on="user_id,gmail_id", ignore_duplicates=True)
    return apply(user_id)

def apply(user_id: str) -> int:
    ev = rest().select("splitwise_events", user_id=f"eq.{user_id}", select="id,kind,description,total_cents,my_share_cents,person,occurred_on,matched_txn")
    since = (datetime.now().date() - timedelta(days=400)).isoformat()
    rows = rest().select("transactions", user_id=f"eq.{user_id}", occurred_at=f"gte.{since}", select="id,amount_cents,occurred_at,merchant_raw,merchant_clean,category_rule_id,user_edited")
    cat = rest().select("categories", user_id=f"eq.{user_id}", name="eq.Splitwise", select="id")
    n = 0
    for m in match(ev, rows):
        patch = {"note": m["note"]}
        if m["kind"] == "expense":
            patch["shared_cents"] = m["shared_cents"]
        elif cat:
            patch["category_id"] = cat[0]["id"]
        rest().update("transactions", {"id": m["txn"], "user_id": user_id}, patch)
        rest().update("splitwise_events", {"id": m["event"], "user_id": user_id}, {"matched_txn": m["txn"], "covers": m.get("covers") or []})
        n += 1
    return n

def likely(rows: list[dict], types: dict[str, str], friends: list[str], rejected: set[str]) -> list[dict]:
    """Source B. Person-to-person money with someone I share expenses with, and shared-looking charges a friend later paid back. Rows a rule claimed are left alone."""
    out = []
    free = [r for r in rows if not r.get("category_rule_id") and r["id"] not in rejected and r.get("cat_name") != "Splitwise" and "category" not in (r.get("user_edited") or [])]
    for r in free:
        text = r.get("merchant_raw") or r.get("merchant_clean") or ""
        if r["amount_cents"] < 0 and not is_purchase(r, types) and r.get("flow") is None or is_person_credit(r, types):
            who = next((f for f in friends if name_score(f, text)), None)
            if who:
                out.append({"txn_id": r["id"], "label": f"Zelle with {who.split(' ')[0]}", "cents": abs(r["amount_cents"]), "confidence": 0.8, "reason": "friend"})
    for s in suggest([r for r in free if r.get("cat_name") in ("Restaurants", "Groceries", "Travel") or is_person_credit(r, types)], types, set()):
        c = s["candidates"][0]
        out.append({"txn_id": c["purchase_id"], "label": c["merchant"], "cents": c["amount_cents"], "confidence": 0.7, "reason": "paid_back"})
    return sorted({o["txn_id"]: o for o in out}.values(), key=lambda o: -o["confidence"])[:5]

@router.get("/splitwise/likely")
def likely_route(user_id: str = Depends(current_user)):
    user_limiter.check(f"swl:{user_id}", 30, 60)
    since = (datetime.now().date() - timedelta(days=60)).isoformat()
    rows = rest().select("transactions", user_id=f"eq.{user_id}", occurred_at=f"gte.{since}", select="id,account_id,amount_cents,occurred_at,merchant_raw,merchant_clean,flow,reimbursed_cents,category_rule_id,user_edited,category_id")
    cats = {c["id"]: c["name"] for c in rest().select("categories", user_id=f"eq.{user_id}", select="id,name")}
    for r in rows:
        r["cat_name"] = cats.get(r.get("category_id"))
    types = {a["id"]: a["type"] for a in rest().select("accounts", user_id=f"eq.{user_id}", select="id,type")}
    mine = [m["group_id"] for m in rest().select("tally_members", member_user_id=f"eq.{user_id}", status="eq.active", select="group_id")]
    friends = [m["name"] for m in rest().select("tally_members", group_id=f"in.({','.join(mine)})", select="name,member_user_id") if m.get("member_user_id") != user_id and m.get("name")] if mine else []
    rejected = {e["matched_txn"] for e in rest().select("splitwise_events", user_id=f"eq.{user_id}", kind="eq.rejected", select="matched_txn,description") if not e.get("description")}
    return {"suggestions": likely(rows, types, sorted(set(friends)), rejected)}

class AnswerBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    txn_id: str
    yes: bool

@router.post("/splitwise/answer")
def answer(body: AnswerBody, user_id: str = Depends(current_user)):
    """Yes: this row is Splitwise, and so is other money with this person outside any rent rule. No: never ask about this row again."""
    user_limiter.check(f"swl-w:{user_id}", 30, 60)
    if not re.fullmatch(r"[0-9a-f\-]{36}", body.txn_id):
        raise HTTPException(404, "not found")
    row = rest().select("transactions", id=f"eq.{body.txn_id}", user_id=f"eq.{user_id}", select="id,merchant_raw,merchant_clean,user_edited")
    if not row:
        raise HTTPException(404, "not found")
    if not body.yes:
        rest().insert("splitwise_events", {"user_id": user_id, "kind": "rejected", "matched_txn": body.txn_id}, returning=False)
        return {"saved": True}
    cat = rest().select("categories", user_id=f"eq.{user_id}", name="eq.Splitwise", select="id")
    if not cat:
        raise HTTPException(404, "not found")
    rest().update("transactions", {"id": body.txn_id, "user_id": user_id}, {"category_id": cat[0]["id"], "user_edited": sorted({*(row[0].get("user_edited") or []), "category"})})
    who = payer_name(row[0].get("merchant_raw") or "")
    if who:
        key = who.lower()
        rest().insert("category_rules", {"user_id": user_id, "person_key": key, "display_name": who, "category_id": cat[0]["id"], "priority": 10, "source": "suggested"}, returning=False)
        rest().insert("ask_memory", {"user_id": user_id, "kind": "alias", "key": key.split(" ")[0], "value": {"person": key.split(" ")[0]}}, upsert_on="user_id,kind,key")
    return {"saved": True}
