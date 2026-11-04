import itertools
from datetime import datetime, timedelta, timezone

import pytest
from hypothesis import HealthCheck, given, settings, strategies as st

from app.reconcile import Candidate, Txn, apply_plaid_removed, ingest, total_spend

T0 = datetime(2026, 11, 3, 14, 12, tzinfo=timezone.utc)

def sms(amount=-1840, merchant="UBER *TRIP", last4="4421", dt=0, ref="sms-1", conf=0.96):
    return Candidate("sms", ref, amount, T0 + timedelta(minutes=dt), merchant, "", last4, "posted", confidence=conf)

def apay(amount=-1840, merchant="Uber", last4="4421", dt=1, ref="ap-1"):
    return Candidate("applepay", ref, amount, T0 + timedelta(minutes=dt), merchant, "", last4, "posted", confidence=0.95)

def plaid(amount=-1840, merchant="Uber", last4="4421", dt=0, ref="px-1", status="posted", pending_id=None, hours=0):
    return Candidate("plaid", ref, amount, T0 + timedelta(minutes=dt, hours=hours), merchant, merchant, last4, status, plaid_transaction_id=ref, plaid_pending_id=pending_id, confidence=1.0)

def run(cands, names=None):
    txns: list[Txn] = []
    for i, c in enumerate(cands):
        ingest(txns, c, f"t{i}", category_names=names)
    return txns

# ---------- single channels ----------
@pytest.mark.parametrize("c", [sms(), apay(), plaid()])
def test_single_source_inserts_one(c):
    t = run([c])
    assert len(t) == 1 and t[0].amount_cents == -1840

def test_low_confidence_flags_review():
    t = run([sms(conf=0.6)])
    assert t[0].needs_review is True
    t = run([sms(conf=0.96)])
    assert t[0].needs_review is False

# ---------- every channel combination, every order ----------
CHANNELS = {"sms": sms, "applepay": apay, "plaid": plaid}

@pytest.mark.parametrize("combo", [c for r in (2, 3) for c in itertools.combinations(CHANNELS, r)])
def test_all_combinations_all_orders_merge_to_one(combo):
    for order in itertools.permutations(combo):
        t = run([CHANNELS[name]() for name in order])
        assert len(t) == 1, (combo, order)
        row = t[0]
        assert row.amount_cents == -1840
        assert {s["source"] for s in row.sources} == set(combo)
        assert total_spend(t) == 1840
        if "plaid" in combo:
            assert row.plaid_transaction_id == "px-1" and row.status == "posted"

def test_plaid_wins_truth_regardless_of_order():
    # SMS reports $18.40 at 14:12; Plaid says $18.40 posted with a different timestamp and clean merchant
    for order in ([sms(), plaid(dt=5)], [plaid(dt=5), sms()]):
        t = run(order)[0]
        assert t.merchant_clean == "Uber" and t.occurred_at == T0 + timedelta(minutes=5)

def test_pending_then_posted_via_pending_transaction_id():
    t = run([sms(), plaid(ref="pend-1", status="pending"), plaid(ref="post-1", status="posted", pending_id="pend-1")])
    assert len(t) == 1 and t[0].plaid_transaction_id == "post-1" and t[0].status == "posted"
    assert {s["source"] for s in t[0].sources} == {"sms", "plaid"}
    assert total_spend(t) == 1840

def test_pending_posted_with_changed_amount_tip():
    t = run([plaid(ref="pend-1", status="pending", amount=-1840, merchant="Chipotle"), plaid(ref="post-1", amount=-2200, merchant="Chipotle", pending_id="pend-1")])
    assert len(t) == 1 and t[0].amount_cents == -2200

def test_plaid_id_update_is_idempotent_and_modified_event_updates():
    t = run([plaid(), plaid(amount=-1900)])  # 'modified' event reuses the same plaid id
    assert len(t) == 1 and t[0].amount_cents == -1900

# ---------- tip tolerance ----------
def test_tip_merges_for_restaurants_both_orders():
    for order in ([sms(-1840, "CHIPOTLE 0123"), plaid(-2200, "Chipotle")], [plaid(-2200, "Chipotle"), sms(-1840, "CHIPOTLE 0123")]):
        t = run(order)
        assert len(t) == 1 and t[0].amount_cents == -2200, order

