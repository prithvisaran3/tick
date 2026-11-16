"""Paycheck splits: one net pay across several accounts. The same arithmetic as SQL `pay_split_amounts` and Dart `splitAmounts`
(vectors: tests/data/pay_splits.json). Fixed lines first in order, then percents of the whole net, and the one "rest" line takes what is left."""
from __future__ import annotations

from .db import rest

def split_amounts(net: int, splits: list[dict]) -> list[int]:
    left = max(net, 0)
    out = [0] * len(splits)
    for i, s in enumerate(splits):
        if s["kind"] == "fixed":
            out[i] = min(int(s["value"]), left); left -= out[i]
    for i, s in enumerate(splits):
        if s["kind"] == "percent":
            out[i] = min(max(net, 0) * int(s["value"]) // 10000, left); left -= out[i]
    for i, s in enumerate(splits):
        if s["kind"] == "rest":
            out[i] = left; left = 0
    return out

def load(user_id: str, r=None) -> list[dict]:
    """[r]: the caller's own database handle, so one request (and one test) uses one."""
    return (r or rest()).select("pay_splits", user_id=f"eq.{user_id}", select="id,account_id,label,mask,kind,value,sort", order="sort.asc")

def per_account(net: int, splits: list[dict]) -> list[tuple[dict, int]]:
    """(line, cents) for every line that gets money."""
    return [(s, c) for s, c in zip(splits, split_amounts(net, splits)) if c > 0]

def from_deposits(deposits: list[dict], accounts: list[dict]) -> list[dict]:
    """A statement's deposit lines as splits: the biggest line takes the rest, the others are fixed. Lines are tied to my accounts by the last digits."""
    if len(deposits) < 1:
        return []
    big = max(range(len(deposits)), key=lambda i: deposits[i]["cents"])
    out = []
    for i, d in enumerate(deposits):
        acct = next((a for a in accounts if d.get("mask") and a.get("mask") and str(a["mask"])[-len(str(d["mask"])):] == str(d["mask"])[-len(str(a["mask"])):] and a.get("type") in ("checking", "savings")), None)
        out.append({"account_id": acct["id"] if acct else None, "label": None if acct else (d.get("label") or "Other account")[:60], "mask": d.get("mask"),
                    "kind": "rest" if i == big else "fixed", "value": 0 if i == big else int(d["cents"])})
    return out
