"""Statement import: POST /import/statement (preview or commit), POST /import/{batch}/undo, GET /import/batches.
Signed-in users only; a few imports a minute. Each commit is ONE batch, so "Undo import" removes exactly what it added."""
from __future__ import annotations

import csv

import json
import re
import uuid
from datetime import date, datetime, timedelta, timezone

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile

from . import applecard as AC
from . import splitwise as SW
from . import rules as category_rules
from . import paystubs as PS
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

PAY_PROBLEMS = {"pay_date": "Tick couldn't read the pay date. Enter it to import this.", "gross": "Tick couldn't read gross pay. Enter it to import this.",
                "net": "Tick couldn't read net pay. Enter it to import this."}

def _apply_fixes(st: PS.Statement, fixes: dict) -> list[str]:
    """What I corrected on the review screen. Totals stay the sum of their lines: a corrected total replaces that group's lines with one line."""
    done = []
    try:
        if fixes.get("pay_date"):
            st.pay_date = date.fromisoformat(str(fixes["pay_date"])[:10]); done.append("pay_date")
        if isinstance(fixes.get("employer"), str) and fixes["employer"].strip():
            st.employer = fixes["employer"].strip()[:120]; done.append("employer")
        for key, attr in (("gross_cents", "gross_cents"), ("net_cents", "net_cents")):
            if fixes.get(key) is not None:
                v = int(fixes[key])
                if not 0 < v < 100_000_000:
                    raise ValueError
                setattr(st, attr, v); done.append(key.removesuffix("_cents"))
        for key, kind, label in (("taxes_cents", "tax", "Taxes"), ("deductions_cents", "deduction", "Deductions")):
            if fixes.get(key) is not None:
                v = int(fixes[key])
                if not 0 <= v < 100_000_000:
                    raise ValueError
                if v != sum(l.cents for l in st.lines if l.kind == kind):
                    st.lines = [l for l in st.lines if l.kind != kind] + ([PS.Line(kind, label, v)] if v else [])
                    done.append(key.removesuffix("_cents"))
    except (ValueError, TypeError):
        raise HTTPException(422, "Check the amounts and the date, then try again.")
    if st.gross_cents and not any(l.kind == "earning" for l in st.lines):
        st.lines.insert(0, PS.Line("earning", "Earnings", st.gross_cents))
    return done

