#!/usr/bin/env python3
"""Read-only bank sync diagnosis. For every Plaid Item: institution, Item error, products consented and billed, webhook URL set,
transactions status (last success / failure), last webhook, accounts (type, subtype, mask) with the number of rows Tick holds vs what Plaid
returns for a THROWAWAY full /transactions/sync, and Tick's stored sync state.

Safe by construction: it only calls /item/get, /accounts/get, /transactions/sync (cursor starts empty and is never saved) and runs SELECTs.
It never creates, removes or updates an Item, never writes to the database, and never prints tokens, names, merchants or amounts.
Usage: python3 tools/plaid_doctor.py [--json]
Needs PLAID_CLIENT_ID, PLAID_SECRET (+PLAID_ENV), SUPABASE_ACCESS_TOKEN, SUPABASE_PROJECT_REF in the environment."""
import collections, json, os, pathlib, sys
ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "tools"), str(ROOT / "api")]
import db as D                       # noqa: E402
from app import plaid as P           # noqa: E402

def sel(sql):
    return D.query(sql)

def diagnose():
    prov = P.PlaidProvider(os.environ["PLAID_CLIENT_ID"], os.environ["PLAID_SECRET"], os.environ.get("PLAID_ENV", "production"), "https://example.invalid")
    # The new sync-state columns only exist after `supabase db push`; before that, report them as null instead of failing.
    have = {r["column_name"] for r in sel("select column_name from information_schema.columns where table_schema='public' and table_name='connections'")}
    cols = ["id", "institution", "item_id", "vault_secret_id", "status", "last_synced_at", "products", "error_code"]
    new = ["sync_state", "last_error", "initial_complete", "historical_complete", "last_attempt_at", "last_webhook_code", "last_webhook_at"]
    q = ", ".join(cols + [c if c in have else f"null as {c}" for c in new])
    conns = sel(f"select {q}, (cursor is not null) has_cursor from connections where provider = 'plaid' order by created_at")
    for c in conns:
        c["sync_state"] = c["sync_state"] or ("ok" if c["status"] == "active" and c["last_synced_at"] else c["status"])
        c["last_error"] = c["last_error"] or c.get("error_code")
    counts = {r["account_id"]: r["n"] for r in sel("select account_id, count(*) n from transactions where account_id is not null group by 1")}
    accts_db = sel("select id, connection_id, provider_account_id, mask, type, subtype from accounts")
    out = []
    for c in conns:
        rep = {"institution": c["institution"], "tick": {k: c[k] for k in ("status", "sync_state", "last_error", "initial_complete", "historical_complete", "last_synced_at",
                                                                          "last_attempt_at", "last_webhook_code", "last_webhook_at", "products", "has_cursor")}, "findings": []}
        tok = (sel(f"select public.tick_vault_get('{c['vault_secret_id']}') t") or [{}])[0].get("t")
        if not tok:
            rep["findings"].append("NO ACCESS TOKEN in Vault for this connection")
            out.append(rep); continue
        try:
            item = prov._post("/item/get", {"access_token": tok}); it, st = item["item"], item.get("status") or {}
            rep["plaid"] = {"error": (it.get("error") or {}).get("error_code"), "products": it.get("products"), "billed": it.get("billed_products"),
                            "consented": it.get("consented_products"), "webhook_url_set": bool(it.get("webhook")),
                            "transactions": st.get("transactions"), "last_webhook": {k: v for k, v in (st.get("last_webhook") or {}).items() if k in ("code_sent", "sent_at")},
                            "update_type": it.get("update_type"), "consent_expiration": it.get("consent_expiration_time")}
            if it.get("error"):
                rep["findings"].append(f"Item error {it['error'].get('error_code')}: re-authenticate with Link update mode (no new link)")
            if not it.get("webhook"):
                rep["findings"].append("no webhook URL on this Item: syncs depend on the cron safety net")
            if "transactions" not in (it.get("billed_products") or []) + (it.get("products") or []):
                rep["findings"].append("transactions product is not on this Item")
            if "liabilities" not in (it.get("consented_products") or []) and c["institution"] != "Chase":
                rep["findings"].append("liabilities not consented (cards will show owed and limit only)")
        except P.PlaidError as e:
            rep["plaid"] = {"item_get_error": e.code, "type": e.typ}
            rep["findings"].append(f"/item/get failed: {e.code}")
        mine = [a for a in accts_db if a["connection_id"] == c["id"]]
        try:
            pa = prov.accounts(tok)
        except P.PlaidError as e:
            pa = []; rep["findings"].append(f"/accounts/get failed: {e.code}")
        cursor, added, pages = None, [], 0
        try:
            while pages < 50:
                pg = prov.sync_page(tok, cursor); pages += 1
                added += pg["added"]; cursor = pg["next_cursor"]
                if not pg["has_more"]:
                    break
        except P.PlaidError as e:
            rep["findings"].append(f"/transactions/sync failed: {e.code}")
        by = collections.Counter(t["account_id"] for t in added)
        rep["accounts"] = []
        for a in pa:
            row = next((m for m in mine if m["provider_account_id"] == a["account_id"]), None)
            have = counts.get(row["id"], 0) if row else None
            rep["accounts"].append({"type": a["type"], "subtype": a.get("subtype"), "mask": a.get("mask"), "plaid_rows": by.get(a["account_id"], 0),
                                    "tick_rows": have, "in_tick": row is not None})
            if row is None:
                rep["findings"].append(f"account ••{a.get('mask')} is at Plaid but not in Tick")
            elif have is not None and by.get(a["account_id"], 0) > have:
                rep["findings"].append(f"account ••{a.get('mask')}: Plaid has {by[a['account_id']]} rows, Tick has {have}: run tools/repair_sync.py")
        if c["sync_state"] in ("pending", "syncing") and c["last_attempt_at"]:
            rep["findings"].append("Tick still says 'syncing': the last attempt did not finish")
        if c["sync_state"] == "error":
            rep["findings"].append(f"last sync failed in Tick: {c['last_error'] or c.get('status')}")
        out.append(rep)
    return out

def render(reports):
    lines = []
    for r in reports:
        lines.append(f"== {r['institution'] or '?'}")
        t = r["tick"]
        lines.append(f"   Tick: state={t['sync_state']} status={t['status']} error={t['last_error']} initial={t['initial_complete']} historical={t['historical_complete']} "
                     f"last_synced={t['last_synced_at']} last_webhook={t['last_webhook_code']} cursor={t['has_cursor']} products={t['products']}")
        p = r.get("plaid", {})
        if p:
            lines.append(f"   Plaid: error={p.get('error') or p.get('item_get_error')} products={p.get('products')} billed={p.get('billed')} consented={p.get('consented')} "
                         f"webhook_url={p.get('webhook_url_set')} txn_status={p.get('transactions')} last_webhook={p.get('last_webhook')}")
        for a in r.get("accounts", []):
            lines.append(f"   account {a['type']}/{a['subtype']} ••{a['mask']}: Plaid {a['plaid_rows']} rows, Tick {a['tick_rows']}")
        for f in r["findings"]:
            lines.append(f"   ! {f}")
        if not r["findings"]:
            lines.append("   all good")
    return "\n".join(lines)

if __name__ == "__main__":
    reps = diagnose()
    print(json.dumps(reps, indent=1, default=str) if "--json" in sys.argv else render(reps))