def test_tip_applies_to_rideshare():
    t = run([apay(-1840, "Uber"), plaid(-2300, "Uber")])
    assert len(t) == 1 and t[0].amount_cents == -2300

def test_no_tip_tolerance_for_groceries():
    t = run([sms(-1840, "WHOLE FOODS"), plaid(-2200, "Whole Foods")])
    assert len(t) == 2

def test_tip_over_25_percent_not_merged():
    t = run([sms(-1000, "CHIPOTLE"), plaid(-1300, "Chipotle")])
    assert len(t) == 2

def test_tip_exactly_25_percent_merges():
    t = run([sms(-2000, "CHIPOTLE"), plaid(-2500, "Chipotle")])
    assert len(t) == 1

def test_larger_amount_must_come_from_higher_priority_source():
    # Plaid posted $18.40, SMS claims $22.00: that is not a tip; keep separate.
    t = run([plaid(-1840, "Chipotle"), sms(-2200, "CHIPOTLE")])
    assert len(t) == 2

def test_category_name_makes_unknown_merchant_tippable():
    t = run([sms(-4000, "JOES PLACE"), plaid(-4800, "Joes Place")], names={})
    assert len(t) == 2
    ledger = run([sms(-4000, "JOES PLACE")])
    ledger[0].category_id = "cat-restaurants"
    cand = plaid(-4800, "Joes Place")
    ingest(ledger, cand, "tx", category_names={"cat-restaurants": "Restaurants"})
    assert len(ledger) == 1

# ---------- negatives: must NOT merge ----------
def test_different_card_not_merged():
    assert len(run([sms(last4="1111"), plaid(last4="2222")])) == 2

def test_missing_card_is_neutral():
    assert len(run([sms(last4=None), plaid()])) == 1

def test_different_merchant_same_amount_not_merged():
    assert len(run([sms(-1840, "CHIPOTLE"), plaid(-1840, "Uber")])) == 2

def test_outside_72h_not_merged_inside_merged():
    assert len(run([sms(), plaid(hours=73)])) == 2
    assert len(run([sms(), plaid(hours=71)])) == 1
    assert len(run([plaid(hours=71), sms()])) == 1

def test_refund_vs_charge_not_merged():
    assert len(run([sms(-1840), plaid(1840, ref="r-1")])) == 2

def test_same_source_twice_is_two_purchases():
    t = run([sms(-575, "BLUE BOTTLE", ref="a", dt=0), sms(-575, "BLUE BOTTLE", ref="b", dt=20)])
    assert len(t) == 2 and total_spend(t) == 1150

def test_two_plaid_txns_same_amount_are_distinct():
    t = run([plaid(-575, "Blue Bottle", ref="p1"), plaid(-575, "Blue Bottle", ref="p2", dt=30)])
    assert len(t) == 2

def test_two_coffees_each_confirmed_by_plaid():
    cands = [sms(-575, "BLUE BOTTLE", ref="s1", dt=0), sms(-575, "BLUE BOTTLE", ref="s2", dt=60),
             plaid(-575, "Blue Bottle", ref="p1", dt=2), plaid(-575, "Blue Bottle", ref="p2", dt=62)]
    for order in itertools.permutations(cands):
        t = run(list(order))
        assert len(t) == 2 and total_spend(t) == 1150, [c.ref for c in order]

def test_redelivery_is_noop():
    txns: list[Txn] = []
    ingest(txns, sms(), "t0")
    a = ingest(txns, sms(), "t1")
    assert a.kind == "noop" and len(txns) == 1

def test_merchantless_matches_only_with_card_and_exact_amount_within_6h():
    assert len(run([sms(merchant=""), plaid()])) == 1
    assert len(run([sms(merchant="", last4=None), plaid(last4=None)])) == 2
    assert len(run([sms(merchant=""), plaid(hours=7)])) == 2
    assert len(run([sms(-1841, merchant=""), plaid()])) == 2

def test_best_candidate_chosen_when_two_match():
    existing = run([apay(-1840, "Uber", ref="a1", dt=0), apay(-1840, "Uber", ref="a2", dt=600)])
    assert len(existing) == 2
    ingest(existing, plaid(-1840, "Uber", dt=598), "t9")
    # merged into the nearer one (a2), not the first
    assert len(existing) == 2
    merged = [t for t in existing if t.has_source("plaid")]
    assert len(merged) == 1 and merged[0].sources[0]["ref"] == "a2"

