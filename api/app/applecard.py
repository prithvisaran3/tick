"""Apple Card statement import (Wallet -> Apple Card -> Statements -> Export Transactions -> CSV).

Apple Card is not on Plaid and FinanceKit needs an Apple entitlement, so Tick gets Apple Card purchases two ways:
live from the Wallet "Transaction" Shortcuts automation (card = "Apple Card"), and from this CSV. The CSV never creates a second copy of
a purchase that was already captured live: a row is skipped when an existing transaction has the same amount, a similar merchant and a
date within +/-2 days. Re-importing the same file is a no-op (external_ref is unique per row).

Apple's CSV columns: Transaction Date, Clearing Date, Description, Merchant, Category, Type, Amount (USD), Purchased By.
Amount is positive for purchases and negative for payments and credits. Dates are MM/DD/YYYY."""
from __future__ import annotations

import csv
import hashlib
import io
import re
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone

from zoneinfo import ZoneInfo

from .merchants import categorize, clean_merchant, similarity

ET = ZoneInfo("America/New_York")

MAX_BYTES = 2_000_000
MAX_ROWS = 5000
MATCH_DAYS = 2
APPLE_CARD_ACCOUNT_REF = "manual:apple-card"           # provider_account_id of the one Apple Card account per user

# Apple's categories -> Tick's default categories (anything else falls back to Tick's own merchant rules).
_CATEGORY = {"restaurants": "Restaurants", "grocery": "Groceries", "groceries": "Groceries", "transportation": "Rideshare", "airlines": "Travel",
             "hotels": "Travel", "travel": "Travel", "shopping": "Shopping", "entertainment": "Fun", "medical": "Health", "health": "Health",
             "utilities": "Utilities", "gas": "Travel", "other": None, "alcohol": "Restaurants"}

class ImportError_(ValueError):
    """A file Tick can't read. The message is safe to show."""

@dataclass
class Row:
    when: date
    merchant: str
    description: str
    category: str | None              # Tick category name, or None = use Tick's merchant rules
    kind: str                         # purchase | payment | credit | interest | fee | other
    amount_cents: int                 # Tick sign: negative = money out
    ref: str                          # stable per row: re-importing the same file never duplicates

@dataclass
class Plan:
    inserts: list[Row] = field(default_factory=list)
    duplicates: list[tuple[Row, str]] = field(default_factory=list)   # (row, id of the live capture it matched)
    already_imported: int = 0
    unreadable: int = 0

def _norm(h: str) -> str:
    return re.sub(r"[^a-z]", "", h.lower())

def _amount(s: str) -> int:
    s = s.strip().replace("$", "").replace(",", "")
    neg = s.startswith("(") and s.endswith(")")
    v = round(float(s.strip("()")) * 100)
    return -v if neg else v

def _date(s: str) -> date:
    s = s.strip()
    for fmt in ("%m/%d/%Y", "%Y-%m-%d", "%m/%d/%y"):
        try:
            return datetime.strptime(s, fmt).date()
        except ValueError:
            pass
    raise ValueError(s)

