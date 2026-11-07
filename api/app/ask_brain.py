"""Ask Tick's brain. The model never does arithmetic or date maths: dates come from `parse_range`, numbers from typed tools over the SQL money rules
(ask_rows), and sentences from templates. A question is routed cheapest first: rules, the learned matcher, the phone's model, a cloud model. Whichever path
picks the tool, the same tool computes the number. Nothing here touches the database, so all of it is testable on a plain Ledger."""
from __future__ import annotations

import calendar
import math
import re
from collections import Counter
from dataclasses import dataclass, field
from datetime import date, timedelta
from typing import Callable

MONTHS = {m.lower(): i for i, m in enumerate(calendar.month_name) if m} | {m.lower(): i for i, m in enumerate(calendar.month_abbr) if m}

@dataclass
class Range:
    start: date
    end: date           # inclusive
    label: str
    explicit: bool = True

    def has(self, d: date) -> bool:
        return self.start <= d <= self.end
    def text(self) -> str:
        return f"{self.start:%b} {self.start.day} to {self.end:%b} {self.end.day}" if self.start != self.end else f"{self.start:%b} {self.start.day}"

@dataclass
class Ledger:
    txns: list[dict]                     # {id, merchant, amount_cents, out_cents, in_cents, date, category, tags, person}
    today: date
    recurring: list[dict] = field(default_factory=list)   # {merchant, cadence, expected_cents, next_date}
    accounts: list[dict] = field(default_factory=list)    # {name, type, balance_cents, available_cents, statement_balance_cents, due_date, include_in_safe}
    goals_cents: int = 0
    period: dict | None = None            # {period_start, period_end, next_payday}
    prev_period: dict | None = None
    paycheck_cents: int = 0
    balances: list[dict] = field(default_factory=list)    # {name, group, cents} positive = they owe me
    people: list[str] = field(default_factory=list)       # names Tick knows: Tally people, rule names, aliases
    category_ids: dict[str, str] = field(default_factory=dict)

# ---------------- dates ----------------
def _month_end(y: int, m: int) -> date:
    return date(y, m, calendar.monthrange(y, m)[1])

