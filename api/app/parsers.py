"""Table-driven regex parsers for bank alert texts. Each bank has a detector and a list of patterns; the first match wins.
Confidence: 0.95 clean match on a known bank, lowered for messy merchants; generic fallback is 0.55 (goes to Gemini, then to the Caught inbox)."""
import re
from dataclasses import dataclass, field
from datetime import datetime

from .merchants import clean_merchant

@dataclass
class ParsedAlert:
    amount_cents: int            # negative = out
    merchant_raw: str
    bank: str | None = None
    card_last4: str | None = None
    date_hint: str | None = None
    confidence: float = 0.0
    pattern: str = ""
    notes: list[str] = field(default_factory=list)

AMT = r"\$\s?(?P<amount>\d{1,3}(?:,\d{3})*(?:\.\d{2})?|\d+(?:\.\d{2})?)"
MERCH = r"(?P<merchant>[A-Za-z0-9][^\n]*?)"
LAST4 = r"(?:card\s+)?(?:ending|ends)\s+(?:in\s+)?(?P<last4>\d{4})"
DATE = r"(?P<date>(?:\d{1,2}/\d{1,2}(?:/\d{2,4})?)|(?:[A-Z][a-z]{2,8}\.? \d{1,2}(?:, \d{4})?))"

BANKS: list[dict] = [
    {"bank": "Chase", "detect": r"\bchase\b", "patterns": [
        ("chase_made", rf"(?:a|you made a)\s+{AMT}\s+(?:debit card\s+|credit card\s+)?transaction (?:was made )?(?:at|with)\s+{MERCH}(?:\s+on\s+{DATE}.*?|\s+on card ending.*|\s+with card ending.*|\.|$)", "out"),
        ("chase_card", rf"{AMT}\s+transaction (?:was )?(?:made )?at\s+{MERCH}\s+on {LAST4}", "out"),
        ("chase_deposit", rf"(?:you received|deposit of|direct deposit of)\s+(?:a deposit of\s+)?{AMT}", "in"),
    ]},
    {"bank": "Bank of America", "detect": r"\b(?:bofa|bank of america|boa)\b", "patterns": [
        ("bofa_charged", rf"{LAST4}\s+was (?:charged|used for)\s+{AMT}\s+at\s+{MERCH}(?:\s+on\s+{DATE}.*|\.|$)", "out"),
        ("bofa_colon", rf"{LAST4}:\s*{AMT}\s+at\s+{MERCH}(?:\s+on\s+{DATE}.*|\.|$)", "out"),
        ("bofa_deposit", rf"deposit of {AMT}", "in"),
    ]},
    {"bank": "Capital One", "detect": r"\bcapital one\b", "patterns": [
        ("cap1_purchase", rf"purchase of {AMT} was made on your .*?{LAST4}\s+at\s+{MERCH}(?:\s+on\s+{DATE}.*|\.|$)", "out"),
        ("cap1_txn", rf"{AMT}\s+transaction at\s+{MERCH}\s+was charged to your .*?{LAST4}", "out"),
    ]},
    {"bank": "American Express", "detect": r"\b(?:american express|amex)\b", "patterns": [
        ("amex_charge", rf"{LAST4}:?\s*(?:a )?charge of {AMT} was made at\s+{MERCH}(?:\s+on\s+{DATE}.*|\.|$)", "out"),
        ("amex_alert", rf"(?:a )?{AMT}\s+charge on your {LAST4}\s+at\s+{MERCH}(?:\.|$)", "out"),
    ]},
    {"bank": "Wells Fargo", "detect": r"\bwells fargo\b", "patterns": [
        ("wf_used", rf"{LAST4}\s+used at\s+{MERCH}\s+for {AMT}(?:\s+on\s+{DATE}.*|\.|$)", "out"),
        ("wf_purchase", rf"purchase of {AMT} at\s+{MERCH}\s+on\s+{DATE}(?:\s+on)?.*?{LAST4}", "out"),
    ]},
    {"bank": "Citi", "detect": r"\bciti(?:bank)?\b", "patterns": [
        ("citi_made", rf"(?:a )?{AMT}\s+transaction was made at\s+{MERCH}\s+on (?:the )?{LAST4}", "out"),
        ("citi_used", rf"{LAST4}\s+was used for {AMT}\s+at\s+{MERCH}(?:\.|$)", "out"),
    ]},
    {"bank": "Discover", "detect": r"\bdiscover\b", "patterns": [
        ("disc_txn", rf"transaction of {AMT} was made at\s+{MERCH}\s+on\s+{DATE}.*?{LAST4}", "out"),
        ("disc_txn2", rf"{AMT}\s+(?:purchase|transaction) at\s+{MERCH}\s+on (?:your )?(?:card )?.*?{LAST4}", "out"),
    ]},
    {"bank": "Apple Card", "detect": r"\bapple card\b", "patterns": [
        ("apple_card", rf"{AMT}\s+at\s+{MERCH}(?:\.|$)", "out"),
    ]},
]

