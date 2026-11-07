"""Statement import: POST /import/statement (preview or commit), POST /import/{batch}/undo, GET /import/batches.
Signed-in users only; a few imports a minute. Each commit is ONE batch, so "Undo import" removes exactly what it added."""
from __future__ import annotations

import csv

import json
import re
import uuid
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile

from . import applecard as AC
from . import splitwise as SW
from . import statements as ST
from . import store
from .audit import audit
from .auth import current_user, user_limiter
from .db import rest
from .merchants import looks_business
from .transfers import is_p2p, p2p_category

router = APIRouter()
SAMPLE = 6

def _account(user_id: str, account_id: str | None, parsed: ST.Parsed) -> dict | None:
    """The Tick account the rows go on. Apple Card files always go to the Apple Card account (created once, never on Plaid)."""
    if parsed.source == "apple_card":
        return {"id": store.apple_card_account(user_id), "type": "credit", "name": "Apple Card"}
    if not account_id:
        return None
    if not re.fullmatch(r"[0-9a-f\-]{36}", account_id):
        raise HTTPException(422, "Pick one of your accounts.")
    rows = rest().select("accounts", id=f"eq.{account_id}", user_id=f"eq.{user_id}", select="id,type,name,mask,institution")
    if not rows:
        raise HTTPException(404, "account not found")
    return rows[0]

def _suggest(user_id: str, parsed: ST.Parsed) -> list[dict]:
    want = {"credit": ("credit",), "cash": ("checking", "savings", "cash")}.get(parsed.kind or "", ("credit", "checking", "savings", "cash", "loan"))
    out = []
    for a in rest().select("accounts", user_id=f"eq.{user_id}", select="id,name,type,mask,institution"):
        if a["type"] in want:
            score = (1 if parsed.mask and a.get("mask") == parsed.mask else 0) + (1 if parsed.institution and (a.get("institution") or "").lower() == parsed.institution.lower() else 0)
            out.append({"id": a["id"], "label": f"{a.get('institution') or a['name']} ••{a['mask']}" if a.get("mask") else (a.get("institution") or a["name"]), "type": a["type"], "score": score})
    return sorted(out, key=lambda x: -x["score"])

def _existing(user_id: str, rows: list[AC.Row]) -> list[dict]:
    lo = datetime.combine(min(r.when for r in rows), datetime.min.time(), timezone.utc) - timedelta(days=AC.MATCH_DAYS + 1)
    hi = datetime.combine(max(r.when for r in rows), datetime.min.time(), timezone.utc) + timedelta(days=AC.MATCH_DAYS + 2)
    r = rest().c.get(f"{rest().base}/transactions", headers=rest().h, params=[
        ("user_id", f"eq.{user_id}"), ("occurred_at", f"gte.{lo.isoformat()}"), ("occurred_at", f"lte.{hi.isoformat()}"),
        ("select", "id,amount_cents,occurred_at,merchant_clean,merchant_raw,account_id,external_ref,sources"), ("limit", "20000")])
    r.raise_for_status()
    return r.json()

def _row_fields(row: AC.Row, acct: dict, name_to_id: dict[str, str], rules: dict[str, str]) -> dict:
    f = AC.row_fields(row, acct["id"], name_to_id, rules)
    text = row.merchant or row.description
    if is_p2p(text) and f.get("flow") is None and name_to_id.get("Friends and family") and (row.category in (None, "Other")):
        f["category_id"] = name_to_id.get(p2p_category(text)) or name_to_id["Friends and family"]
    if acct.get("type") in ("credit", "loan") and row.amount_cents > 0 and row.kind == "payment":
        f["flow"] = "transfer"                                  # a payment received on a card or loan is never income
    if row.amount_cents < 0 and looks_business(text) and acct.get("type") != "credit" or (row.amount_cents < 0 and looks_business(text)):
        f["tags"] = sorted(set(f.get("tags") or []) | {"business"})
    f["sources"] = [{**f["sources"][0], "source": "statement"}]
    return f