# ---------- user edits survive ----------
def test_user_edits_not_overwritten():
    txns = run([sms()])
    txns[0].category_id = "cat-travel"
    txns[0].merchant_clean = "Uber (work)"
    txns[0].user_edited = {"category", "merchant"}
    ingest(txns, plaid(), "t1")
    t = txns[0]
    assert len(txns) == 1 and t.category_id == "cat-travel" and t.merchant_clean == "Uber (work)"

def test_corroboration_clears_review():
    txns = run([sms(conf=0.6)])
    assert txns[0].needs_review
    ingest(txns, plaid(), "t1")
    assert not txns[0].needs_review and txns[0].confidence >= 0.97

# ---------- plaid removals ----------
def test_removed_pending_only_deletes():
    txns = run([plaid(ref="pend-1", status="pending")])
    acts = apply_plaid_removed(txns, ["pend-1"])
    assert txns == [] and acts[0].kind == "delete"

def test_removed_pending_keeps_sms_view():
    txns = run([sms(), plaid(ref="pend-1", status="pending")])
    apply_plaid_removed(txns, ["pend-1"])
    assert len(txns) == 1 and txns[0].plaid_transaction_id is None and txns[0].has_source("sms")

# ---------- property-based ----------
MERCHANTS = ["Uber", "Chipotle", "Whole Foods", "Cursor", "Spotify", "Comcast", "Delta Air", "CVS", "Sweetgreen", "Namecheap"]

@st.composite
def purchases(draw):
    n = draw(st.integers(1, 8))
    ms = draw(st.permutations(MERCHANTS).map(lambda m: m[:n]))
    out = []
    for i, m in enumerate(ms):
        out.append({"merchant": m, "amount": -draw(st.integers(100, 50_000)), "day": draw(st.integers(0, 40)) * 5, "last4": draw(st.sampled_from(["4421", "1180", None]))})
    chans = [draw(st.lists(st.sampled_from(["sms", "applepay", "plaid"]), min_size=1, max_size=3, unique=True)) for _ in out]
    return out, chans

def make(ch, p, i):
    base = timedelta(days=p["day"]) 
    c = {"sms": sms, "applepay": apay, "plaid": plaid}[ch](p["amount"], p["merchant"].upper() if ch == "sms" else p["merchant"], p["last4"], 0, f"{ch}-{i}")
    c.occurred_at = T0 + base + timedelta(minutes={"sms": 0, "applepay": 1, "plaid": 3}[ch])
    return c

@settings(max_examples=150, suppress_health_check=[HealthCheck.too_slow], deadline=None)
@given(purchases(), st.randoms(use_true_random=False))
def test_property_never_double_counts_and_is_order_independent(data, rnd):
    ps, chans = data
    # distinct purchases >=5 days apart so time windows never overlap: enforce by spreading days
    for i, p in enumerate(ps):
        p["day"] = i * 5
    cands = [make(ch, p, i) for i, (p, cs) in enumerate(zip(ps, chans)) for ch in cs]
    rnd.shuffle(cands)
    txns = run(cands)
    assert len(txns) == len(ps)
    # Total = sum of each purchase's amount (all channels agree on amount here)
    assert total_spend(txns) == sum(-p["amount"] for p in ps)
    # Idempotent: replaying every delivery changes nothing
    snapshot = [(t.amount_cents, t.status, len(t.sources)) for t in txns]
    for j, c in enumerate(cands):
        ingest(txns, c, f"re{j}")
    assert len(txns) == len(ps)
    assert [(t.amount_cents, t.status, len(t.sources)) for t in txns] == snapshot

@settings(max_examples=100, deadline=None)
@given(st.integers(500, 20_000), st.sampled_from(["Chipotle", "Uber", "Sweetgreen"]), st.integers(0, 25), st.randoms(use_true_random=False))
def test_property_tip_amount_converges_to_plaid(auth, merchant, tip_pct, rnd):
    final = auth + auth * tip_pct // 100
    cands = [sms(-auth, merchant.upper()), apay(-auth, merchant), plaid(-final, merchant)]
    rnd.shuffle(cands)
    txns = run(cands)
    assert len(txns) == 1 and txns[0].amount_cents == -final


