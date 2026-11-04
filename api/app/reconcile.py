"""Dedupe + reconcile: one purchase may arrive via SMS, Apple Pay and Plaid. Merge them into ONE transaction keeping every source ref.

Design rules (tested in tests/test_reconcile.py):
  * Order independent: delivering the same purchase's sources in any order yields one row with the same truth fields.
  * Truth priority: Plaid posted > Plaid pending > Apple Pay > SMS/receipt > manual. Higher priority wins amount/date/status/merchant.
  * Match: exact Plaid ids (incl. pending -> posted via pending_transaction_id), exact (source, ref) re-delivery, else heuristics:
    same sign, within 72h, card last-4 must not conflict, amount exact or within 25% tip tolerance for tippable merchants
    (the larger amount must come from the higher-priority source), and fuzzy merchant similarity.
  * Two events from the SAME source are different purchases (e.g. two coffees), never merged, except exact re-delivery or Plaid pending -> posted.
  * User edits (category, tags, note, merchant) are never overwritten by a later source.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any

from .merchants import is_tippable, similarity

WINDOW = timedelta(hours=72)
TIP_WINDOW = timedelta(hours=24)
REDELIVERY_WINDOW = timedelta(minutes=10)
TIP_TOLERANCE = 0.25
MIN_SIMILARITY = 0.55
REVIEW_THRESHOLD = 0.8

def priority(source: str, status: str = "posted") -> int:
    if source == "plaid":
        return 5 if status == "posted" else 4
    return {"applepay": 3, "sms": 2, "receipt": 2, "manual": 1}.get(source, 1)

@dataclass
class Candidate:
    source: str                       # sms | applepay | plaid | receipt | manual
    ref: str                          # stable id of this delivery (plaid txn id, sha of sms text, ...)
    amount_cents: int                 # negative = out
    occurred_at: datetime             # aware UTC
    merchant_raw: str = ""
    merchant_clean: str = ""
    card_last4: str | None = None
    status: str = "posted"            # pending | posted
    plaid_transaction_id: str | None = None
    plaid_pending_id: str | None = None
    confidence: float = 1.0
    account_id: str | None = None
    category_id: str | None = None
    time_precise: bool = True         # False for date-only timestamps (Plaid posting dates)

    def __post_init__(self) -> None:
        if self.occurred_at.tzinfo is None:
            self.occurred_at = self.occurred_at.replace(tzinfo=timezone.utc)
        else:
            self.occurred_at = self.occurred_at.astimezone(timezone.utc)

@dataclass
class Txn:
    id: str
    amount_cents: int
    occurred_at: datetime
    merchant_raw: str = ""
    merchant_clean: str = ""
    card_last4: str | None = None
    status: str = "posted"
    sources: list[dict] = field(default_factory=list)   # [{source, ref, amount_cents, status}]
    plaid_transaction_id: str | None = None
    plaid_pending_id: str | None = None
    confidence: float = 1.0
    needs_review: bool = False
    account_id: str | None = None
    category_id: str | None = None
    user_edited: set[str] = field(default_factory=set)   # fields the user changed: 'merchant', 'category', 'amount', 'tags', 'note'

    @property
    def best_priority(self) -> int:
        return max((priority(s["source"], s.get("status", "posted")) for s in self.sources), default=0)

    def has_source(self, source: str) -> bool:
        return any(s["source"] == source for s in self.sources)

@dataclass
class Action:
    kind: str                          # insert | update | noop
    txn_id: str | None = None
    fields: dict[str, Any] = field(default_factory=dict)
    reason: str = ""

def _name(x: Candidate | Txn) -> str:
    return x.merchant_clean or x.merchant_raw

def _amount_compatible(cand: Candidate, t: Txn, tippable: bool, dt: timedelta) -> tuple[bool, bool]:
    """Returns (ok, exact). Tip band: only when the LARGER figure is a Plaid posted amount (the final, tipped charge),
    within 24h, and for tippable merchants. Apple Pay / SMS amounts are never assumed to be pre-tip."""
    a, b = cand.amount_cents, t.amount_cents
    if a == 0 or b == 0 or (a < 0) != (b < 0):
        return False, False
    if a == b:
        return True, True
    if not tippable or dt > TIP_WINDOW:
        return False, False
    lo, hi = sorted((abs(a), abs(b)))
    if hi > lo * (1 + TIP_TOLERANCE):
        return False, False
    cand_larger = abs(a) > abs(b)
    larger_is_plaid_posted = (cand.source == "plaid" and cand.status == "posted") if cand_larger else (t.best_priority == 5)
    return (True, False) if larger_is_plaid_posted else (False, False)

def _near(at: str | None, when: datetime) -> bool:
    if not at:
        return True
    try:
        d = datetime.fromisoformat(at)
    except ValueError:
        return True
    if d.tzinfo is None:
        d = d.replace(tzinfo=timezone.utc)
    return abs(d - when) <= REDELIVERY_WINDOW

def find_match(cand: Candidate, txns: list[Txn], *, category_names: dict[str, str] | None = None) -> tuple[Txn | None, str]:
    """Return (matching txn or None, reason)."""
    # 1. Exact ids
    for t in txns:
        if cand.plaid_transaction_id and t.plaid_transaction_id == cand.plaid_transaction_id:
            return t, "plaid_id"
        if cand.plaid_pending_id and t.plaid_transaction_id == cand.plaid_pending_id:
            return t, "pending_to_posted"
    # 2. Idempotent re-delivery: same (source, ref) delivered again shortly after.
    for t in txns:
        for s in t.sources:
            if s["source"] == cand.source and s["ref"] == cand.ref and _near(s.get("at"), cand.occurred_at):
                return t, "redelivery"
    # 3. Heuristics
    best: tuple[float, Txn, bool, str] | None = None
    best_close = None
    for t in txns:
        if t.has_source(cand.source):
            # Same source twice = two purchases, except Plaid posted settling a row whose only Plaid sources are pending.
            only_pending_plaid = cand.source == "plaid" and cand.status == "posted" and all(
                x.get("status") == "pending" for x in t.sources if x["source"] == "plaid") and t.plaid_transaction_id != cand.plaid_transaction_id
            if not only_pending_plaid:
                continue
        dt = abs(cand.occurred_at - t.occurred_at)
        if dt > WINDOW:
            continue
        if cand.card_last4 and t.card_last4 and cand.card_last4 != t.card_last4:
            continue
        cat = (category_names or {}).get(t.category_id or "")
        tippable = is_tippable(_name(cand), cat) or is_tippable(_name(t), cat)
        ok, exact = _amount_compatible(cand, t, tippable, dt)
        if not ok:
            continue
        na, nb = _name(cand), _name(t)
        sim = similarity(na, nb) if na and nb else 0.0
        card_eq = bool(cand.card_last4 and t.card_last4 and cand.card_last4 == t.card_last4)
        if sim < MIN_SIMILARITY:
            # A merchant-less capture may still match an exact amount on the same card within a few hours.
            if not ((not na or not nb) and exact and card_eq and dt <= timedelta(hours=6)):
                continue
        score = sim * 2 + (1.0 if card_eq else 0.0) + (2.0 if exact else 0.0) + 0.5 * (1 - dt / WINDOW)
        strong = exact and sim >= 0.8
        if best is None or score > best[0] + 0.05 or (abs(score - best[0]) <= 0.05 and dt < best_close):
            kind = "heuristic" if exact and strong else ("tip" if not exact else "heuristic_weak")
            best, best_close = (score, t, strong, kind), dt
    if best:
        return best[1], best[3]
    return None, "none"

def _source_entry(c: Candidate) -> dict:
    return {"source": c.source, "ref": c.ref, "amount_cents": c.amount_cents, "status": c.status, "at": c.occurred_at.isoformat(),
            "merchant_raw": c.merchant_raw, "card_last4": c.card_last4, "confidence": c.confidence, "pending_id": c.plaid_pending_id}

def merge_fields(t: Txn, c: Candidate, reason: str) -> dict[str, Any]:
    """Compute the update patch for merging candidate [c] into [t]. Pure."""
    f: dict[str, Any] = {}
    cp = priority(c.source, c.status)
    t_best = max(t.sources, key=lambda x: (priority(x["source"], x.get("status", "posted")), x["source"]), default=None)
    t_key = (t.best_priority, t_best["source"] if t_best else "")
    wins = (cp, c.source) > t_key or (cp == t.best_priority and reason in ("pending_to_posted", "plaid_id"))
    sources = list(t.sources)
    if not any(s["source"] == c.source and s["ref"] == c.ref for s in sources):
        sources.append(_source_entry(c))
    else:
        sources = [(_source_entry(c) if (s["source"] == c.source and s["ref"] == c.ref) else s) for s in sources]  # refresh status/amount
    if reason == "tip":
        sources = [{**x, "match": "tip"} for x in sources]       # provisional: a later exact match may take a slot back
    f["sources"] = sources

    if wins and "amount" not in t.user_edited:
        f["amount_cents"] = c.amount_cents
    if wins and (c.time_precise or not t.sources or not any(x["source"] != "plaid" for x in t.sources)):
        f["occurred_at"] = c.occurred_at
    if wins:
        if c.merchant_raw:
            f["merchant_raw"] = c.merchant_raw
        if c.merchant_clean and "merchant" not in t.user_edited:
            f["merchant_clean"] = c.merchant_clean
    else:
        if not t.merchant_clean and c.merchant_clean and "merchant" not in t.user_edited:
            f["merchant_clean"] = c.merchant_clean
        if not t.merchant_raw and c.merchant_raw:
            f["merchant_raw"] = c.merchant_raw
    # Status: posted is sticky.
    if c.status == "posted" and t.status == "pending":
        f["status"] = "posted"
    # Plaid ids always carried over when present.
    if c.plaid_transaction_id:
        f["plaid_transaction_id"] = c.plaid_transaction_id
    if c.plaid_pending_id:
        f["plaid_pending_id"] = c.plaid_pending_id
    if c.card_last4 and not t.card_last4:
        f["card_last4"] = c.card_last4
    if c.account_id and not t.account_id:
        f["account_id"] = c.account_id
    if c.category_id and not t.category_id and "category" not in t.user_edited:
        f["category_id"] = c.category_id
    # Corroboration: independent sources agreeing means the capture is trustworthy.
    conf = max(t.confidence, c.confidence)
    if t.sources and c.source != "manual" and reason in ("heuristic", "tip", "pending_to_posted"):
        conf = max(conf, 0.97)
    f["confidence"] = conf
    if reason == "heuristic_weak":
        f["needs_review"] = True              # a weak match is never silently accepted
    elif conf >= REVIEW_THRESHOLD:
        f["needs_review"] = False
    return f

def new_txn_fields(c: Candidate, *, user_review_threshold: float = REVIEW_THRESHOLD) -> dict[str, Any]:
    return {
        "amount_cents": c.amount_cents, "occurred_at": c.occurred_at, "merchant_raw": c.merchant_raw, "merchant_clean": c.merchant_clean or c.merchant_raw,
        "card_last4": c.card_last4, "status": c.status, "sources": [_source_entry(c)], "plaid_transaction_id": c.plaid_transaction_id,
        "plaid_pending_id": c.plaid_pending_id, "confidence": c.confidence, "needs_review": c.confidence < user_review_threshold,
        "account_id": c.account_id, "category_id": c.category_id,
    }

def decide(cand: Candidate, txns: list[Txn], *, category_names: dict[str, str] | None = None) -> Action:
    t, reason = find_match(cand, txns, category_names=category_names)
    if t is None:
        return Action("insert", None, new_txn_fields(cand), reason)
    if reason == "redelivery" and not _would_change(t, cand):
        return Action("noop", t.id, {}, reason)
    return Action("update", t.id, merge_fields(t, cand, reason), reason)

def _would_change(t: Txn, c: Candidate) -> bool:
    return t.status != c.status and c.status == "posted"

def apply_action(txns: list[Txn], a: Action, new_id: str) -> None:
    """Apply an Action to an in-memory ledger (used by tests and by the DB glue's dry-run)."""
    if a.kind == "insert":
        f = a.fields
        txns.append(Txn(id=new_id, amount_cents=f["amount_cents"], occurred_at=f["occurred_at"], merchant_raw=f["merchant_raw"], merchant_clean=f["merchant_clean"],
                        card_last4=f["card_last4"], status=f["status"], sources=f["sources"], plaid_transaction_id=f["plaid_transaction_id"],
                        plaid_pending_id=f["plaid_pending_id"], confidence=f["confidence"], needs_review=f["needs_review"], account_id=f["account_id"], category_id=f["category_id"]))
    elif a.kind == "update":
        t = next(x for x in txns if x.id == a.txn_id)
        for k, v in a.fields.items():
            setattr(t, k, v)

def _candidate_from_entry(e: dict) -> Candidate:
    is_plaid = e["source"] == "plaid"
    return Candidate(e["source"], e["ref"], e["amount_cents"], datetime.fromisoformat(e["at"]), e.get("merchant_raw") or "", "", e.get("card_last4"),
                     e.get("status", "posted"), plaid_transaction_id=e["ref"] if is_plaid else None, plaid_pending_id=e.get("pending_id"),
                     confidence=e.get("confidence", 1.0))

def _without(t: Txn, e: dict) -> Txn:
    rest = [x for x in t.sources if x is not e]
    best = max(rest, key=lambda x: (priority(x["source"], x.get("status", "posted")), x["source"])) if rest else None
    r = Txn(id=t.id, amount_cents=best["amount_cents"] if best else t.amount_cents, occurred_at=t.occurred_at, merchant_raw=t.merchant_raw,
            merchant_clean=t.merchant_clean, card_last4=t.card_last4, status=t.status, sources=rest, confidence=t.confidence, needs_review=t.needs_review,
            account_id=t.account_id, category_id=t.category_id, user_edited=set(t.user_edited))
    if e["source"] != "plaid":
        r.plaid_transaction_id, r.plaid_pending_id = t.plaid_transaction_id, t.plaid_pending_id
    return r

def plan(cand: Candidate, txns: list[Txn], *, category_names: dict[str, str] | None = None, depth: int = 0) -> list[Action]:
    """All actions needed to ingest [cand]. Usually one. When [cand] exactly matches a row whose slot for the same source is held only by a
    PROVISIONAL tip-merged entry, [cand] takes the slot back and the displaced entry is re-ingested on its own (exact beats tip, in any arrival order)."""
    if depth < 3:
        for t in txns:
            for e in t.sources:
                if e["source"] != cand.source or e.get("match") != "tip" or (e["ref"] == cand.ref):
                    continue
                r = _without(t, e)
                m, reason = find_match(cand, [r], category_names=category_names)
                if m is not None and reason == "heuristic" and cand.amount_cents == r.amount_cents:
                    fields = merge_fields(r, cand, "heuristic")
                    if e["source"] == "plaid" and not cand.plaid_transaction_id:
                        fields["plaid_transaction_id"] = None
                    elif e["source"] == "plaid":
                        fields["plaid_transaction_id"] = cand.plaid_transaction_id
                    first = Action("update", t.id, fields, "steal")
                    apply_action(txns, first, t.id)
                    return [first] + plan(_candidate_from_entry(e), txns, category_names=category_names, depth=depth + 1)
    return [decide(cand, txns, category_names=category_names)]

def ingest(txns: list[Txn], cand: Candidate, new_id: str, *, category_names: dict[str, str] | None = None) -> Action:
    acts = plan(cand, txns, category_names=category_names)
    last = acts[-1]
    if last.kind in ("insert", "update") and last.reason != "steal":
        apply_action(txns, last, new_id)
    return acts[0] if len(acts) == 1 else acts[-1]

def apply_plaid_removed(txns: list[Txn], removed_ids: list[str]) -> list[Action]:
    """Plaid reports removed transactions (e.g. a cancelled pending authorization). Delete if Plaid was the only source; otherwise
    detach the Plaid refs and fall back to the other sources, flagging the row for review (the hold may have been voided)."""
    out: list[Action] = []
    for t in list(txns):
        if t.plaid_transaction_id in removed_ids:
            others = [x for x in t.sources if x["source"] != "plaid"]
            if not others:
                txns.remove(t)
                out.append(Action("delete", t.id, {}, "plaid_removed"))
                continue
            best = max(others, key=lambda x: (priority(x["source"], x.get("status", "posted")), x["source"]))
            t.sources = others
            t.plaid_transaction_id = None
            t.plaid_pending_id = None
            if "amount" not in t.user_edited and "amount_cents" in best:
                t.amount_cents = best["amount_cents"]
            t.needs_review = True
            f = {"sources": others, "plaid_transaction_id": None, "plaid_pending_id": None, "amount_cents": t.amount_cents, "needs_review": True}
            out.append(Action("update", t.id, f, "plaid_removed_keep_others"))
    return out

def total_spend(txns: list[Txn]) -> int:
    return sum(-t.amount_cents for t in txns if t.amount_cents < 0)
