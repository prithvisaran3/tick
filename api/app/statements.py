"""Statement files from any of my banks -> rows Tick can import. Detects the source from the file itself (never from what the user says):
Apple Card, Chase (checking and card), Bank of America (checking and card), Discover, Capital One, SoFi, OFX/QFX, and a generic CSV with a
column mapping. Pure parsing here; routes and database writes are in imports.py. Amounts leave this module in Tick's sign (negative = out).

Dates are statement dates without a time, stored at noon Eastern (like Plaid posting dates). Every row gets a stable ref (file content, not
file name), so re-importing the same file, or an overlapping one, never duplicates a row."""
from __future__ import annotations

import csv
import hashlib
import io
import re
from dataclasses import dataclass, field
from datetime import date, datetime

from . import applecard as AC
from .applecard import Row

MAX_BYTES = 5_000_000
MAX_ROWS = 20_000

class StatementError(ValueError):
    """A file Tick can't read; the message is safe to show."""

@dataclass
class Parsed:
    source: str                                  # apple_card | chase_checking | chase_card | bofa_checking | bofa_card | discover | capital_one | sofi | ofx | generic
    label: str                                   # "Apple Card statement"
    rows: list[Row] = field(default_factory=list)
    unreadable: int = 0
    kind: str | None = None                      # 'credit' | 'cash' (which kind of Tick account this belongs on)
    institution: str | None = None
    mask: str | None = None                      # last four of the account, when the file says (OFX)
    needs_mapping: dict | None = None            # generic CSV: {"columns": [...], "sample": [[...]]}

def _norm(h: str) -> str:
    return re.sub(r"[^a-z]", "", h.lower())

def _amount(s: str) -> int:
    s = (s or "").strip().replace("$", "").replace(",", "").replace(" ", "")
    if not s:
        raise ValueError("empty")
    neg = (s.startswith("(") and s.endswith(")")) or s.endswith("-") or s.startswith("-")
    v = round(abs(float(s.strip("()-+"))) * 100)
    return -v if neg else v

def _date(s: str) -> date:
    s = (s or "").strip()
    for fmt in ("%m/%d/%Y", "%Y-%m-%d", "%m/%d/%y", "%d-%b-%Y", "%b %d, %Y", "%Y/%m/%d", "%m-%d-%Y"):
        try:
            return datetime.strptime(s, fmt).date()
        except ValueError:
            pass
    raise ValueError(s)

def _decode(raw: bytes) -> str:
    if len(raw) > MAX_BYTES:
        raise StatementError("That file is too big for one statement.")
    order = ("utf-16", "utf-8-sig", "cp1252") if raw[:2] in (b"\xff\xfe", b"\xfe\xff") else ("utf-8-sig", "cp1252")
    for enc in order:
        try:
            return raw.decode(enc)
        except (UnicodeDecodeError, UnicodeError):
            continue
    raise StatementError("That doesn't look like a statement Tick can read.")

def _ref(source: str, key: str, n: int) -> str:
    return f"stmt:{source}:" + hashlib.sha256(f"{key}|{n}".encode()).hexdigest()[:24]

SIGNATURES: list[tuple[str, set[str]]] = [
    ("apple_card", {"transactiondate", "clearingdate", "description", "merchant", "category", "type", "amountusd"}),
    ("capital_one", {"transactiondate", "posteddate", "cardno", "description", "category", "debit", "credit"}),
    ("chase_checking", {"details", "postingdate", "description", "amount", "type", "balance"}),
    ("chase_card", {"transactiondate", "postdate", "description", "category", "type", "amount"}),
    ("bofa_card", {"posteddate", "referencenumber", "payee", "address", "amount"}),
    ("bofa_checking", {"date", "description", "amount", "runningbal"}),
    ("discover", {"transdate", "postdate", "description", "amount", "category"}),
    ("sofi", {"date", "description", "type", "amount", "currentbalance", "status"}),
]
LABELS = {"apple_card": "Apple Card statement", "capital_one": "Capital One statement", "chase_checking": "Chase checking statement", "chase_card": "Chase card statement",
          "bofa_card": "Bank of America card statement", "bofa_checking": "Bank of America checking statement", "discover": "Discover statement", "sofi": "SoFi statement",
          "ofx": "Bank statement (OFX)", "generic": "CSV statement"}
INSTITUTION = {"apple_card": "Apple Card", "capital_one": "Capital One", "chase_checking": "Chase", "chase_card": "Chase", "bofa_card": "Bank of America",
               "bofa_checking": "Bank of America", "discover": "Discover", "sofi": "SoFi"}
KIND = {"apple_card": "credit", "capital_one": "credit", "chase_card": "credit", "bofa_card": "credit", "discover": "credit", "chase_checking": "cash", "bofa_checking": "cash", "sofi": "cash"}

def detect(header: list[str]) -> str | None:
    h = {_norm(x) for x in header}
    for name, sig in SIGNATURES:
        if sig <= h:
            return name
    return None