def _paystub(user_id: str, raw: bytes, mode: str, filename: str, fixes: dict | None = None) -> dict:
    """A PDF is a pay statement (bank statements come as CSV or OFX). Preview reads it and names anything it couldn't read; commit takes my
    fixes, saves it once, links its deposit, and sets the expected pay."""
    prof = rest().select("profiles", user_id=f"eq.{user_id}", select="display_name")
    names = [prof[0]["display_name"]] if prof and prof[0].get("display_name") else []
    try:
        st = PS.read(user_id, raw, names)
    except PS.PaystubError as e:
        text = ""
        try:
            text = PS.pdf_text(raw)
        except PS.PaystubError:
            pass
        if text.strip() and not PS.looks_like_paystub(text) and "password" not in str(e):
            raise HTTPException(422, "That PDF isn't a pay statement Tick can read. Bank statements come in as CSV or OFX.")
        raise HTTPException(422, str(e))
    fixed = _apply_fixes(st, fixes) if fixes else []
    problems = [{"field": f, "message": PAY_PROBLEMS[f]} for f in st.problems if f in PAY_PROBLEMS]
    if "adds_up" in st.problems:
        problems.append({"field": "adds_up", "message": f"Gross minus taxes and deductions is ${abs(st.off_by_cents) / 100:,.2f} away from net pay. Check the amounts."})
    if st.statements_in_file > 1:
        problems.append({"field": "file", "message": f"This PDF holds {st.statements_in_file} pay statements. Tick read the first one; import the others one at a time."})
    out = {"source": "paystub", "label": "Pay statement", "employer": st.employer, "pay_date": st.pay_date.isoformat() if st.pay_date else None, "gross_cents": st.gross_cents, "taxes_cents": st.taxes_cents,
           "deductions_cents": st.deductions_cents, "net_cents": st.net_cents, "adds_up": st.adds_up, "via": st.source, "new": 1, "duplicates": 0, "already_imported": 0, "unreadable": 0,
           "accounts": [], "needs_account": False, "empty": False, "sample": [], "problems": problems,
           "deposits": [{"label": d.label, "mask": d.mask, "cents": d.cents} for d in st.deposits],
           "lines": [{"kind": l.kind, "label": l.label, "cents": l.cents} for l in st.lines][:60]}
    if st.pay_date and st.net_cents:
        dupe = [s for s in rest().select("pay_statements", user_id=f"eq.{user_id}", pay_date=f"eq.{st.pay_date.isoformat()}", net_cents=f"eq.{st.net_cents}", select="id,employer")
                if s["employer"].lower() == st.employer.lower()]
        if dupe:
            return {**out, "new": 0, "already_imported": 1, "statement_id": dupe[0]["id"], "imported": 0}
    if mode == "preview":
        return out
    blocking = [p["message"] for p in problems if p["field"] in PAY_PROBLEMS]
    if blocking:
        raise HTTPException(422, blocking[0])
    row = rest().insert("pay_statements", {"user_id": user_id, "employer": st.employer, "pay_date": st.pay_date.isoformat(), "period_start": st.period_start.isoformat() if st.period_start else None,
                                           "period_end": st.period_end.isoformat() if st.period_end else None, "gross_cents": st.gross_cents, "taxes_cents": st.taxes_cents,
                                           "deductions_cents": st.deductions_cents, "net_cents": st.net_cents, "ytd": st.ytd, "status": "ok" if st.adds_up else "review",
                                           "source": st.source, "matched_txn": None, "deposits": out["deposits"], "problems": sorted(set(fixed))})[0]
    rest().insert("pay_statement_lines", [{"statement_id": row["id"], "user_id": user_id, "kind": l.kind, "label": l.label, "cents": l.cents, "ytd_cents": l.ytd_cents, "sort": i}
                                          for i, l in enumerate(st.lines)], returning=False)
    keep = rest().select("settings", user_id=f"eq.{user_id}", select="keep_pay_pdfs")
    if keep and keep[0].get("keep_pay_pdfs"):
        path = f"{user_id}/{row['id']}.pdf"
        if PS.keep_pdf(path, raw):
            rest().update("pay_statements", {"id": row["id"], "user_id": user_id}, {"pdf_path": path})
    link_paystubs(user_id)
    audit(user_id, "import_batch", {"count": 1, "scope": "paystub"})
    return {**out, "statement_id": row["id"], "imported": 1}