def _shift_month(d: date, n: int) -> date:
    t = d.year * 12 + d.month - 1 + n
    return date(t // 12, t % 12 + 1, 1)

def parse_range(q: str, today: date, period: dict | None = None, prev_period: dict | None = None) -> Range:
    """Every date Ask Tick uses comes from here. No phrase means this month, marked not explicit."""
    s = q.lower()
    first = today.replace(day=1)
    def r(a: date, b: date, label: str) -> Range:
        return Range(a, min(b, today) if b >= a else b, label)
    if period and re.search(r"\bsince (my |the )?(last )?pay ?(day|check)\b|\bthis pay ?period\b|\bcurrent pay ?period\b", s):
        return r(period["period_start"], period["period_end"], "this pay period")
    if prev_period and re.search(r"\b(last|previous) pay ?(period|check|day)\b", s):
        return r(prev_period["period_start"], prev_period["period_end"], "last pay period")
    if re.search(r"\byesterday\b", s):
        y = today - timedelta(days=1)
        return r(y, y, "yesterday")
    if re.search(r"\btoday\b", s):
        return r(today, today, "today")
    m = re.search(r"\b(?:last|past|previous) (\d{1,3}) (day|week|month)s?\b", s)
    if m:
        n = int(m.group(1))
        if m.group(2) == "month":
            return r(_shift_month(first, -n), today, f"last {n} months")
        return r(today - timedelta(days=n * (7 if m.group(2) == "week" else 1) - 1), today, f"last {n} {m.group(2)}s")
    monday = today - timedelta(days=today.weekday())
    if re.search(r"\bthis week\b", s):
        return r(monday, today, "this week")
    if re.search(r"\b(last|previous) week\b", s):
        return r(monday - timedelta(days=7), monday - timedelta(days=1), "last week")
    if re.search(r"\b(this|current) month\b|\bso far\b|\bmtd\b", s):
        return r(first, today, "this month")
    if re.search(r"\b(last|previous) month\b", s):
        a = _shift_month(first, -1)
        return r(a, first - timedelta(days=1), "last month")
    if re.search(r"\b(this|current) year\b|\bytd\b|\byear to date\b", s):
        return r(date(today.year, 1, 1), today, "this year")
    if re.search(r"\blast year\b", s):
        return r(date(today.year - 1, 1, 1), date(today.year - 1, 12, 31), "last year")
    names = "|".join(sorted(MONTHS, key=len, reverse=True))
    m = re.search(rf"\bsince (?:the start of )?({names})\b", s)
    if m:
        mo = MONTHS[m.group(1)]
        y = today.year if mo <= today.month else today.year - 1
        return r(date(y, mo, 1), today, f"since {calendar.month_name[mo]}")
    m = re.search(rf"\b(?:in|for|during|of|from)? ?({names})\.? ?(20\d\d)?\b", s) if re.search(rf"\b({names})\b", s.replace("may i", "")) else None
    if m:
        mo = MONTHS[m.group(1)]
        y = int(m.group(2)) if m.group(2) else (today.year if mo <= today.month else today.year - 1)
        return r(date(y, mo, 1), _month_end(y, mo), f"{calendar.month_name[mo]} {y}" if m.group(2) else calendar.month_name[mo])
    return Range(first, today, "this month", explicit=False)

# ---------------- money words ----------------
def money(c: int) -> str:
    c = abs(int(c))
    return f"${c // 100:,}" if c % 100 == 0 else f"${c / 100:,.2f}"

SYNONYMS = {"eating out": ["Restaurants", "Food delivery"], "restaurants": ["Restaurants", "Food delivery"], "dining": ["Restaurants", "Food delivery"], "takeout": ["Restaurants", "Food delivery"],
            "food": ["Groceries", "Restaurants", "Coffee", "Food delivery"], "groceries": ["Groceries"], "coffee": ["Coffee"], "rent": ["Rent"], "uber": ["Rideshare"], "rides": ["Rideshare"], "rideshare": ["Rideshare"],
            "subscriptions": ["Subscriptions"], "travel": ["Travel"], "shopping": ["Shopping"], "software": ["Software"], "utilities": ["Utilities"], "fun": ["Fun"], "health": ["Health"],
            "fees": ["Fees and interest"], "interest": ["Fees and interest"], "friends": ["Friends and family"], "splitwise": ["Splitwise"]}

def _has(phrase: str, s: str) -> bool:
    return re.search(rf"\b{re.escape(phrase)}s?\b", s) is not None

@dataclass
class Slots:
    range: Range
    categories: list[str] = field(default_factory=list)
    not_categories: list[str] = field(default_factory=list)
    merchant: str | None = None
    person: str | None = None
    amount: int | None = None
    other_range: Range | None = None

def _cats(s: str, l: Ledger, aliases: dict) -> list[str]:
    known = {c.lower(): c for c in l.category_ids}
    for k, v in aliases.items():
        if v.get("categories") and _has(k, s):
            return v["categories"]
    for k, v in sorted(SYNONYMS.items(), key=lambda kv: -len(kv[0])):
        if _has(k, s):
            return v
    for lower, name in known.items():
        if _has(lower, s):
            return [name]
    return []

def extract(q: str, l: Ledger, aliases: dict | None = None) -> Slots:
    aliases = aliases or {}
    s = q.lower()
    out = Slots(parse_range(q, l.today, l.period, l.prev_period))
    m = re.search(r"(?:that wasn'?t|that isn'?t|not|excluding|except|other than|apart from|besides) ([a-z ]+?)(?:\?|$|,| this| last| in )", s)
    if m:
        out.not_categories = _cats(m.group(1), l, aliases)
        if out.not_categories:
            s = s.replace(m.group(0), " ")
    out.categories = _cats(s, l, aliases)
    for k, v in aliases.items():
        if v.get("person") and _has(k, s):
            out.person = v["person"]
    if out.person is None:
        for name in sorted(l.people, key=len, reverse=True):
            words = [w for w in name.lower().split() if len(w) >= 2]
            if words and any(_has(w, s) for w in words):
                out.person = words[0]
                break
    if out.person is None and re.search(r"\b(sent|send|paid|pay|zelle[d]?|venmo[ed]*|to) ([a-z]{3,})\b", s):
        w = re.search(r"\b(?:sent|send|paid|pay|zelle[d]?|venmo[ed]*|to) ([a-z]{3,})\b", s).group(1)
        if any(w in (t.get("person") or "").split() for t in l.txns):
            out.person = w
    seen = {t["merchant"] for t in l.txns if t.get("merchant") and not t.get("person")}
    for name in sorted(seen, key=len, reverse=True):
        n = name.lower()
        if len(n) >= 3 and (_has(n, s) or _has(n.split()[0], s) and len(n.split()[0]) >= 4):
            out.merchant = name
            break
    m = re.search(r"\$ ?(\d[\d,]*(?:\.\d{1,2})?)|\b(\d{2,}(?:\.\d{1,2})?)\b(?! days| weeks| months)", s)
    if m:
        out.amount = round(float((m.group(1) or m.group(2)).replace(",", "")) * 100)
    m = re.search(r"\b(?:vs\.?|versus|compared (?:to|with)|than) (.+)$", s)
    if m:
        other = parse_range(m.group(1), l.today, l.period, l.prev_period)
        if other.explicit:
            out.other_range = other
            head = parse_range(s[:m.start()], l.today, l.period, l.prev_period)
            out.range = head
    return out

# ---------------- tools ----------------
@dataclass
class Result:
    text: str
    numbers: dict
    range: Range | None = None
    see: dict | None = None        # the Activity filter for exactly these rows

def _see(l: Ledger, r: Range, cats: list[str] | None = None, query: str | None = None, not_cats: list[str] | None = None) -> dict:
    ids = [l.category_ids[c] for c in (cats or []) if c in l.category_ids]
    if not_cats:
        ids = [i for n, i in l.category_ids.items() if n not in not_cats] if not ids else [i for i in ids]
    return {"from": r.start.isoformat(), "to": r.end.isoformat(), "categories": ids, "query": query or ""}

def _in(l: Ledger, r: Range, cats=None, merchant=None, person=None, not_cats=None) -> list[dict]:
    return [t for t in l.txns if r.has(t["date"]) and (not cats or t.get("category") in cats) and (not not_cats or t.get("category") not in not_cats)
            and (not merchant or merchant.lower() in (t.get("merchant") or "").lower()) and (not person or person in (t.get("person") or "").split())]

def _raw(cats: list[str] | None, person: str | None) -> bool:
    """Money with friends is out of the totals, but "how much did I send Kaarthik" still has an answer: what left the account."""
    return bool(person) or bool(cats) and all(c in ("Friends and family", "Splitwise") for c in cats)

def _word(cats, merchant, person, not_cats) -> str:
    if person:
        return f"sent to {person.capitalize()}" + (f", not counting {', '.join(not_cats)}" if not_cats else "")
    if merchant:
        return f"at {merchant}"
    if cats:
        return f"on {', '.join(cats)}"
    return "spent"

class Tools:
    """Typed tools. Each answers from the classified rows and says the range it used."""
    def __init__(self, l: Ledger):
        self.l = l

    def spend_summary(self, s: Slots, kind: str = "out") -> Result:
        l, r = self.l, s.range
        rows = _in(l, r, s.categories, s.merchant, s.person, s.not_categories)
        if kind == "in":
            total = sum(t.get("in_cents", 0) for t in rows)
            return Result(f"{money(total)} came in.", {"cents": total, "count": sum(1 for t in rows if t.get("in_cents"))}, r, _see(l, r))
        raw = _raw(s.categories, s.person)
        hits = [t for t in rows if (t["amount_cents"] < 0 if raw else t.get("out_cents", 0) != 0)]
        total = sum(-t["amount_cents"] if raw else t["out_cents"] for t in hits)
        return Result(f"{money(total)} {_word(s.categories, s.merchant, s.person, s.not_categories)}.", {"cents": total, "count": len(hits)}, r, _see(l, r, s.categories, s.merchant or s.person, s.not_categories))

    def category_breakdown(self, s: Slots) -> Result:
        by: Counter = Counter()
        for t in _in(self.l, s.range):
            by[t.get("category") or "Other"] += t.get("out_cents", 0)
        top = [(k, v) for k, v in by.most_common() if v > 0]
        if not top:
            return Result("$0 spent.", {"cents": 0}, s.range, _see(self.l, s.range))
        return Result(f"{money(top[0][1])} on {top[0][0]}, your biggest category." + "".join(f" {k} {money(v)}." for k, v in top[1:3]), {"cents": top[0][1], "total_cents": sum(v for _, v in top), "category": top[0][0]}, s.range, _see(self.l, s.range))

    def top_merchants(self, s: Slots) -> Result:
        by: Counter = Counter()
        for t in _in(self.l, s.range):
            if t.get("out_cents", 0) > 0:
                by[t["merchant"]] += t["out_cents"]
        top = by.most_common(3)
        if not top:
            return Result("$0 spent.", {"cents": 0}, s.range, _see(self.l, s.range))
        return Result(f"{money(top[0][1])} at {top[0][0]}, your top merchant." + "".join(f" {k} {money(v)}." for k, v in top[1:]), {"cents": top[0][1], "merchant": top[0][0]}, s.range, _see(self.l, s.range))

    def compare_periods(self, s: Slots) -> Result:
        l = self.l
        a = s.range if s.range.explicit else Range(l.today.replace(day=1), l.today, "this month")
        b = s.other_range or Range(_shift_month(a.start.replace(day=1), -1), a.start.replace(day=1) - timedelta(days=1), "last month")
        tot = lambda r: sum(t.get("out_cents", 0) for t in _in(l, r, s.categories, s.merchant, None, s.not_categories))
        x, y = tot(a), tot(b)
        d = x - y
        word = "more" if d > 0 else "less"
        return Result(f"{money(abs(d))} {word} {a.label} than {b.label}: {money(x)} vs {money(y)}." if d else f"The same: {money(x)} in both.", {"cents": x, "other_cents": y, "diff_cents": d}, a, _see(l, a, s.categories, s.merchant))

    def balance_now(self, s: Slots) -> Result:
        accts = [a for a in self.l.accounts if a.get("balance_cents") is not None]
        name = (s.merchant or "").lower()
        cash = [a for a in accts if a["type"] in ("checking", "savings", "cash")]
        hit = [a for a in accts if name and name in a["name"].lower()] or cash
        total = sum(a["balance_cents"] for a in hit)
        return Result(f"{money(total)} across {len(hit)} {'account' if len(hit) == 1 else 'accounts'}.", {"cents": total, "count": len(hit)})

    def upcoming_bills(self, s: Slots, days: int = 7) -> Result:
        l = self.l
        end = l.today + timedelta(days=days)
        items = sorted((r for r in l.recurring if l.today <= r["next_date"] <= end), key=lambda r: r["next_date"])
        total = sum(r["expected_cents"] for r in items)
        if not items:
            return Result(f"$0 due in the next {days} days.", {"cents": 0, "count": 0})
        return Result(f"{money(total)} due in the next {days} days: " + ", ".join(f"{r['merchant']} {money(r['expected_cents'])}" for r in items[:4]) + ".", {"cents": total, "count": len(items)})

    def subscriptions(self, s: Slots) -> Result:
        per = {"weekly": 52 / 12, "biweekly": 26 / 12, "monthly": 1, "yearly": 1 / 12}
        total = round(sum(r["expected_cents"] * per.get(r.get("cadence"), 1) for r in self.l.recurring))
        return Result(f"{money(total)} a month across {len(self.l.recurring)} recurring charges.", {"cents": total, "count": len(self.l.recurring)})

    def _safe(self) -> tuple[int, date | None]:
        l = self.l
        pay = l.period["next_payday"] if l.period else None
        cash = sum((a.get("available_cents") if a.get("available_cents") is not None else a.get("balance_cents") or 0) for a in l.accounts if a["type"] in ("checking", "cash") and a.get("include_in_safe", True))
        end = pay or l.today + timedelta(days=14)
        bills = sum(r["expected_cents"] for r in l.recurring if l.today <= r["next_date"] < end)
        cards = sum(a.get("statement_balance_cents") or 0 for a in l.accounts if a["type"] == "credit" and a.get("due_date") and a["due_date"] <= end)
        return cash - bills - cards - l.goals_cents, pay

    def safe_to_spend(self, s: Slots) -> Result:
        v, pay = self._safe()
        return Result(f"{money(v)} safe to spend" + (f" until {pay:%A}." if pay else ".") if v >= 0 else f"{money(v)} past safe to spend.", {"cents": v})

    def payday_info(self, s: Slots) -> Result:
        l = self.l
        if not l.period:
            return Result("No payday set yet. Add it in Settings.", {})
        p = l.period
        days = (p["next_payday"] - l.today).days
        return Result(f"{days} {'day' if days == 1 else 'days'} until payday, {p['next_payday']:%A %b} {p['next_payday'].day}. This period is {p['period_start']:%b} {p['period_start'].day} to {p['period_end']:%b} {p['period_end'].day}.", {"days": days})

    def tally_balances(self, s: Slots) -> Result:
        rows = [b for b in self.l.balances if not s.person or s.person in b["name"].lower()]
        owed = sum(b["cents"] for b in rows if b["cents"] > 0)
        owe = -sum(b["cents"] for b in rows if b["cents"] < 0)
        if s.person and rows:
            n = sum(b["cents"] for b in rows)
            return Result(f"{s.person.capitalize()} owes you {money(n)}." if n > 0 else f"You owe {s.person.capitalize()} {money(n)}." if n < 0 else f"You and {s.person.capitalize()} are square.", {"cents": n})
        return Result(f"{money(owed)} owed to you, {money(owe)} you owe.", {"cents": owed, "owe_cents": owe})

    def find_transactions(self, s: Slots) -> Result:
        rows = sorted(_in(self.l, s.range, s.categories, s.merchant, s.person, s.not_categories), key=lambda t: (t["date"], t["id"]), reverse=True)
        return Result(f"{len(rows)} {'transaction' if len(rows) == 1 else 'transactions'}." + (f" Latest: {rows[0]['merchant']} on {rows[0]['date']:%b} {rows[0]['date'].day}." if rows else ""), {"count": len(rows)}, s.range, _see(self.l, s.range, s.categories, s.merchant or s.person, s.not_categories))

    def biggest(self, s: Slots) -> Result:
        rows = [t for t in _in(self.l, s.range, s.categories) if t.get("out_cents", 0) > 0]
        if not rows:
            return Result("$0 spent.", {"cents": 0}, s.range, _see(self.l, s.range))
        t = max(rows, key=lambda x: x["out_cents"])
        return Result(f"{money(t['out_cents'])} at {t['merchant']}, your biggest purchase.", {"cents": t["out_cents"]}, s.range, _see(self.l, s.range, s.categories))

    def what_if(self, s: Slots) -> Result:
        if not s.amount:
            return Result("Give me an amount and I'll check it against Safe to spend.", {})
        v, pay = self._safe()
        left = v - s.amount
        tail = f" until {pay:%A}" if pay else ""
        return Result(f"Yes. {money(s.amount)} leaves {money(left)} safe to spend{tail}." if left >= 0 else f"Not comfortably. {money(s.amount)} puts you {money(left)} past safe to spend{tail}.", {"cents": left})

TOOL_NAMES = ["spend_summary", "category_breakdown", "top_merchants", "compare_periods", "balance_now", "upcoming_bills", "subscriptions", "safe_to_spend", "payday_info", "tally_balances", "find_transactions", "what_if", "biggest"]

# ---------------- rules ----------------
INTENTS: list[tuple[str, str, dict]] = [
    (r"\b(can i afford|what if|if i (spend|buy)|could i (buy|spend)|am i ok(ay)? to)\b", "what_if", {}),
    (r"\b(safe to spend|how much can i spend|what can i spend|spending money left|left to spend)\b", "safe_to_spend", {}),
    (r"^(?!.*\b(spent|spend|spending|sent|send|earn|earned|made)\b).*\b(pay ?day|paid next|get paid|next paycheck|pay ?period)\b", "payday_info", {}),
    (r"\b(owe[sd]?|owing|tally|split with|square with)\b", "tally_balances", {}),
    (r"\b(subscriptions?|recurring charges)\b(?!.*\b(spen[dt]|last month|in \w+)\b)", "subscriptions", {}),
    (r"\b(bills? (are |is )?(due|coming|left)|what'?s due|due (this|next|soon)|upcoming bills?|bills? this week)\b", "upcoming_bills", {}),
    (r"\b(balance|how much (money )?(do i have|is in|have i got)|in my (checking|savings|account))\b", "balance_now", {}),
    (r"\b(vs\.?|versus|compared? (to|with)|more than|less than|than last|than in)\b", "compare_periods", {}),
    (r"\b(top|most) (merchants?|stores?|places?|shops?)\b|\bwhere did i (spend|shop) (the )?most\b|\bwho did i pay most\b", "top_merchants", {}),
    (r"\b(biggest|largest|most expensive) (purchase|expense|charge|transaction)\b", "biggest", {}),
    (r"\b(breakdown|by category|biggest categor\w*|top categor\w*|where did (my|the) money go|where is my money going|what did i spend (the )?most on)\b", "category_breakdown", {}),
    (r"\b(earn(ed)?|income|made|came in|got paid)\b", "spend_summary", {"kind": "in"}),
    (r"\b(show|list|find|see)( me)?\b.*\b(transactions?|purchases?|payments?|charges?|zelle)\b|\bwhen did i\b", "find_transactions", {}),
    (r"\b(how much|what did i|total|spent|spend|spending|sent|send|i paid|did i pay)\b", "spend_summary", {}),
]

def normalise(q: str, l: Ledger, s: Slots | None = None) -> str:
    """The question's shape: dates, amounts, names and categories become slots, so "rent in October" and "rent in March" are one question."""
    t = q.lower()
    s = s or extract(q, l)
    t = re.sub(r"\$ ?\d[\d,.]*", " <amount> ", t)
    t = re.sub(r"\b(last|past|previous) \d+ (days?|weeks?|months?)\b|\b(this|last|previous|current) (week|month|year|pay ?period)\b|\byesterday\b|\btoday\b|\bsince (my |the )?(last )?pay ?(day|check)\b", " <range> ", t)
    names = "|".join(sorted(MONTHS, key=len, reverse=True))
    t = re.sub(rf"\b(in |for |during |since )?({names})( 20\d\d)?\b", " <range> ", t)
    if s.person:
        t = re.sub(rf"\b{re.escape(s.person)}\b( \w+)?", " <person> ", t)
    for c in sorted({*s.categories, *s.not_categories}, key=len, reverse=True):
        t = re.sub(rf"\b{re.escape(c.lower())}\b", " <cat> ", t)
    return " ".join(re.sub(r"[^a-z0-9<> ]", " ", t).split())

def route_rules(q: str) -> tuple[str, dict] | None:
    s = q.lower()
    for pattern, tool, params in INTENTS:
        if re.search(pattern, s):
            return tool, params
    return None

# ---------------- learned matcher ----------------
def grams(s: str, n: int = 3) -> Counter:
    t = f"  {s}  "
    return Counter(t[i:i + n] for i in range(len(t) - n + 1))

@dataclass
class Matcher:
    """Char n-gram TF-IDF with cosine similarity over questions I marked good."""
    docs: list[dict]        # {normalised, tool, params, weight}
    idf: dict = field(default_factory=dict)
    THRESHOLD = 0.62

    def __post_init__(self):
        if not self.idf and self.docs:
            df: Counter = Counter()
            for d in self.docs:
                df.update(grams(d["normalised"]).keys())
            n = len(self.docs)
            self.idf = {g: math.log((1 + n) / (1 + c)) + 1 for g, c in df.items()}
        self.vecs = [self._vec(d["normalised"]) for d in self.docs]

    def _vec(self, s: str) -> dict:
        v = {g: c * self.idf.get(g, 1.0) for g, c in grams(s).items()}
        norm = math.sqrt(sum(x * x for x in v.values())) or 1.0
        return {g: x / norm for g, x in v.items()}

    def nearest(self, s: str, k: int = 1) -> list[tuple[float, dict]]:
        q = self._vec(s)
        scored = [(sum(x * v.get(g, 0.0) for g, x in q.items()) * d.get("weight", 1.0), d) for v, d in zip(self.vecs, self.docs)]
        return sorted(scored, key=lambda x: -x[0])[:k]

    def match(self, s: str) -> dict | None:
        best = self.nearest(s)
        return best[0][1] if best and best[0][0] >= self.THRESHOLD else None

# ---------------- the chain ----------------
@dataclass
class Routed:
    tool: str | None
    params: dict
    path: str

FOLLOW_UP = re.compile(r"^\s*(and|what about|how about|same for|and for|what of|ok and)\b", re.I)

def run(tool: str, params: dict, s: Slots, l: Ledger) -> Result:
    t = Tools(l)
    if params.get("range_phrase"):                      # a correction said which period: still parsed fresh, never stored as dates
        s.range = parse_range(params["range_phrase"], l.today, l.period, l.prev_period)
    return getattr(t, tool)(s, **{k: v for k, v in params.items() if k in ("kind", "days")})

def apply_context(s: Slots, q: str, ctx: dict | None) -> Slots:
    """"and last month?": keep what the last answer was about, change what this question names."""
    if not ctx or not FOLLOW_UP.match(q):
        return s
    p = ctx.get("slots") or {}
    s.categories = s.categories or p.get("categories") or []
    s.not_categories = s.not_categories or p.get("not_categories") or []
    s.merchant = s.merchant or p.get("merchant")
    s.person = s.person or p.get("person")
    return s

def slot_dict(s: Slots) -> dict:
    return {"categories": s.categories, "not_categories": s.not_categories, "merchant": s.merchant, "person": s.person, "range": s.range.label}

def route(q: str, l: Ledger, *, aliases: dict | None = None, matcher: Matcher | None = None, promoted: dict | None = None, context: dict | None = None,
          device: Callable[[str], tuple[str, dict] | None] | None = None, cloud: Callable[[str], tuple[str, dict] | None] | None = None) -> tuple[Routed, Slots]:
    """Cheapest first. The router only ever picks a tool; `run` computes the number."""
    s = apply_context(extract(q, l, aliases), q, context)
    norm = normalise(q, l, s)
    if promoted and norm in promoted:
        return Routed(promoted[norm]["tool"], promoted[norm].get("params") or {}, "rules"), s
    # A correction or a good answer to this very shape beats the general rules.
    hit = matcher.match(norm) if matcher else None
    if hit and hit.get("corrected"):
        return Routed(hit["tool"], hit.get("params") or {}, "learned"), s
    if context and FOLLOW_UP.match(q) and context.get("tool"):
        return Routed(context["tool"], context.get("params") or {}, "rules"), s
    r = route_rules(q)
    if r:
        return Routed(r[0], r[1], "rules"), s
    if not hit and (s.categories or s.person or s.merchant):      # "rent in October": a thing and a time is a spending question
        return Routed("spend_summary", {}, "rules"), s
    if hit:
        return Routed(hit["tool"], hit.get("params") or {}, "learned"), s
    for fn, path in ((device, "device"), (cloud, "cloud")):
        got = fn(q) if fn else None
        if got and got[0] in TOOL_NAMES:
            return Routed(got[0], got[1] if isinstance(got[1], dict) else {}, path), s
    return Routed(None, {}, "none"), s

def suggestions(l: Ledger) -> list[str]:
    """Questions worth asking of this person's own data."""
    out = []
    if l.period:
        out.append("How much have I spent since payday?")
    by = Counter(t.get("category") for t in l.txns if t.get("out_cents", 0) > 0 and t.get("category"))
    if by:
        out.append(f"How much on {by.most_common(1)[0][0]} this month?")
    if any(t.get("person") for t in l.txns):
        p = Counter(w for t in l.txns for w in (t.get("person") or "").split()[:1]).most_common(1)
        if p:
            out.append(f"How much did I send {p[0][0].capitalize()} this year?")
    out += ["What's safe to spend?", "What's due this week?", "Spending vs last month"]
    return out[:4]
