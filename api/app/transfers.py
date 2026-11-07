"""Internal transfers: money moving between my own accounts is neither spending nor income.

A checking "payment to card", "payment to loan" or "transfer to another of my accounts" is paired with its counterpart on the other
account: same total, counterpart within PAIR_DAYS after (or one day before, banks post in different orders). One payment may cover
several cards (up to three counterparts summing to the payment). Both sides of a card or account-to-account transfer get
flow='transfer'. A LOAN payment keeps flow='bill' on the checking side (it is real cash out, counted as a bill, never as discretionary
spending); the loan's "payment received" side is a transfer.

Unmatched payments: a card payment with no linked counterpart (Apple Card is never on Plaid) is STILL a transfer, because that card's
purchases are tracked one by one (Wallet capture, CSV import); counting the payment too would double count. An unmatched loan payment
stays a bill. A generic unmatched transfer (e.g. Zelle to a friend) is left alone.

Cross-institution transfers: Chase "SoFi Bank TRANSFER" and SoFi "JPMORGAN CHASE BANK, NA" are the same move of money. Two cash accounts of mine,
opposite amounts, within -1 to +5 days, and name evidence (one side names the other's bank, either side names ME, or both say "transfer")
pair up and BOTH sides are excluded. Zelle and other person-to-person money is NOT a transfer: "Zelle payment to Kaarthik" is real money
out unless a matching row on my own account exists. Unmatched P2P rows are labelled "Friends and family".

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
        return None                                             # Zelle to a friend is real money; pass 2 pairs it only with evidence it is mine
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

_P2P_WORDS = re.compile(r"\b(zelle|venmo|cash ?app|cashapp|paypal|apple cash)\b", re.I)
_INSTS = {
    "chase": re.compile(r"\b(jpmorgan|jp ?morgan|jpm|chase)\b", re.I),
    "sofi": re.compile(r"\bsofi\b", re.I),
    "boa": re.compile(r"\b(bank of america|bofa|boa|bk of amer\w*|bankamerica)\b", re.I),
    "discover": re.compile(r"\bdiscover\b", re.I),
    "capone": re.compile(r"\b(capital ?one|cap one|capone)\b", re.I),
    "apple": re.compile(r"\b(apple ?card|applecard|goldman|gs bank)\b", re.I),
}

def is_p2p(text: str) -> bool:
    return bool(_P2P_WORDS.search(text or ""))

_RENT = re.compile(r"\brent\b", re.I)

def p2p_category(text: str) -> str:
    """Zelle to a landlord is rent, real spending. Everything else person-to-person is money with friends (MONEY_RULES.md)."""
    return "Rent" if _RENT.search(text or "") else "Friends and family"

def inst_keys(text: str | None) -> set[str]:
    return {k for k, rx in _INSTS.items() if rx.search(text or "")}

def mentions_me(text: str, my_names: set[str]) -> bool:
    """My own name in a bank description ("Zelle payment from Prithvi Saran", "...TRANSFER PSathyasaran" where the first initial is glued on)."""
    words = re.findall(r"[a-z]{5,}", (text or "").lower())
    for w in words:
        for n in my_names:
            if len(n) < 5:
                continue
            if w == n or w.startswith(n) or (len(n) >= 7 and n in w) or (len(w) >= 7 and w in n):
                return True
    return False

def name_tokens(display_name: str | None, extra: str = "") -> set[str]:
    return {t for t in re.findall(r"[a-z]{5,}", f"{display_name or ''} {extra}".lower())}

def pair(rows: list[Row], acct_types: dict[str, str], acct_inst: dict[str, str] | None = None, my_names: set[str] | None = None) -> dict[str, dict]:
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
        else:
            # An ordinary own-account transfer lands in cash: it must never take a card or loan payment credit (that credit belongs to the card payment).
            pool = [i for i in pool if acct_types.get(i.account_id or "") not in ("credit", "loan")]
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

    # ---- pass 2: cash <-> cash across institutions (Chase "SoFi Bank TRANSFER" <-> SoFi "JPMORGAN CHASE BANK, NA", Zelle to myself) ----
    inst = acct_inst or {}
    names = my_names or set()
    cash = lambda r: acct_types.get(r.account_id or "") in CASH
    def evidence(o: Row, i: Row) -> bool:
        ko, ki = inst.get(o.account_id or ""), inst.get(i.account_id or "")
        if ki and ki in inst_keys(o.merchant) and ki != ko:
            return True                                                     # "...SOFI BANK TRANSFER" leaving Chase for SoFi
        if ko and ko in inst_keys(i.merchant) and ko != ki:
            return True                                                     # "JPMORGAN CHASE BANK, NA" arriving from Chase
        if mentions_me(o.merchant, names) or mentions_me(i.merchant, names):
            return True                                                     # "Zelle ... Prithvi": it is my own name
        return bool(_TRANSFER.search(o.merchant) and _TRANSFER.search(i.merchant))
    open_outs = sorted((r for r in rows if r.amount_cents < 0 and cash(r) and not r.edited and not r.pair and r.id not in patches and r.id not in used),
                       key=lambda r: (r.occurred_at, r.id))
    open_ins = [r for r in rows if r.amount_cents > 0 and cash(r) and not r.edited and not r.pair and r.id not in patches and r.id not in used]
    for o in open_outs:
        if o.id in used:
            continue
        want = -o.amount_cents
        cands = [i for i in open_ins if i.id not in used and i.account_id != o.account_id and i.amount_cents == want and _near(o, i) and evidence(o, i)]
        if cands:
            best = min(cands, key=lambda i: (abs((i.occurred_at - o.occurred_at).total_seconds()), i.id))
            used.add(best.id); used.add(o.id)
            patches[o.id] = {"flow": "transfer", "transfer_pair_id": o.id}
            patches[best.id] = {"flow": "transfer", "transfer_pair_id": o.id}

    # ---- pass 3: money to or from MY OWN name with no counterpart (an unlinked account of mine): still not spending or income ----
    for r in rows:
        if cash(r) and not r.edited and not r.pair and r.id not in patches and r.flow is None and is_p2p(r.merchant) and mentions_me(r.merchant, names):
            patches[r.id] = {"flow": "transfer"}
    return patches
