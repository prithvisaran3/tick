"""Internal transfers: money moving between my own accounts is neither spending nor income.

A checking "payment to card", "payment to loan" or "transfer to another of my accounts" is paired with its counterpart on the other
account: same total, counterpart within PAIR_DAYS after (or one day before, banks post in different orders). One payment may cover
several cards (up to three counterparts summing to the payment). Both sides of a card or account-to-account transfer get
flow='transfer'. A LOAN payment keeps flow='bill' on the checking side (it is real cash out, counted as a bill, never as discretionary
spending); the loan's "payment received" side is a transfer.

Unmatched payments: a card payment with no linked counterpart (Apple Card is never on Plaid) is STILL a transfer, because that card's
purchases are tracked one by one (Wallet capture, CSV import); counting the payment too would double count. An unmatched loan payment
stays a bill. A generic unmatched transfer (e.g. Zelle to a friend) is left alone.

Pure functions; tests in tests/test_transfers.py. Rows are dicts as stored (amount_cents negative = out)."""
from __future__ import annotations

import itertools
import re
from dataclasses import dataclass
from datetime import datetime, timedelta

PAIR_DAYS = 5
CASH = {"checking", "savings", "cash"}
_PAYMENT = re.compile(r"\b(payment|pymt|pmt|autopay|auto pay|epay|e-payment|thank you)\b", re.I)
_TRANSFER = re.compile(r"\b(transfer|xfer|trnsfr|online banking transfer|to savings|from checking|to checking|from savings)\b", re.I)

@dataclass
class Row:
    id: str
    account_id: str | None
    amount_cents: int
    occurred_at: datetime
    merchant: str
    flow: str | None
    category: str | None            # category name
    pair: str | None
    edited: bool = False             # the person changed the flow by hand: never touch it

def _dt(s) -> datetime:
    return s if isinstance(s, datetime) else datetime.fromisoformat(str(s).replace("Z", "+00:00"))

def rows_from_db(raw: list[dict], cat_names: dict[str, str]) -> list[Row]:
    return [Row(r["id"], r.get("account_id"), int(r["amount_cents"]), _dt(r["occurred_at"]), r.get("merchant_clean") or r.get("merchant_raw") or "",
                r.get("flow"), cat_names.get(r.get("category_id") or ""), r.get("transfer_pair_id"), "flow" in (r.get("user_edited") or []))
            for r in raw]

_P2P = re.compile(r"\b(zelle|venmo|cash app|cashapp|paypal)\b", re.I)
_CARD = re.compile(r"\b(discover|capital one|capone|bank of america|bk of amer|boa|bofa|chase card|citi|amex|american express|apple ?card|gs bank|goldman|crd|card)\b", re.I)

def _out_kind(r: Row, acct_type: str | None) -> str | None:
    """What an outgoing cash-account row is: 'loan' | 'card' | 'transfer' | None (an ordinary purchase)."""
    if r.amount_cents >= 0 or acct_type not in CASH or r.edited:
        return None
    m = r.merchant
    if r.flow == "bill" or r.category == "Loan payment":
        return "loan"
    if _P2P.search(m):
        return "transfer"                                       # Zelle to a friend is only internal if my own account received it
    if _PAYMENT.search(m) and not _TRANSFER.search(m):
        return "card"
    if r.flow == "transfer" or r.category == "Transfer" or _TRANSFER.search(m):
        return "transfer"
    return None

def _sure_card_payment(r: Row) -> bool:
    """Unmatched rows are only called card payments on strong evidence (the bank said so, or issuer + payment wording)."""
    return r.flow == "transfer" or (bool(_PAYMENT.search(r.merchant)) and bool(_CARD.search(r.merchant)))

def _in_ok(r: Row, acct_type: str | None) -> bool:
    """Could this incoming row be the other side of one of my transfers?"""
    if r.amount_cents <= 0 or r.edited or r.pair:
        return False
    if acct_type in ("credit", "loan"):
        # Card/loan side: a payment, never a refund of a purchase.
        return r.flow == "transfer" or r.category == "Transfer" or bool(_PAYMENT.search(r.merchant))
    return r.flow == "transfer" or r.category == "Transfer" or bool(_TRANSFER.search(r.merchant))

def _near(out: Row, inn: Row) -> bool:
    d = inn.occurred_at - out.occurred_at
    return timedelta(days=-1) <= d <= timedelta(days=PAIR_DAYS)

def pair(rows: list[Row], acct_types: dict[str, str]) -> dict[str, dict]:
    """Returns {row_id: patch} with flow / transfer_pair_id for every row that should change. Deterministic: outgoing rows are processed
    oldest first, and each picks the closest-in-time exact counterpart, else the closest-in-time 2- or 3-row combination."""
    patches: dict[str, dict] = {}
    used: set[str] = {r.id for r in rows if r.pair}
    outs = sorted((r for r in rows if not r.edited and not r.pair and _out_kind(r, acct_types.get(r.account_id or "")) is not None),
                  key=lambda r: (r.occurred_at, r.id))
    ins = [r for r in rows if _in_ok(r, acct_types.get(r.account_id or ""))]
    for o in outs:
        kind = _out_kind(o, acct_types.get(o.account_id or ""))
        want = -o.amount_cents
        pool = [i for i in ins if i.id not in used and i.account_id != o.account_id and _near(o, i)]
        if kind == "loan":
            pool = [i for i in pool if acct_types.get(i.account_id or "") == "loan"]
        elif kind == "card":
            pool = [i for i in pool if acct_types.get(i.account_id or "") in ("credit", "loan")]
        dist = lambda i: abs((i.occurred_at - o.occurred_at).total_seconds())
        match: list[Row] = []
        exact = sorted((i for i in pool if i.amount_cents == want), key=lambda i: (dist(i), i.id))
        if exact:
            match = [exact[0]]
        elif kind in ("card", "loan"):
            # One payment covering several cards: the smallest-spread combination of 2-3 payments received that sums exactly.
            cands = sorted(pool, key=lambda i: (dist(i), i.id))[:12]
            best = None
            for n in (2, 3):
                for combo in itertools.combinations(cands, n):
                    if sum(i.amount_cents for i in combo) == want and len({i.account_id for i in combo}) == n:
                        score = sum(dist(i) for i in combo)
                        if best is None or score < best[0]:
                            best = (score, list(combo))
                if best:
                    break
            match = best[1] if best else []
        out_flow = "bill" if kind == "loan" else "transfer"
        if match:
            for i in match:
                used.add(i.id)
                patches[i.id] = {"flow": "transfer", "transfer_pair_id": o.id}
            patches[o.id] = {"flow": out_flow, "transfer_pair_id": o.id}
        elif kind == "loan" and o.flow != "bill":
            patches[o.id] = {"flow": "bill"}                     # unmatched loan payment: still a bill
        elif kind == "card" and o.flow != "transfer" and _sure_card_payment(o):
            patches[o.id] = {"flow": "transfer"}                 # unmatched card payment (e.g. Apple Card): still not spending
    return patches
