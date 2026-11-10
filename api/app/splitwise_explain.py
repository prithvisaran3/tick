"""What a Splitwise row most likely was. Three places can say: a Splitwise email (only once Gmail is connected), a Tally expense, or an open Tally balance.
Each answer carries a confidence; "Not this one" hides that one answer for that row and nothing else. A Zelle to a friend also lists the expenses it could settle.
Nothing here writes money: tags and rejections live in splitwise_events."""
from __future__ import annotations

import re
from datetime import date, datetime, timedelta

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, ConfigDict

from .auth import current_user, user_limiter
from .db import rest
from .paybacks import ET, UUID, name_score, payer_name
from .tally import simplify

router = APIRouter()
NEAR_DAYS = 3
SETTLE_LOOKBACK = 90

def _d(v) -> date:
    if isinstance(v, date) and not isinstance(v, datetime):
        return v
    s = str(v)
    if len(s) == 10:
        return date.fromisoformat(s)
    return datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone(ET).date()

def _text(t: dict) -> str:
    return t.get("merchant_raw") or t.get("merchant_clean") or ""

def person_of(t: dict) -> str | None:
    """The friend on a Zelle/Venmo line, or None for a card purchase."""
    text = _text(t)
    return payer_name(text) if re.search(r"zelle|venmo|cash ?app|paypal", text, re.I) else None

def _near(conf_close: float, conf_far: float, days: int) -> float:
    return conf_close if days <= 1 else conf_far

def explain(txn: dict, events: list[dict], expenses: list[dict], balances: list[dict], tag: dict | None, rejected: set[str]) -> list[dict]:
    """Candidates, most likely first. [expenses]: {id, group_id, group_name, description, amount_cents, spent_on, paid_by_me, paid_by_name, my_share_cents, transaction_id}.
    [balances]: {group_id, group_name, name, cents} with cents > 0 = they owe me, < 0 = I owe them."""
    amt, on, who = txn["amount_cents"], _d(txn["occurred_at"]), person_of(txn)
    cents = abs(amt)
    out: list[dict] = []
    for e in expenses:
        days = abs((_d(e["spent_on"]) - on).days)
        if e.get("transaction_id") == txn["id"]:
            out.append(_c("tally", e["id"], e["description"], e["group_name"], e["amount_cents"], e["spent_on"], 0.97, e["group_id"], None))
        elif who is None and amt < 0 and e["paid_by_me"] and e["amount_cents"] == cents and days <= NEAR_DAYS:
            out.append(_c("tally", e["id"], e["description"], e["group_name"], e["amount_cents"], e["spent_on"], _near(0.9, 0.75, days), e["group_id"], None))
        elif who and amt < 0 and not e["paid_by_me"] and e["my_share_cents"] == cents and name_score(e.get("paid_by_name"), who) and 0 <= (on - _d(e["spent_on"])).days <= 30:
            out.append(_c("tally", e["id"], e["description"], e["group_name"], cents, e["spent_on"], 0.7, e["group_id"], e.get("paid_by_name")))
    for v in events:
        if v["kind"] not in ("expense", "settle_out", "settle_in") or not v.get("total_cents"):
            continue
        days = abs((_d(v["occurred_on"]) - on).days)
        if v["kind"] == "expense" and who is None and amt < 0 and v["total_cents"] == cents and days <= NEAR_DAYS:
            out.append(_c("splitwise", v["id"], v.get("description") or "Splitwise expense", "From Splitwise email", cents, v["occurred_on"], _near(0.92, 0.78, days), None, None))
        elif v["kind"] == ("settle_out" if amt < 0 else "settle_in") and v["total_cents"] == cents and days <= 5 and (not who or name_score(v.get("person"), who)):
            out.append(_c("splitwise", v["id"], f"Settle up with {v.get('person') or 'a friend'}", "From Splitwise email", cents, v["occurred_on"], _near(0.92, 0.8, days), None, v.get("person")))
    if who:
        for b in balances:
            if not name_score(b["name"], who) or (amt < 0) != (b["cents"] < 0):
                continue
            owed = abs(b["cents"])
            if cents > owed:
                continue
            label = f"You owed {b['name'].split(' ')[0]}" if amt < 0 else f"{b['name'].split(' ')[0]} owed you"
            out.append(_c("balance", f"bal:{b['group_id']}:{b['name'].lower()}", label, b["group_name"], owed, None, 0.85 if owed == cents else 0.6, b["group_id"], b["name"]))
    if tag:
        for c in out:
            hit = (tag.get("group_id") and c["group_id"] == tag["group_id"]) or (tag.get("person") and c["person"] and name_score(tag["person"], c["person"]))
            c["confidence"] = round(min(0.97, c["confidence"] + 0.05) if hit else c["confidence"] * 0.6, 2)
    best: dict[str, dict] = {}
    for c in out:
        if c["ref"] not in rejected and (c["ref"] not in best or best[c["ref"]]["confidence"] < c["confidence"]):
            best[c["ref"]] = c
    return sorted(best.values(), key=lambda c: (-c["confidence"], c["ref"]))