def link_paystubs(user_id: str) -> int:
    """Each unlinked statement to its deposit(s). A paycheck split across accounts is several deposits: each statement line is matched to its own
    row (by the account's last digits when the statement gives them), every matched row reads "Paycheck · Nov 13", and none is used twice.
    Later expected paychecks follow the latest net, through the splits when there are any."""
    from . import splits as SP
    rule = ((rest().select("settings", user_id=f"eq.{user_id}", select="payday_rule") or [{}])[0].get("payday_rule")) or {}
    accounts = rest().select("accounts", user_id=f"eq.{user_id}", select="id,mask,type")
    splits = SP.load(user_id, rest())
    n = 0
    for s in rest().select("pay_statements", user_id=f"eq.{user_id}", matched_txn="is.null", select="id,employer,pay_date,net_cents,deposits"):
        d = date.fromisoformat(s["pay_date"])
        rows = rest().select("transactions", user_id=f"eq.{user_id}", occurred_at=f"gte.{(d - timedelta(days=4)).isoformat()}T00:00:00+00:00", select="id,amount_cents,occurred_at,account_id")
        parts: list[tuple[int, str | None]] = []                     # (cents, account or None for "any")
        deps = s.get("deposits") or []
        if len(deps) > 1:
            for dep in deps:
                acct = next((a["id"] for a in accounts if dep.get("mask") and a.get("mask") and str(a["mask"])[-2:] == str(dep["mask"])[-2:] and str(a["mask"])[-len(str(dep["mask"])):] == str(dep["mask"])[-len(str(a["mask"])):]), None)
                parts.append((int(dep["cents"]), acct))
        elif splits:
            parts = [(c, sp.get("account_id")) for sp, c in SP.per_account(s["net_cents"], splits) if sp.get("account_id")]
        if not parts:
            parts = [(s["net_cents"], rule.get("account_id"))]
        used, hits = set(), []
        for cents, acct in sorted(parts, key=lambda p: -p[0]):
            hit = PS.match_deposit(PS.Statement(employer=s["employer"], pay_date=d, net_cents=cents), [r for r in rows if r["id"] not in used], acct)
            if hit:
                used.add(hit["id"]); hits.append(hit)
        if not hits and len(parts) > 1:                              # the statement says split, the bank shows one deposit: fall back to the whole net
            hit = PS.match_deposit(PS.Statement(employer=s["employer"], pay_date=d, net_cents=s["net_cents"]), rows, None)
            hits = [hit] if hit else []
        if hits:
            rest().update("pay_statements", {"id": s["id"], "user_id": user_id}, {"matched_txn": hits[0]["id"]})
            for h in hits:
                rest().update("transactions", {"id": h["id"], "user_id": user_id}, {"note": f"Paycheck · {d:%b} {d.day}"})
            n += 1
    latest = rest().select("pay_statements", user_id=f"eq.{user_id}", select="net_cents,pay_date", order="pay_date.desc", limit="1")
    if latest:
        by_account = {sp["account_id"]: c for sp, c in SP.per_account(latest[0]["net_cents"], splits) if sp.get("account_id")}
        for e in rest().select("expected", user_id=f"eq.{user_id}", kind="eq.paycheck", status="eq.expected", select="id,expected_date,account_id"):
            if e["expected_date"] > latest[0]["pay_date"]:
                amount = by_account.get(e.get("account_id")) if e.get("account_id") else latest[0]["net_cents"]
                if amount:
                    rest().update("expected", {"id": e["id"]}, {"amount_cents": amount})
    return n

@router.get("/pay/splits/suggested")
def suggested_splits(user_id: str = Depends(current_user)):
    """Pre-fill for Profile > Pay > Where it goes: the latest statement's deposit lines as split lines. Nothing is saved."""
    from . import splits as SP
    user_limiter.check(f"splits:{user_id}", 30, 60)
    st = rest().select("pay_statements", user_id=f"eq.{user_id}", select="deposits,net_cents,pay_date", order="pay_date.desc", limit="1")
    if not st or len(st[0].get("deposits") or []) < 1:
        return {"splits": [], "net_cents": st[0]["net_cents"] if st else None}
    accounts = rest().select("accounts", user_id=f"eq.{user_id}", select="id,mask,type")
    return {"splits": SP.from_deposits(st[0]["deposits"], accounts), "net_cents": st[0]["net_cents"], "pay_date": st[0]["pay_date"]}

@router.post("/import/statement")
def import_statement(file: UploadFile = File(...), mode: str = Form("preview"), account_id: str | None = Form(None), mapping: str | None = Form(None),
                     me_member: str | None = Form(None, max_length=120), group_name: str | None = Form(None, max_length=60), fixes: str | None = Form(None, max_length=600),
                     user_id: str = Depends(current_user)):
    user_limiter.check(f"import:{user_id}", 8, 60)
    if mode not in ("preview", "commit"):
        raise HTTPException(422, "mode must be preview or commit")
    raw = file.file.read(ST.MAX_BYTES + 1)
    if len(raw) <= ST.MAX_BYTES and raw[:5] == b"%PDF-":
        try:
            fx = json.loads(fixes) if fixes else None
            if fx is not None and not isinstance(fx, dict):
                raise ValueError
        except ValueError:
            raise HTTPException(422, "Check the details and try again.")
        return _paystub(user_id, raw, mode, file.filename or "", fx)
    if raw[:5] == b"%PDF-":
        raise HTTPException(422, "That PDF is too big for one pay statement. Download a single statement from myADP and import that.")
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
        category_rules.apply(user_id)
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