def _find_header(lines: list[list[str]]) -> int | None:
    """Some banks put a summary above the real header (Bank of America checking). The header is the first row that matches a signature."""
    for i, row in enumerate(lines[:40]):
        if detect(row):
            return i
    return None

def parse_csv(text: str, mapping: dict | None = None) -> Parsed:
    lines = [r for r in csv.reader(io.StringIO(text))]
    if not lines:
        raise StatementError("That file is empty.")
    hi = _find_header(lines)
    if hi is None:
        if mapping:
            return _parse_generic(lines, mapping)
        # No known bank: ask for a column mapping from the first row that looks like a header (the one with the most non-empty cells).
        idx = max(range(min(len(lines), 15)), key=lambda i: sum(1 for c in lines[i] if c.strip()))
        cols = [c.strip() for c in lines[idx]]
        if len([c for c in cols if c]) < 2:
            raise StatementError("That doesn't look like a CSV statement.")
        return Parsed("generic", LABELS["generic"], needs_mapping={"columns": cols, "header_row": idx, "sample": [r[:len(cols)] for r in lines[idx + 1: idx + 4]]})
    source = detect(lines[hi])
    assert source
    header = [_norm(c) for c in lines[hi]]
    ix = {h: i for i, h in enumerate(header)}
    out = Parsed(source, LABELS[source], kind=KIND[source], institution=INSTITUTION[source])
    seen: dict[str, int] = {}
    for rec in lines[hi + 1:]:
        if not any(c.strip() for c in rec):
            continue
        if len(out.rows) >= MAX_ROWS:
            raise StatementError("That file has more rows than one statement.")
        get = lambda k: rec[ix[k]].strip() if k in ix and ix[k] < len(rec) else ""
        try:
            row = _row(source, get)
        except (ValueError, IndexError, KeyError):
            out.unreadable += 1
            continue
        if row is None:
            continue
        seen[row.ref] = seen.get(row.ref, 0) + 1
        row.ref = _ref(source, row.ref, seen[row.ref])
        out.rows.append(row)
    return out

def _row(source: str, get) -> Row | None:
    if source == "apple_card":
        when, amount, typ, desc = _date(get("transactiondate")), _amount(get("amountusd")), get("type").lower(), get("description")[:200]
        merchant = (get("merchant") or desc)[:120]
        kind = "payment" if "payment" in typ else "credit" if "credit" in typ or typ in ("return", "refund") else "interest" if "interest" in typ else "purchase"
        cat = "Transfer" if kind == "payment" else "Fees and interest" if kind == "interest" else AC._CATEGORY.get(get("category").lower())
        return Row(when, merchant, desc, cat, kind, -amount, f"{when}|{desc}|{amount}|{typ}") if amount else None
    if source in ("chase_checking",):
        when, amount, desc = _date(get("postingdate")), _amount(get("amount")), get("description")[:200]
        return Row(when, desc, desc, None, "other", amount, f"{when}|{desc}|{amount}") if amount else None
    if source in ("chase_card",):
        when, amount, desc = _date(get("transactiondate")), _amount(get("amount")), get("description")[:200]
        kind = "payment" if get("type").lower() == "payment" else "credit" if amount > 0 else "purchase"
        return Row(when, desc, desc, "Transfer" if kind == "payment" else None, kind, amount, f"{when}|{desc}|{amount}")  if amount else None
    if source == "bofa_checking":
        when, amount, desc = _date(get("date")), _amount(get("amount")), get("description")[:200]
        return Row(when, desc, desc, None, "other", amount, f"{when}|{desc}|{amount}") if amount else None
    if source == "bofa_card":
        when, amount, desc = _date(get("posteddate")), _amount(get("amount")), (get("payee") or "")[:200]
        kind = "payment" if amount > 0 and re.search(r"payment|thank you", desc, re.I) else "credit" if amount > 0 else "purchase"
        return Row(when, desc, desc, "Transfer" if kind == "payment" else None, kind, amount, f"{when}|{desc}|{amount}|{get('referencenumber')}") if amount else None
    if source == "discover":
        when, amount, desc = _date(get("transdate")), _amount(get("amount")), get("description")[:200]
        kind = "payment" if amount < 0 and re.search(r"direct ?pay|payment|thank you|autopay", desc, re.I) else "credit" if amount < 0 else "purchase"
        return Row(when, desc, desc, "Transfer" if kind == "payment" else None, kind, -amount, f"{when}|{desc}|{amount}") if amount else None
    if source == "capital_one":
        when, desc = _date(get("transactiondate")), get("description")[:200]
        debit, credit = (_amount(get("debit")) if get("debit") else 0), (_amount(get("credit")) if get("credit") else 0)
        amount = credit - debit
        kind = "payment" if credit and re.search(r"payment|pmt", desc, re.I) else "credit" if credit else "purchase"
        return Row(when, desc, desc, "Transfer" if kind == "payment" else None, kind, amount, f"{when}|{desc}|{amount}|{get('cardno')}") if amount else None
    if source == "sofi":
        when, amount, desc = _date(get("date")), _amount(get("amount")), get("description")[:200]
        if get("status").lower() in ("pending",) and False:
            return None
        return Row(when, desc, desc, None, "other", amount, f"{when}|{desc}|{amount}|{get('type')}") if amount else None
    return None

