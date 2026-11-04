import pytest
from app.parsers import parse_alert, parse_applepay
from app.merchants import clean_merchant, similarity, categorize, looks_business

CASES = [
    ("Chase: A $18.40 transaction was made at UBER *TRIP on card ending in 4421.", -1840, "Chase", "4421", "UBER *TRIP"),
    ("Chase: You made a $45.67 debit card transaction with TARGET on Nov 3, 2026 at 9:12 AM ET.", -4567, "Chase", None, "TARGET"),
    ("BofA: Card ending in 1234 was charged $12.34 at STARBUCKS on 11/03.", -1234, "Bank of America", "1234", "STARBUCKS"),
    ("Bank of America: Credit card ending 4321: $23.45 at WALMART on 11/03/26", -2345, "Bank of America", "4321", "WALMART"),
    ("Capital One: A purchase of $18.40 was made on your Savor card ending in 1234 at UBER on 11/03.", -1840, "Capital One", "1234", "UBER"),
    ("Capital One: A $9.99 transaction at SPOTIFY was charged to your Quicksilver card ending in 7788", -999, "Capital One", "7788", "SPOTIFY"),
    ("American Express: Card ending in 1007: A charge of $1,250.00 was made at DELTA AIR on 11/03/2026.", -125000, "American Express", "1007", "DELTA AIR"),
    ("Amex Alert: A $18.40 charge on your card ending 1007 at UBER.", -1840, "American Express", "1007", "UBER"),
    ("Wells Fargo: Card ending in 1234 used at TRADER JOES for $42.10 on 11/03.", -4210, "Wells Fargo", "1234", "TRADER JOES"),
    ("Citi Alert: A $18.40 transaction was made at UBER on card ending in 1234.", -1840, "Citi", "1234", "UBER"),
    ("Citi: Card ending in 1234 was used for $5.75 at BLUE BOTTLE.", -575, "Citi", "1234", "BLUE BOTTLE"),
    ("Discover Card: A transaction of $64.00 was made at COMCAST on November 3, 2026 on your card ending in 1234", -6400, "Discover", "1234", "COMCAST"),
    ("Apple Card: $18.40 at Uber.", -1840, "Apple Card", None, "Uber"),
]

@pytest.mark.parametrize("text,cents,bank,last4,merchant", CASES)
def test_known_banks(text, cents, bank, last4, merchant):
    p = parse_alert(text)
    assert p is not None, text
    assert (p.amount_cents, p.bank, p.card_last4) == (cents, bank, last4)
    assert p.merchant_raw.upper().startswith(merchant.upper()[:6])
    assert p.confidence >= 0.8

def test_deposit_is_positive():
    p = parse_alert("Chase: You received a deposit of $2,310.00 to your checking account ending in 1180.")
    assert p and p.amount_cents == 231000

def test_unknown_bank_is_low_confidence():
    p = parse_alert("Your card was charged $12.00 at JOES PIZZA.")
    assert p and p.confidence < 0.8 and p.amount_cents == -1200

def test_amount_only_is_lowest():
    p = parse_alert("Alert: something happened for $5.00")
    assert p and p.confidence < 0.5 and p.merchant_raw == ""

@pytest.mark.parametrize("junk", ["", "hello there", "Your code is 123456", None])
def test_junk(junk):
    assert parse_alert(junk) is None

def test_messy_merchant_lowers_confidence():
    p = parse_alert("Chase: A $29.99 transaction was made at AMZN Mktp US*2K4TT93 on card ending in 4421.")
    assert p and p.confidence < 0.96 and p.confidence >= 0.8

def test_applepay():
    p = parse_applepay("Uber", "18.40", "Chase Freedom Visa 4421")
    assert p.amount_cents == -1840 and p.card_last4 == "4421" and p.confidence >= 0.9
    assert parse_applepay("", 5, None).confidence < 0.8
    assert parse_applepay("Refund Co", "-24.00").amount_cents == 2400
    assert parse_applepay("x", "abc") is None

def test_clean_merchant():
    assert clean_merchant("SQ *BLUE BOTTLE COFFEE 12345") == "Blue Bottle Coffee"
    assert clean_merchant("UBER *TRIP") == "Uber"
    assert clean_merchant("AMZN Mktp US*2K4TT93") == "Amazon"
    assert clean_merchant("") == ""
    assert clean_merchant(clean_merchant("TRADER JOES #123")) == clean_merchant("TRADER JOES #123")

def test_similarity():
    assert similarity("UBER *TRIP", "Uber") == 1.0
    assert similarity("Whole Foods", "WHOLEFDS MKT 10234") >= 0.55
    assert similarity("Uber", "Chipotle") < 0.55
    assert similarity("", "Uber") == 0.0

def test_categorize_rules_win():
    assert categorize("Uber") == ("Rideshare", "keyword")
    assert categorize("Uber", {"uber": "Travel"}) == ("Travel", "rule")
    assert categorize("Weird Shop") == ("Other", "none")
    assert looks_business("Namecheap") and not looks_business("Chipotle")
