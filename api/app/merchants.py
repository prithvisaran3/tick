"""Merchant cleaning, similarity and rule-based categorisation. Pure functions."""
import re
from difflib import SequenceMatcher

# prefixes added by payment processors
_PREFIX = re.compile(r"^(sq\s*\*|tst\s*\*|sp\s*\*|pp\s*\*|paypal\s*\*|pos\s+|dd\s*\*|ach\s+|apl\s*\*|google\s*\*|amzn\s+mktp\s+us\*?)", re.I)
_NOISE_WORDS = {"inc", "llc", "ltd", "co", "corp", "the", "store", "stores", "usa", "us", "online", "purchase", "payment", "pos", "debit", "card", "trip", "help", "com", "www", "mktp", "mktplace"}
_TRAILING_ID = re.compile(r"[\s#*-]+(?:\d{3,}|(?=[A-Za-z0-9]*\d)[A-Za-z0-9]{6,})\s*$")
_STATE_CITY = re.compile(r"\s+[A-Z][a-zA-Z .]+\s+[A-Z]{2}\s*$")

ALIASES = {
    "ubereats": "Uber Eats", "uber": "Uber", "amazonwebservices": "AWS", "aws": "AWS", "lyft": "Lyft", "amzn": "Amazon", "amazon": "Amazon", "amazoncom": "Amazon",
    "wholefoods": "Whole Foods", "wholefds": "Whole Foods", "wfm": "Whole Foods", "traderjoes": "Trader Joe's", "traderjoe": "Trader Joe's",
    "starbucks": "Starbucks", "chipotle": "Chipotle", "doordash": "DoorDash", "netflix": "Netflix", "spotify": "Spotify",
    "applecombill": "Apple", "appleservices": "Apple", "cursor": "Cursor", "anthropic": "Claude", "claudeai": "Claude", "openai": "OpenAI",
    "github": "GitHub", "cloudflare": "Cloudflare", "namecheap": "Namecheap", "railway": "Railway", "vercel": "Vercel",
}

_ALIAS_ORDER = sorted(ALIASES.items(), key=lambda kv: -len(kv[0]))

def _alnum(s: str) -> str:
    return re.sub(r"[^a-z0-9]", "", s.lower())

def clean_merchant(raw: str) -> str:
    """'SQ *BLUE BOTTLE COFFEE 1234 Arlington VA' -> 'Blue Bottle Coffee'. Idempotent."""
    s = (raw or "").strip()
    if not s:
        return ""
    raw_key = _alnum(s)
    for alias, name in _ALIAS_ORDER:
        if raw_key.startswith(alias):
            return name
    s = _PREFIX.sub("", s).strip()
    s = re.sub(r"\s+", " ", s)
    s = _STATE_CITY.sub("", s) if s.isupper() else s
    s = _TRAILING_ID.sub("", s).strip(" *#-.,")
    key = _alnum(s)
    for alias, name in _ALIAS_ORDER:
        if key.startswith(alias):
            return name
    words = s.split()
    out = [w.capitalize() if (w.isupper() or w.islower()) else w for w in words]
    return " ".join(out)[:60]

def norm_tokens(s: str) -> list[str]:
    s = clean_merchant(s).lower()
    toks = [t for t in re.split(r"[^a-z0-9]+", s) if t and t not in _NOISE_WORDS]
    return toks

def similarity(a: str, b: str) -> float:
    """0..1 fuzzy merchant similarity, robust to processor prefixes, ids and truncation."""
    ta, tb = norm_tokens(a), norm_tokens(b)
    if not ta or not tb:
        return 0.0
    ja, jb = "".join(ta), "".join(tb)
    if ja == jb:
        return 1.0
    sa, sb = set(ta), set(tb)
    small, large = (sa, sb) if len(sa) <= len(sb) else (sb, sa)
    # "Uber" is not "Uber Eats": a single-token name that is only a strict subset of a longer name is a different merchant.
    if len(small) == 1 and small < large:
        return 0.5
    if len(ja) >= 3 and len(jb) >= 3 and (ja in jb or jb in ja):
        return 0.9
    seq = SequenceMatcher(None, ja, jb).ratio()
    jac = len(sa & sb) / len(sa | sb)
    return max(seq, jac)

TIPPABLE_WORDS = ("restaurant", "cafe", "coffee", "bar", "grill", "pizza", "kitchen", "tavern", "pub", "bistro", "diner", "taco", "sushi", "thai",
                  "uber", "lyft", "doordash", "grubhub", "salon", "spa", "barber", "cab", "taxi", "chipotle", "sweetgreen", "starbucks")
_TIPPABLE_RE = re.compile(r"\b(?:" + "|".join(TIPPABLE_WORDS) + r")\b")

def is_tippable(merchant: str, category_name: str | None = None) -> bool:
    m = (merchant or "").lower()
    if category_name and category_name.lower() in {"restaurants", "coffee", "rideshare"}:
        return True
    return bool(_TIPPABLE_RE.search(re.sub(r"[^a-z0-9 ]", " ", m)))

BUSINESS_KEYWORDS = ("claude", "anthropic", "openai", "cursor", "github", "vercel", "railway", "supabase", "aws", "amazon web", "google cloud", "cloudflare",
                     "namecheap", "godaddy", "porkbun", "apple developer", "figma", "notion", "linear", "sentry", "twilio", "stripe", "digitalocean", "heroku",
                     "netlify", "canva", "adobe", "gemini", "perplexity", "replit", "plaid")

def looks_business(merchant: str) -> bool:
    m = (merchant or "").lower()
    return any(k in m for k in BUSINESS_KEYWORDS)

_CAT_KEYWORDS = [
    ("Rideshare", ("uber", "lyft")), ("Coffee", ("starbucks", "coffee", "blue bottle", "dunkin", "peet")),
    ("Groceries", ("whole foods", "trader joe", "safeway", "giant", "kroger", "harris teeter", "grocer", "aldi", "costco")),
    ("Restaurants", ("chipotle", "sweetgreen", "doordash", "grubhub", "restaurant", "pizza", "grill", "kitchen", "taco", "sushi", "uber eats")),
    ("Rent", ("rent", "landlord", "property mgmt")), ("Phone and internet", ("comcast", "xfinity", "verizon", "t-mobile", "at&t", "internet", "fios")),
    ("Utilities", ("pepco", "dominion", "water", "electric", "gas bill", "washgas")),
    ("Subscriptions", ("netflix", "spotify", "hulu", "disney", "youtube", "apple.com/bill", "icloud", "hbo")),
    ("Software", ("claude", "anthropic", "openai", "cursor", "github", "vercel", "railway", "supabase", "aws", "cloudflare", "namecheap", "figma", "notion", "apple developer")),
    ("Travel", ("delta", "united", "american air", "southwest", "airbnb", "marriott", "hilton", "jetblue", "flight")),
    ("Health", ("cvs", "walgreens", "pharmacy", "clinic", "dental")), ("Shopping", ("amazon", "target", "walmart", "best buy", "ikea")),
]

def categorize(merchant: str, rules: dict[str, str] | None = None) -> tuple[str, str]:
    """Return (category name, source) where source is 'rule' | 'keyword' | 'none'. Learned rules always win."""
    m = (merchant or "").lower()
    for pat, cat in (rules or {}).items():
        if pat and pat in m:
            return cat, "rule"
    for cat, keys in _CAT_KEYWORDS:
        if any(k in m for k in keys):
            return cat, "keyword"
    return "Other", "none"