def _c(source, ref, label, where, cents, on, conf, group_id, person) -> dict:
    return {"source": source, "ref": str(ref), "label": label, "where": where, "cents": cents, "date": str(on) if on else None, "confidence": conf, "group_id": group_id, "person": person}

def could_settle(txn: dict, expenses: list[dict]) -> dict | None:
    """A Zelle to a friend: the expenses they paid that my share of could be settling, newest first. Exact when the newest run adds up to the amount."""
    who = person_of(txn)
    if not who or txn["amount_cents"] >= 0:
        return None
    on, cents = _d(txn["occurred_at"]), -txn["amount_cents"]
    mine = [e for e in expenses if not e["paid_by_me"] and e["my_share_cents"] > 0 and name_score(e.get("paid_by_name"), who) and 0 <= (on - _d(e["spent_on"])).days <= SETTLE_LOOKBACK]
    mine.sort(key=lambda e: (str(e["spent_on"]), e["id"]), reverse=True)
    if not mine:
        return None
    run = 0
    for i, e in enumerate(mine):
        run += e["my_share_cents"]
        if run == cents:
            return {"person": who, "exact": True, "total_cents": run, "items": [_item(x) for x in mine[: i + 1]]}
        if run > cents:
            break
    pick = mine[:5]
    return {"person": who, "exact": False, "total_cents": sum(e["my_share_cents"] for e in pick), "items": [_item(x) for x in pick]}

def _item(e: dict) -> dict:
    return {"id": e["id"], "label": e["description"], "group_name": e["group_name"], "cents": e["my_share_cents"], "date": str(e["spent_on"])}

# ---------- loading ----------

def _tally(user_id: str, around: date) -> tuple[list[dict], list[dict], list[dict], list[dict]]:
    """My groups, their members, recent expenses with my share, and every open balance between me and someone."""
    mine = rest().select("tally_members", member_user_id=f"eq.{user_id}", status="eq.active", select="id,group_id")
    if not mine:
        return [], [], [], []
    me = {m["group_id"]: m["id"] for m in mine}
    ids = ",".join(sorted(me))
    groups = rest().select("tally_groups", id=f"in.({ids})", deleted_at="is.null", select="id,name")
    names = {g["id"]: g["name"] for g in groups}
    members = rest().select("tally_members", group_id=f"in.({ids})", select="id,group_id,name,member_user_id,status")
    who = {m["id"]: m.get("name") or "Someone" for m in members}
    since, until = (around - timedelta(days=SETTLE_LOOKBACK + 5)).isoformat(), (around + timedelta(days=NEAR_DAYS + 1)).isoformat()
    ex = rest().select("tally_expenses", group_id=f"in.({ids})", deleted_at="is.null", spent_on=f"gte.{since}", select="id,group_id,description,amount_cents,spent_on,paid_by_member,transaction_id")
    ex = [e for e in ex if str(e["spent_on"]) <= until]
    shares = rest().select("tally_shares", expense_id=f"in.({','.join(e['id'] for e in ex)})", select="expense_id,member_id,owed_cents") if ex else []
    expenses = []
    for e in ex:
        my = me.get(e["group_id"])
        expenses.append({"id": e["id"], "group_id": e["group_id"], "group_name": names.get(e["group_id"], "Tally"), "description": e["description"], "amount_cents": e["amount_cents"],
                         "spent_on": e["spent_on"], "paid_by_me": e["paid_by_member"] == my, "paid_by_name": who.get(e["paid_by_member"]), "transaction_id": e.get("transaction_id"),
                         "my_share_cents": sum(s["owed_cents"] for s in shares if s["expense_id"] == e["id"] and s["member_id"] == my)})
    nets: dict[str, dict] = {}
    for r in rest().rpc("tally_balances", {"p_uid": user_id, "p_group": None}) or []:
        nets.setdefault(r["group_id"], {})[r["member_id"]] = int(r["net_cents"])
    balances = []
    for gid, net in nets.items():
        for frm, to, c in simplify(net):
            if to == me.get(gid):
                balances.append({"group_id": gid, "group_name": names.get(gid, "Tally"), "name": who.get(frm, "Someone"), "cents": c})
            elif frm == me.get(gid):
                balances.append({"group_id": gid, "group_name": names.get(gid, "Tally"), "name": who.get(to, "Someone"), "cents": -c})
    friends = sorted({(m["name"]) for m in members if m.get("member_user_id") != user_id and m.get("status", "active") == "active" and m.get("name")})
    return groups, friends, expenses, balances