def _splitwise(user_id: str, raw: bytes, mode: str, filename: str, me: str | None, group_name: str | None) -> dict:
    """A Splitwise export is a Tally group, not bank rows. Preview says what would be added; commit needs to know which member is me."""
    try:
        ex = SW.parse(raw)
    except ST.StatementError as e:
        raise HTTPException(422, str(e))
    refs = {r["external_ref"].rsplit(":", 1)[0] for t in ("tally_expenses", "tally_settlements")
            for r in rest().select(t, user_id=f"eq.{user_id}", external_ref="like.splitwise:*", select="external_ref")}
    fresh = [i for i in ex.items if i.ref not in refs]
    prof = rest().select("profiles", user_id=f"eq.{user_id}", select="display_name")
    name = (group_name or re.sub(r"[_-]+", " ", filename.rsplit(".", 1)[0]).strip() or "Splitwise")[:60]
    out = {"source": "splitwise", "label": "Splitwise group", "group_name": name, "members": ex.members, "me_guess": SW.guess_me(ex.members, prof[0].get("display_name") if prof else None),
           "balances": ex.balances, "new": len(fresh), "already_imported": len(ex.items) - len(fresh), "duplicates": 0, "unreadable": ex.unreadable, "accounts": [], "needs_account": False,
           "empty": not ex.items, "sample": [{"date": i.when.isoformat(), "merchant": i.description, "cents": -i.cost_cents} for i in sorted(fresh, key=lambda i: i.when, reverse=True)[:SAMPLE]]}
    if mode == "preview" or not fresh:
        return {**out, "imported": 0} if mode == "commit" else out
    if me not in ex.members:
        raise HTTPException(422, "Pick which member is you.")
    batch = rest().insert("import_batches", {"user_id": user_id, "source": "splitwise", "filename": filename[:120], "rows_added": len(fresh), "rows_skipped": len(ex.items) - len(fresh)})[0]
    res = rest().rpc("tally_import_splitwise", {"p_uid": user_id, "p_batch": batch["id"], "p": SW.payload(ex, me, name, refs)})
    audit(user_id, "import_batch", {"count": len(fresh), "scope": "splitwise"})
    return {**out, "batch_id": batch["id"], "imported": len(fresh), "group_id": res.get("group_id")}