# Generic: "$12.34 at MERCHANT", "purchase ... $12.34 ... at MERCHANT"
GENERIC = [("generic_at", rf"{AMT}\s+(?:at|to|with)\s+{MERCH}(?:\s+on\s+{DATE}.*|\.|$)", "out"),
           ("generic_charged", rf"charged\s+{AMT}\s+(?:at|by)\s+{MERCH}(?:\.|$)", "out")]

def _cents(s: str) -> int:
    s = s.replace(",", "")
    whole, _, frac = s.partition(".")
    return int(whole) * 100 + int((frac + "00")[:2])

def _messy(merchant: str) -> bool:
    return bool(re.search(r"\d{4,}", merchant)) or "*" in merchant or len(merchant) < 3

def parse_alert(text: str) -> ParsedAlert | None:
    """Parse a bank alert SMS. Returns None when nothing amount-like is found."""
    t = re.sub(r"\s+", " ", (text or "").strip())
    if not t:
        return None
    low = t.lower()
    tried: list[tuple[str, str, str | None]] = []
    for b in BANKS:
        if re.search(b["detect"], low):
            tried += [(n, p, b["bank"]) for n, p, _ in b["patterns"]]
            kinds = {n: k for n, _, k in b["patterns"]}
            for name, pat, bank in tried:
                m = re.search(pat, t, re.I)
                if not m:
                    continue
                gd = m.groupdict()
                amt = _cents(gd["amount"])
                direction = kinds[name]
                merchant = (gd.get("merchant") or "").strip(" .")
                last4 = gd.get("last4") or (re.search(LAST4, t, re.I).group("last4") if re.search(LAST4, t, re.I) else None)
                if direction == "in":
                    return ParsedAlert(amt, merchant or "Deposit", bank, last4, gd.get("date"), 0.9, name)
                conf = 0.96
                notes = []
                if _messy(merchant):
                    conf = 0.88
                    notes.append("merchant text is messy")
                if not merchant:
                    continue
                return ParsedAlert(-amt, merchant, bank, last4, gd.get("date"), conf, name, notes)
            break
    # Unknown bank or no pattern matched: generic, low confidence.
    for name, pat, _ in GENERIC:
        m = re.search(pat, t, re.I)
        if m:
            gd = m.groupdict()
            last4m = re.search(LAST4, t, re.I)
            return ParsedAlert(-_cents(gd["amount"]), (gd.get("merchant") or "").strip(" ."), None, last4m.group("last4") if last4m else None, gd.get("date"), 0.55, name, ["unrecognised bank format"])
    m = re.search(AMT, t)
    if m:
        return ParsedAlert(-_cents(m.group("amount")), "", None, None, None, 0.3, "amount_only", ["no merchant found"])
    return None

def parse_applepay(merchant: str, amount: str | float | int, card: str | None = None) -> ParsedAlert | None:
    """Shortcuts 'Transaction' (Wallet) automation: structured fields, so confidence is high."""
    try:
        a = float(str(amount).replace("$", "").replace(",", "").strip())
    except ValueError:
        return None
    if a == 0:
        return None
    last4 = None
    if card:
        m = re.search(r"(\d{4})\D*$", card)
        last4 = m.group(1) if m else None
    merchant = (merchant or "").strip()
    conf = 0.95 if merchant else 0.4
    if merchant and _messy(merchant):
        conf = 0.9
    return ParsedAlert(-round(abs(a) * 100) if a > 0 else round(abs(a) * 100), merchant, card, last4, None, conf, "applepay")