# ---------- regressions from the Opus review ----------
def test_plaid_posted_without_pending_id_settles_pending_row():
    t = run([sms(), plaid(ref="pend-1", status="pending"), plaid(ref="post-1", dt=1440)])
    assert len(t) == 1 and total_spend(t) == 1840 and t[0].status == "posted"
    apply_plaid_removed(t, ["pend-1"])  # the pending id is gone: nothing left to detach
    assert len(t) == 1 and total_spend(t) == 1840

def test_redelivery_beyond_window_is_not_swallowed_but_same_minute_taps_are_distinct():
    a = sms(ref="h1", dt=0); b = sms(ref="h1", dt=30)       # same hash 30 min later: a second real purchase of the same text
    assert len(run([a, b])) == 2
    assert len(run([sms(ref="h1", dt=0), sms(ref="h1", dt=1)])) == 1   # a Shortcuts retry within minutes

def test_naive_datetimes_are_normalised():
    c = Candidate("sms", "n1", -500, datetime(2026, 11, 3, 14, 12), "COFFEE")
    assert c.occurred_at.tzinfo is not None
    assert len(run([c, plaid(-500, "Coffee")])) == 1

def test_zero_amount_never_merges():
    assert len(run([sms(0), plaid(0, ref="z")])) == 2

def test_alias_uber_eats_is_not_uber():
    from app.merchants import clean_merchant
    assert clean_merchant("UBER EATS") == "Uber Eats" and clean_merchant("Amazon Web Services") == "AWS"
    assert len(run([sms(-2500, "UBER EATS"), plaid(-2500, "Uber")])) == 2

def test_same_first_word_different_merchant_not_merged():
    assert len(run([sms(-1500, "BLUE APRON"), plaid(-1500, "Blue Bottle Coffee")])) == 2

def test_publix_is_not_tippable():
    assert len(run([sms(-10000, "PUBLIX #123", last4=None), plaid(-12000, "Publix", last4=None, hours=20)])) == 2

def test_apple_pay_amount_is_not_pre_tip():
    assert len(run([sms(-1840, "CHIPOTLE"), apay(-2200, "Chipotle")])) == 2

def test_tip_only_within_24h():
    assert len(run([sms(-1840, "CHIPOTLE"), plaid(-2200, "Chipotle", hours=30)])) == 2

def test_lunch_dinner_same_merchant_every_order():
    lunch_s, dinner_s = sms(-1840, "CHIPOTLE", ref="sL", dt=0), sms(-2200, "CHIPOTLE", ref="sD", dt=360)
    lunch_p, dinner_p = plaid(-1840, "Chipotle", ref="pL", dt=3), plaid(-2200, "Chipotle", ref="pD", dt=363)
    for order in itertools.permutations([lunch_s, dinner_s, lunch_p, dinner_p]):
        t = run(list(order))
        assert len(t) == 2 and total_spend(t) == 4040, [c.ref for c in order]

def test_weak_merge_flags_review():
    t = run([sms(-1500, "JOES GRILL HOUSE", last4=None), apay(-1500, "Joes Grill", last4=None)])
    assert len(t) == 1

def test_removal_flags_review_and_keeps_status():
    t = run([sms(), plaid(ref="pend-1", status="pending")])
    acts = apply_plaid_removed(t, ["pend-1"])
    assert t[0].needs_review and acts[0].fields["plaid_transaction_id"] is None

@settings(max_examples=120, deadline=None)
@given(st.lists(st.tuples(st.sampled_from([1840, 2200, 1500, 3100]), st.integers(0, 600)), min_size=2, max_size=3, unique_by=lambda x: x[0]), st.randoms(use_true_random=False))
def test_property_same_merchant_repeat_purchases(purchases, rnd):
    cands = []
    for i, (amt, mins) in enumerate(purchases):
        cands += [sms(-amt, "CHIPOTLE", ref=f"s{i}", dt=mins), plaid(-amt, "Chipotle", ref=f"p{i}", dt=mins + 3)]
    rnd.shuffle(cands)
    t = run(cands)
    assert len(t) == len(purchases) and total_spend(t) == sum(a for a, _ in purchases)