@router.post("/import/statement")
def import_statement(file: UploadFile = File(...), mode: str = Form("preview"), account_id: str | None = Form(None), mapping: str | None = Form(None),
                     me_member: str | None = Form(None, max_length=120), group_name: str | None = Form(None, max_length=60), user_id: str = Depends(current_user)):
    user_limiter.check(f"import:{user_id}", 8, 60)
    if mode not in ("preview", "commit"):
        raise HTTPException(422, "mode must be preview or commit")
    raw = file.file.read(ST.MAX_BYTES + 1)
    if len(raw) <= ST.MAX_BYTES and SW.looks_like(raw):
        return _splitwise(user_id, raw, mode, file.filename or "", me_member, group_name)
    try:
        m = json.loads(mapping) if mapping else None
        if m is not None and not isinstance(m, dict):
            raise ValueError
        parsed = ST.parse_statement(raw, file.filename or "", m)
    except (ST.StatementError, AC.ImportError_) as e:
        raise HTTPException(422, str(e))
    except (ValueError, csv.Error, OverflowError, IndexError, TypeError):
        raise HTTPException(422, "Check the details and try again.")
    if parsed.needs_mapping:
        return {"source": parsed.source, "label": parsed.label, "needs_mapping": parsed.needs_mapping}
    if not parsed.rows:
        return {"source": parsed.source, "label": parsed.label, "new": 0, "duplicates": 0, "already_imported": 0, "unreadable": parsed.unreadable, "sample": [],
                "accounts": _suggest(user_id, parsed), "needs_account": False, "empty": True}
    acct = _account(user_id, account_id, parsed)
    base = {"source": parsed.source, "label": parsed.label, "accounts": _suggest(user_id, parsed), "unreadable": parsed.unreadable,
            "date_from": min(r.when for r in parsed.rows).isoformat(), "date_to": max(r.when for r in parsed.rows).isoformat(), "total_rows": len(parsed.rows)}
    if acct is None:
        return {**base, "needs_account": True}
    existing = _existing(user_id, parsed.rows)
    imported = {e["external_ref"] for e in existing if e.get("external_ref")}
    live = existing                      # fuzzy pass sees earlier imports too (CSV then OFX of the same account must not double up)
    p = ST.plan(parsed.rows, live, imported, acct["id"])
    summary = {**base, "needs_account": False, "account_id": acct["id"], "new": len(p.inserts), "duplicates": len(p.duplicates), "already_imported": p.already_imported,
               "sample": [{"date": r.when.isoformat(), "merchant": r.merchant, "cents": r.amount_cents} for r in sorted(p.inserts, key=lambda r: r.when, reverse=True)[:SAMPLE]]}
    if mode == "preview" or not p.inserts:
        return {**summary, "imported": 0, "skipped_duplicates": len(p.duplicates)} if mode == "commit" else summary      # nothing new: no empty batch
    name_to_id, _ = store.category_maps(user_id)
    rules = store.learned_rules(user_id)
    batch = rest().insert("import_batches", {"user_id": user_id, "source": parsed.source, "account_id": acct["id"], "filename": (file.filename or "")[:120],
                                             "rows_added": len(p.inserts), "rows_skipped": len(p.duplicates) + p.already_imported})[0]
    with store.user_lock(user_id):
        rows = [{**_row_fields(r, acct, name_to_id, rules), "id": str(uuid.uuid4()), "user_id": user_id, "import_batch_id": batch["id"]} for r in p.inserts]
        for i in range(0, len(rows), 500):
            chunk = [{k: x.get(k) for k in sorted({k for y in rows[i:i + 500] for k in y})} for x in rows[i:i + 500]]
            rest().insert("transactions", chunk, returning=False, missing_default=True)
        for _, tid in p.duplicates:                              # a live capture now lives on the right account
            rest().update("transactions", {"id": tid, "user_id": user_id}, {"account_id": acct["id"]})
    try:
        from .plaid import pair_transfers
        pair_transfers(user_id, days=800)                        # statement payments pair with the checking side; Zelle becomes Friends and family
    except Exception:
        pass
    audit(user_id, "import_batch", {"count": len(p.inserts), "scope": parsed.source})
    return {**summary, "batch_id": batch["id"], "imported": len(p.inserts), "skipped_duplicates": len(p.duplicates)}

@router.post("/import/{batch_id}/undo")
def undo(batch_id: str, user_id: str = Depends(current_user)):
    user_limiter.check(f"import-undo:{user_id}", 8, 60)
    if not re.fullmatch(r"[0-9a-f\-]{36}", batch_id):
        raise HTTPException(404, "import not found")
    rows = rest().select("import_batches", id=f"eq.{batch_id}", user_id=f"eq.{user_id}")
    if not rows:
        raise HTTPException(404, "import not found")
    if rows[0].get("undone_at"):
        return {"undone": True, "removed": 0}
    gone = rest().select("transactions", user_id=f"eq.{user_id}", import_batch_id=f"eq.{batch_id}", select="id")
    rest().delete("transactions", {"user_id": user_id, "import_batch_id": batch_id})
    if rows[0].get("source") == "splitwise":
        for t in ("tally_expenses", "tally_settlements"):
            gone += rest().select(t, user_id=f"eq.{user_id}", import_batch_id=f"eq.{batch_id}", select="id")
            rest().delete(t, {"user_id": user_id, "import_batch_id": batch_id})
    rest().update("import_batches", {"id": batch_id, "user_id": user_id}, {"undone_at": datetime.now(timezone.utc).isoformat()})
    audit(user_id, "import_undone", {"count": len(gone)})
    return {"undone": True, "removed": len(gone)}

@router.get("/import/batches")
def batches(user_id: str = Depends(current_user)):
    return {"batches": rest().select("import_batches", user_id=f"eq.{user_id}", select="id,source,filename,rows_added,rows_skipped,created_at,undone_at", order="created_at.desc", limit="20")}