def _row(user_id: str, txn_id: str) -> dict:
    if not UUID.fullmatch(txn_id or ""):
        raise HTTPException(404, "not found")
    row = rest().select("transactions", id=f"eq.{txn_id}", user_id=f"eq.{user_id}", select="id,amount_cents,occurred_at,merchant_raw,merchant_clean")
    if not row:
        raise HTTPException(404, "not found")
    return row[0]

@router.get("/splitwise/explain/{txn_id}")
def explain_route(txn_id: str, user_id: str = Depends(current_user)):
    user_limiter.check(f"swx:{user_id}", 60, 60)
    t = _row(user_id, txn_id)
    ev = rest().select("splitwise_events", user_id=f"eq.{user_id}", select="id,kind,description,total_cents,person,occurred_on,matched_txn,group_id,gmail_id")
    tag = next((e for e in ev if e["kind"] == "tag" and e.get("matched_txn") == txn_id), None)
    rejected = {e["description"] for e in ev if e["kind"] == "rejected" and e.get("matched_txn") == txn_id and e.get("description")}
    groups, _, expenses, balances = _tally(user_id, _d(t["occurred_at"]))
    cands = explain(t, [e for e in ev if e.get("gmail_id")], expenses, balances, tag and {"group_id": tag.get("group_id"), "person": tag.get("person")}, rejected)
    tag_label = None
    if tag:
        tag_label = tag.get("person") or next((g["name"] for g in groups if g["id"] == tag.get("group_id")), None)
    return {"gmail_connected": any(e.get("gmail_id") for e in ev), "tag": tag_label, "best": cands[0] if cands else None, "more": len(cands) - 1 if cands else 0,
            "could_settle": could_settle(t, expenses)}

@router.get("/splitwise/options")
def options_route(user_id: str = Depends(current_user)):
    """Who a Splitwise row could be with: my Tally groups and the friends in them."""
    user_limiter.check(f"swo:{user_id}", 60, 60)
    groups, friends, _, _ = _tally(user_id, datetime.now(ET).date())
    return {"groups": [{"id": g["id"], "name": g["name"]} for g in sorted(groups, key=lambda g: g["name"].lower())], "friends": friends}

class TagBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    txn_id: str
    group_id: str | None = None
    person: str | None = None

@router.post("/splitwise/tag")
def tag_route(body: TagBody, user_id: str = Depends(current_user)):
    """Which group or friend this Splitwise row was with. One tag per row; sending neither clears it."""
    user_limiter.check(f"swt:{user_id}", 30, 60)
    _row(user_id, body.txn_id)
    if body.group_id is not None:
        if not UUID.fullmatch(body.group_id) or not rest().select("tally_members", group_id=f"eq.{body.group_id}", member_user_id=f"eq.{user_id}", status="eq.active", select="id"):
            raise HTTPException(404, "not found")
    person = (body.person or "").strip()[:80] or None
    rest().delete("splitwise_events", {"user_id": user_id, "kind": "tag", "matched_txn": body.txn_id})
    if body.group_id or person:
        rest().insert("splitwise_events", {"user_id": user_id, "kind": "tag", "matched_txn": body.txn_id, "group_id": body.group_id, "person": person}, returning=False)
    return {"saved": True}

class NotBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    txn_id: str
    ref: str

@router.post("/splitwise/not")
def not_route(body: NotBody, user_id: str = Depends(current_user)):
    """"Not this one": that explanation never shows for this row again. The next most likely takes its place."""
    user_limiter.check(f"swn:{user_id}", 30, 60)
    _row(user_id, body.txn_id)
    if not re.fullmatch(r"[\w:.\- ]{1,120}", body.ref):
        raise HTTPException(422, "bad ref")
    rest().insert("splitwise_events", {"user_id": user_id, "kind": "rejected", "matched_txn": body.txn_id, "description": body.ref}, returning=False)
    return {"saved": True}