def parse(raw: bytes) -> tuple[list[Row], int]:
    """(rows, unreadable count). Raises ImportError_ for a file that isn't an Apple Card export."""
    if len(raw) > MAX_BYTES:
        raise ImportError_("That file is too big for one statement.")
    try:
        text = raw.decode("utf-8-sig")
    except UnicodeDecodeError:
        raise ImportError_("That doesn't look like an Apple Card CSV.")
    reader = csv.reader(io.StringIO(text))
    try:
        header = [_norm(h) for h in next(reader)]
    except StopIteration:
        raise ImportError_("That file is empty.")
    need = {"transactiondate", "description", "type", "amountusd"}
    if not need <= set(header):
        raise ImportError_("That doesn't look like an Apple Card CSV. Export it from Wallet, Apple Card, Statements.")
    ix = {h: i for i, h in enumerate(header)}
    rows: list[Row] = []
    bad = 0
    seen: dict[str, int] = {}
    for n, rec in enumerate(reader):
        if n >= MAX_ROWS:
            raise ImportError_("That file has more rows than one statement.")
        if not any(c.strip() for c in rec):
            continue
        try:
            get = lambda k: rec[ix[k]].strip() if k in ix and ix[k] < len(rec) else ""
            when = _date(get("transactiondate"))
            amount = _amount(get("amountusd"))
            typ = get("type").lower()
            desc = get("description")[:200]
            merchant = (get("merchant") or clean_merchant(desc))[:120]
            apple_cat = get("category").lower()
        except (ValueError, KeyError, IndexError):
            bad += 1
            continue
        if amount == 0:
            continue
        kind = ("payment" if "payment" in typ else "credit" if typ in ("credit", "return", "refund") or "credit" in typ
                else "interest" if "interest" in typ else "fee" if "fee" in typ else "purchase" if typ in ("purchase", "installment", "debit") else "other")
        cents = -amount                                   # Apple: + = purchase (money out); Tick: - = money out
        if kind == "payment":
            cat = "Transfer"
        elif kind in ("interest", "fee") or apple_cat in ("interest", "fees"):
            cat = "Fees and interest"
        else:
            cat = _CATEGORY.get(apple_cat)
        key = f"{when.isoformat()}|{desc}|{amount}|{typ}"
        seen[key] = seen.get(key, 0) + 1                  # two identical coffees on one day are two purchases
        ref = "applecard:" + hashlib.sha256(f"{key}|{seen[key]}".encode()).hexdigest()[:24]
        rows.append(Row(when, merchant or desc, desc, cat, kind, cents, ref))
    return rows, bad

def _dt(s) -> datetime:
    return s if isinstance(s, datetime) else datetime.fromisoformat(str(s).replace("Z", "+00:00"))

def plan_import(rows: list[Row], existing: list[dict], imported_refs: set[str]) -> Plan:
    """Decide insert vs skip for each row. [existing] = the user's transactions around the file's dates (dicts as stored).
    Each live capture can absorb at most one CSV row."""
    out = Plan()
    used: set[str] = set()
    for r in rows:
        if r.ref in imported_refs:
            out.already_imported += 1
            continue
        best = None
        for e in existing:
            if e["id"] in used or int(e["amount_cents"]) != r.amount_cents:
                continue
            d = abs((_dt(e["occurred_at"]).astimezone(ET).date() - r.when).days)
            if d > MATCH_DAYS:
                continue
            name = e.get("merchant_clean") or e.get("merchant_raw") or ""
            sim = max(similarity(r.merchant, name), similarity(r.description, name)) if name else 0.0
            same_card = e.get("_apple_card", False)
            # Same amount within 2 days, and either the merchant looks the same or it was captured on the Apple Card itself.
            if sim >= 0.5 or (same_card and d <= 1):
                score = (sim, -d)
                if best is None or score > best[0]:
                    best = (score, e)
        if best:
            used.add(best[1]["id"])
            out.duplicates.append((r, best[1]["id"]))
        else:
            out.inserts.append(r)
    return out

def row_fields(r: Row, account_id: str | None, name_to_id: dict[str, str], rules: dict[str, str]) -> dict:
    cat = r.category
    if cat is None:
        cat, _ = categorize(r.merchant or r.description, rules)
        # a refund keeps the merchant's category: it lowers that category's spending and is never Income
    tags = ["refund"] if r.kind == "credit" else []
    at = datetime(r.when.year, r.when.month, r.when.day, 17, tzinfo=timezone.utc)   # noon Eastern: CSV dates have no time
    return {"amount_cents": r.amount_cents, "occurred_at": at.isoformat(), "merchant_raw": r.description or r.merchant, "merchant_clean": r.merchant,
            "category_id": name_to_id.get(cat), "account_id": account_id, "status": "posted", "confidence": 1.0, "needs_review": False,
            "tags": tags, "flow": "transfer" if r.kind == "payment" else None, "external_ref": r.ref,
            "sources": [{"source": "applecard_csv", "ref": r.ref, "amount_cents": r.amount_cents, "status": "posted", "at": at.isoformat()}]}
