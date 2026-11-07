"""Splitwise group export -> a Tally group. Pure parsing here; the route is in imports.py, the atomic write in SQL (tally_import_splitwise).

The file: Date, Description, Category, Cost, Currency, then one column per member holding that member's NET for the row (positive = they paid
more than their share). A last "Total balance" row repeats the totals and is ignored. This shape is ASSUMED from the export as documented;
no real sample was available (docs/TALLY_V2.md). A row with one positive member is that member's expense. A row with several (multi-payer) is
stored as one expense per payer, which keeps every balance exact. Category "Payment" rows are settlements."""
from __future__ import annotations

import csv
import hashlib
import io
from dataclasses import dataclass, field
from datetime import date

from .statements import StatementError, _amount, _date, _decode, _norm

FIXED = ["date", "description", "category", "cost", "currency"]

@dataclass
class Item:
    ref: str
    when: date
    description: str
    category: str | None
    cost_cents: int
    nets: dict[str, int]
    payment: bool = False

@dataclass
class Export:
    members: list[str]
    items: list[Item] = field(default_factory=list)
    unreadable: int = 0
    balances: dict[str, int] = field(default_factory=dict)

def looks_like(raw: bytes) -> bool:
    try:
        first = next((r for r in csv.reader(io.StringIO(_decode(raw)[:4000])) if any(c.strip() for c in r)), [])
    except (StatementError, csv.Error):
        return False
    return [_norm(c) for c in first[:5]] == FIXED and len(first) >= 7

def parse(raw: bytes) -> Export:
    lines = [r for r in csv.reader(io.StringIO(_decode(raw))) if any(c.strip() for c in r)]
    members = [c.strip() for c in lines[0][5:] if c.strip()]
    if len(members) < 2 or len(set(members)) != len(members):
        raise StatementError("That Splitwise file doesn't list its members clearly.")
    out = Export(members)
    seen: dict[str, int] = {}
    for r in lines[1:]:
        if (r[1] if len(r) > 1 else "").strip().lower() == "total balance":
            continue
        try:
            when, desc, cost = _date(r[0]), r[1].strip()[:120] or "Expense", _amount(r[3])
            if (r[4] or "USD").strip().upper() != "USD":
                raise ValueError("currency")
            nets = {m: _amount(r[5 + i] if 5 + i < len(r) else "0") for i, m in enumerate(members)}
        except (ValueError, IndexError):
            out.unreadable += 1
            continue
        if abs(sum(nets.values())) > len(members):          # a cent or so of rounding per member is normal, more means a broken row
            out.unreadable += 1
            continue
        nets = _balance(nets)
        key = f"{when}|{desc}|{cost}|{sorted(nets.items())}"
        seen[key] = seen.get(key, 0) + 1
        ref = "splitwise:" + hashlib.sha256(f"{key}|{seen[key]}".encode()).hexdigest()[:24]
        cat = (r[2] or "").strip()
        if any(nets.values()):
            out.items.append(Item(ref, when, desc, cat or None, cost, nets, payment=cat.lower() == "payment"))
    for it in out.items:
        for m, c in it.nets.items():
            out.balances[m] = out.balances.get(m, 0) + c
    return out

def _balance(nets: dict[str, int]) -> dict[str, int]:
    """Rows must net to exactly zero; any rounding cent goes to the largest absolute member."""
    d = sum(nets.values())
    if d:
        big = max(nets, key=lambda m: (abs(nets[m]), m))
        nets = {**nets, big: nets[big] - d}
    return nets

def expenses_of(it: Item) -> list[dict]:
    """Expenses for one row: [{payer, amount_cents, shares: {member: owed}}]."""
    cred = sorted(((m, c) for m, c in it.nets.items() if c > 0), key=lambda x: (-x[1], x[0]))
    debt = sorted(((m, -c) for m, c in it.nets.items() if c < 0), key=lambda x: (-x[1], x[0]))
    if len(cred) == 1:
        payer, net = cred[0]
        amount = max(it.cost_cents, net)
        shares = {m: c for m, c in debt}
        if amount > net:
            shares[payer] = amount - net
        return [{"payer": payer, "amount_cents": amount, "shares": shares}]
    left = [list(x) for x in debt]
    out = []
    for payer, net in cred:
        need, shares = net, {}
        for d in left:
            take = min(need, d[1])
            if take:
                shares[d[0]] = take; d[1] -= take; need -= take
        out.append({"payer": payer, "amount_cents": net, "shares": shares})
    return out

def settlements_of(it: Item) -> list[dict]:
    """A payment row: the payer's column is positive (they paid out), the receiver's negative."""
    cred = [(m, c) for m, c in it.nets.items() if c > 0]
    debt = [(m, -c) for m, c in it.nets.items() if c < 0]
    if len(cred) == 1 and len(debt) == 1:
        return [{"from": cred[0][0], "to": debt[0][0], "amount_cents": cred[0][1]}]
    return [{"from": e["payer"], "to": m, "amount_cents": c} for e in expenses_of(it) for m, c in e["shares"].items() if m != e["payer"]]

def payload(ex: Export, me: str, group_name: str, skip_refs: set[str]) -> dict:
    """What tally_import_splitwise writes. `me` becomes null in the person columns."""
    who = lambda m: None if m == me else m
    exp, stl = [], []
    for it in ex.items:
        if it.ref in skip_refs:
            continue
        if it.payment:
            for i, s in enumerate(settlements_of(it)):
                stl.append({"ref": f"{it.ref}:{i}", "from": who(s["from"]), "to": who(s["to"]), "amount_cents": s["amount_cents"], "on": it.when.isoformat()})
        else:
            for i, e in enumerate(expenses_of(it)):
                exp.append({"ref": f"{it.ref}:{i}", "description": it.description, "category": it.category, "spent_on": it.when.isoformat(), "amount_cents": e["amount_cents"],
                            "paid_by": who(e["payer"]), "shares": [{"person": who(m), "owed_cents": c} for m, c in sorted(e["shares"].items())]})
    return {"group": {"name": group_name[:60] or "Splitwise", "import_key": import_key(ex)}, "people": [m for m in ex.members if m != me], "expenses": exp, "settlements": stl}

def import_key(ex: Export) -> str:
    return "splitwise:" + hashlib.sha256("|".join(sorted(m.lower() for m in ex.members)).encode()).hexdigest()[:24]

def guess_me(members: list[str], display_name: str | None) -> str | None:
    words = {w.lower() for w in (display_name or "").split()}
    hits = [m for m in members if {w.lower() for w in m.split()} & words]
    return hits[0] if len(hits) == 1 else None
