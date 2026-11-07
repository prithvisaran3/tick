#!/usr/bin/env python3
"""Set the OWNER's payday to biweekly with next payday 2026-11-13. Dry run by default; --apply writes.
Prints the schedule only: never an email, an amount or a secret. Keeps the existing take-home amount."""
import json, os, pathlib, sys
sys.path.insert(0, str(pathlib.Path(__file__).parent))
from db import query
ANCHOR = "2026-11-13"

def owner_id() -> str:
    """The same rule as plaid.owners(): TICK_OWNER_USER_IDS, else whoever made the first bank link."""
    env = [x.strip() for x in os.environ.get("TICK_OWNER_USER_IDS", "").split(",") if x.strip()]
    if env:
        return env[0]
    rows = query("select user_id from public.plaid_items order by created_at asc limit 1")
    if not rows:
        sys.exit("no owner found")
    return rows[0]["user_id"]

def main():
    uid = owner_id()
    rows = query(f"select payday_rule from public.settings where user_id = '{uid}'")
    old = (rows[0].get("payday_rule") if rows else None) or {}
    if isinstance(old, str):
        old = json.loads(old)
    new = {"amount_cents": 0, **old, "frequency": "biweekly", "next_date": ANCHOR}
    new.pop("days", None)
    print(f"now:  {old.get('frequency')} from {old.get('next_date')}")
    print(f"then: biweekly from {ANCHOR}")
    if "--apply" not in sys.argv:
        print("dry run: nothing written. Add --apply.")
        return
    query(f"update public.settings set payday_rule = '{json.dumps(new)}'::jsonb where user_id = '{uid}'")
    print("period:", query(f"select * from public.pay_period('{uid}')"))

if __name__ == "__main__":
    main()
