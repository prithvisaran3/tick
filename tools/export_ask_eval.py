#!/usr/bin/env python3
"""Writes the questions behind approved Ask Tick proposals (ask_memory kind 'eval') into api/tests/data/ask_eval_approved.json, so the eval keeps them.
Read-only against Supabase. Needs SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY in the environment; prints counts only, never values or keys.
Run: python3 tools/export_ask_eval.py"""
import json, os, pathlib, sys, urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / "api" / "tests" / "data" / "ask_eval_approved.json"

def main() -> int:
    url, key = os.environ.get("SUPABASE_URL"), os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
    if not url or not key:
        print("Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY first.")
        return 1
    req = urllib.request.Request(f"{url}/rest/v1/ask_memory?kind=eq.eval&select=value", headers={"apikey": key, "Authorization": f"Bearer {key}"})
    rows = json.loads(urllib.request.urlopen(req, timeout=20).read())
    cur = json.loads(OUT.read_text())
    have = {c["question"].lower() for c in cur["cases"]}
    added = [{"question": r["value"]["question"], "tool": r["value"]["tool"], "params": r["value"].get("params") or {}} for r in rows
             if isinstance(r.get("value"), dict) and r["value"].get("question") and r["value"]["question"].lower() not in have]
    cur["cases"] += added
    OUT.write_text(json.dumps(cur, indent=2) + "\n")
    print(f"added {len(added)}, total {len(cur['cases'])}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
