#!/usr/bin/env python3
"""Repair bank sync for the live data. IDEMPOTENT. Default is --dry-run: reads Plaid and the database, writes NOTHING.

For every Plaid Item it (1) runs a fresh full /transactions/sync from an empty cursor, (2) reports which transactions are missing from Tick
(by plaid_transaction_id), (3) with --apply runs the real sync from an empty cursor so every missed row is reconciled in (re-running adds
nothing twice), then recomputes sync state, fills account institutions and re-applies the money rules (transfer pairing, Zelle to people,
cross-bank transfers) to existing rows. Never creates or removes an Item; never prints tokens, merchants or amounts.

Run AFTER `supabase db push` and the API deploy:
  python3 tools/repair_sync.py            # dry run
  python3 tools/repair_sync.py --apply
Needs the same env as the API (SUPABASE_URL, SUPABASE_SECRET_KEY, PLAID_CLIENT_ID, PLAID_SECRET, PLAID_ENV) plus SUPABASE_ACCESS_TOKEN for reads."""
import os, pathlib, sys
ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "api")]
from app import plaid as P          # noqa: E402
from app.db import rest             # noqa: E402

def main(apply: bool) -> int:
    prov = P.provider()
    conns = [c for c in rest().select("connections", provider="eq.plaid") if c.get("vault_secret_id") and c.get("status") != "removed"]
    print(f"{'APPLY' if apply else 'DRY RUN'}: {len(conns)} Item(s)")
    total_missing = 0
    for c in conns:
        label = c.get("institution") or "?"
        token = rest().rpc("tick_vault_get", {"secret_id": c["vault_secret_id"]})
        if not token:
            print(f"- {label}: no access token in Vault, skipped"); continue
        have = {r["plaid_transaction_id"] for r in rest().select("transactions", user_id=f"eq.{c['user_id']}", select="plaid_transaction_id", plaid_transaction_id="not.is.null")}
        cursor, seen, pages = None, [], 0
        try:
            while pages < 100:
                pg = prov.sync_page(token, cursor); pages += 1
                seen += [t["transaction_id"] for t in pg["added"] + pg["modified"]]
                cursor = pg["next_cursor"]
                if not pg["has_more"]:
                    break
        except P.PlaidError as e:
            print(f"- {label}: Plaid refused the sync ({e.code}); state -> {P.state_for_error(e.code)}")
            if apply:
                P.mark(c["id"], sync_state=P.state_for_error(e.code), last_error=e.code)
            continue
        missing = [i for i in seen if i not in have]
        total_missing += len(missing)
        print(f"- {label}: Plaid has {len(seen)} rows, Tick is missing {len(missing)}")
        if apply:
            # Fresh full sync: cursor back to empty; reconcile is idempotent so existing rows are matched, not duplicated.
            rest().update("connections", {"id": c["id"]}, {"cursor": None})
            P.sync_connection({**c, "cursor": None, "historical_complete": True}, prov)
            now = rest().select("connections", id=f"eq.{c['id']}")[0]
            print(f"    -> state {now.get('sync_state')}, last_added {now.get('last_added')}")
            for a in rest().select("accounts", connection_id=f"eq.{c['id']}", select="id,institution"):
                if not a.get("institution") and c.get("institution"):
                    rest().update("accounts", {"id": a["id"]}, {"institution": c["institution"]})
    try:
        from app import repairs           # money-rule re-application (Part 1)
        for uid in {c["user_id"] for c in conns}:
            r = repairs.reclassify(uid, apply=apply)
            print(f"- money rules for one user: {r['changed']} row(s) {'reclassified' if apply else 'would be reclassified'} ({r['summary']})")
    except ImportError:
        pass
    print(f"\n{total_missing} missing row(s) in total." + ("" if apply else " Re-run with --apply to repair."))
    return 0

if __name__ == "__main__":
    sys.exit(main("--apply" in sys.argv))
