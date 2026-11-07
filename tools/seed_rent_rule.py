#!/usr/bin/env python3
"""Find the owner's Zelle payments to Kaarthik Roshan (any spelling or initials), detect the recurring amount and day, and create a Rent rule.
Dry run by default; --apply writes and applies to past rows. Prints counts and the amount band only."""
import json, os, pathlib, re, sys
HERE = pathlib.Path(__file__).parent
sys.path.insert(0, str(HERE)); sys.path.insert(0, str(HERE.parent / "api"))
from db import query
from set_payday import owner_id
from app.rules import detect

KEY = "kaarthik roshan"

def is_him(person: str | None) -> bool:
    """Kaarthik Roshan, K Roshan, Karthik R, Roshan K. Not Kaarthik Kumar: he's someone else."""
    w = (person or "").split()
    first = any(re.fullmatch(r"k+a+r+t+h+i+c?k+|k", x) for x in w)
    last = any(re.fullmatch(r"roshan|r", x) for x in w)
    return first and last and any(len(x) > 1 for x in w)

def main():
    uid = owner_id()
    rows = query(f"select * from public.tick_p2p_rows('{uid}', 800)")
    his = [r for r in rows if is_him(r["person"])]
    aliases = sorted({r["person"] for r in his} - {KEY})
    found = detect([{**r, "person": KEY} for r in his if not r.get("edited")])
    print(f"payments to him: {len(his)}, spellings: {len(aliases) + (1 if any(r['person'] == KEY for r in his) else 0)}")
    if not found:
        print("no monthly pattern found: nothing to do")
        return
    d = found[0]
    lo, hi = round(d.amount_cents * .9), round(d.amount_cents * 1.1)
    print(f"rent: ${d.amount_cents / 100:,.2f} (band ${lo / 100:,.2f} to ${hi / 100:,.2f}), around day {d.day}, {d.count} payments in the run")
    if "--apply" not in sys.argv:
        print("dry run: nothing written. Add --apply.")
        return
    cat = query(f"select id from public.categories where user_id = '{uid}' and name = 'Rent'")[0]["id"]
    al = "array[" + ",".join("'" + a.replace("'", "''") + "'" for a in aliases) + "]::text[]" if aliases else "'{}'::text[]"
    if query(f"select id from public.category_rules where user_id = '{uid}' and person_key = '{KEY}' and category_id = '{cat}'"):
        print("a rule already exists: leaving it")
    else:
        query(f"insert into public.category_rules (user_id, person_key, aliases, display_name, amount_cents, day_of_month, category_id, source) values ('{uid}', '{KEY}', {al}, 'Kaarthik Roshan', {d.amount_cents}, {d.day}, '{cat}', 'seed')")
    query(f"select public.tick_apply_category_rules('{uid}')")
    n = query(f"select count(*) c from public.transactions where user_id = '{uid}' and category_rule_id is not null")
    print(f"rows now on the rule: {n[0]['c']}")

if __name__ == "__main__":
    main()