def _parse_generic(lines: list[list[str]], m: dict) -> Parsed:
    """mapping: {"header_row": 0, "date": col, "description": col, "amount": col | null, "debit": col, "credit": col, "negative_is_out": true}"""
    hr = int(m.get("header_row", 0))
    cols = [c.strip() for c in lines[hr]]
    def at(name):
        return cols.index(m[name]) if m.get(name) in cols else None
    d, desc, amt, deb, cre = at("date"), at("description"), at("amount"), at("debit"), at("credit")
    if d is None or desc is None or (amt is None and deb is None and cre is None):
        raise StatementError("Pick the date, description and amount columns.")
    out = Parsed("generic", LABELS["generic"])
    seen: dict[str, int] = {}
    flip = not m.get("negative_is_out", True)
    for rec in lines[hr + 1:]:
        if not any(c.strip() for c in rec):
            continue
        try:
            when = _date(rec[d])
            if amt is not None:
                a = _amount(rec[amt]); a = -a if flip else a
            else:
                a = (_amount(rec[cre]) if cre is not None and rec[cre].strip() else 0) - (_amount(rec[deb]) if deb is not None and rec[deb].strip() else 0)
            text = rec[desc].strip()[:200]
        except (ValueError, IndexError):
            out.unreadable += 1
            continue
        if a == 0:
            continue
        key = f"{when}|{text}|{a}"
        seen[key] = seen.get(key, 0) + 1
        out.rows.append(Row(when, text, text, None, "other", a, _ref("generic", key, seen[key])))
    return out

_TAG = lambda tag, s: (re.search(rf"<{tag}>([^<\r\n]*)", s, re.I) or [None, ""])[1].strip()

def parse_ofx(text: str) -> Parsed:
    if "<STMTTRN>" not in text.upper():
        raise StatementError("That OFX file has no transactions.")
    credit = "<CCSTMTRS>" in text.upper() or "<CREDITCARDMSGSRSV1>" in text.upper()
    acct = _TAG("ACCTID", text)
    out = Parsed("ofx", LABELS["ofx"], kind="credit" if credit else "cash", mask=acct[-4:] if len(acct) >= 4 else None)
    seen: dict[str, int] = {}
    for block in re.findall(r"<STMTTRN>(.*?)(?=</STMTTRN>|<STMTTRN>|</BANKTRANLIST>|</CCSTMTRS>|$)", text, re.I | re.S):
        try:
            when = datetime.strptime(_TAG("DTPOSTED", block)[:8], "%Y%m%d").date()
            amount = _amount(_TAG("TRNAMT", block))
            name = (_TAG("NAME", block) or _TAG("MEMO", block))[:200]
            fitid = _TAG("FITID", block)
        except (ValueError, IndexError):
            out.unreadable += 1
            continue
        if amount == 0:
            continue
        key = f"{fitid}|{when}|{amount}"
        seen[key] = seen.get(key, 0) + 1
        kind = "payment" if _TAG("TRNTYPE", block).upper() in ("PAYMENT",) and credit and amount > 0 else "other"
        out.rows.append(Row(when, name, name, "Transfer" if kind == "payment" else None, kind, amount, _ref("ofx", key, seen[key])))
    return out

def parse_statement(raw: bytes, filename: str = "", mapping: dict | None = None) -> Parsed:
    text = _decode(raw)
    head = text[:4000].upper()
    if "OFXHEADER" in head or "<OFX>" in head or filename.lower().endswith((".ofx", ".qfx", ".qbo")):
        return parse_ofx(text)
    if text.lstrip().startswith("%PDF"):
        raise StatementError("PDF statements aren't supported yet. Export a CSV or OFX file from your bank instead.")
    return parse_csv(text, mapping)


def plan(rows: list[Row], existing: list[dict], imported_refs: set[str], account_id: str | None) -> AC.Plan:
    """De-duplicate against everything already in Tick: earlier imports (stable refs), Plaid rows, and live Wallet / SMS captures.
    A row is a duplicate when an existing row on this account (or with no account) has the same amount, a date within 2 days and a similar
    merchant; a live capture (no Plaid id) on the same account within one day also counts even if its merchant name is missing."""
    cand = []
    for e in existing:
        if e.get("account_id") not in (account_id, None):
            continue
        srcs = {x.get("source") for x in (e.get("sources") or [])}
        capture_only = bool(srcs) and "plaid" not in srcs and not any(str(x).startswith(("statement", "applecard")) for x in srcs)
        cand.append({**e, "_apple_card": bool(account_id) and e.get("account_id") == account_id and capture_only})
    return AC.plan_import(rows, cand, imported_refs)
