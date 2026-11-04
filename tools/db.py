#!/usr/bin/env python3
"""Run SQL against the linked Supabase project through the Management API (HTTPS only; the sandbox can't reach Postgres directly).
Usage: db.py push            apply unapplied supabase/migrations/*.sql, record in supabase_migrations.schema_migrations
       db.py sql 'select 1'  run ad-hoc SQL, print JSON rows
       db.py file path.sql   run a file (used by RLS tests)
Reads SUPABASE_ACCESS_TOKEN and SUPABASE_PROJECT_REF from the environment; never prints them."""
import json, os, pathlib, sys, urllib.request, urllib.error
ROOT = pathlib.Path(__file__).resolve().parents[1]

def query(sql):
    ref, tok = os.environ["SUPABASE_PROJECT_REF"], os.environ["SUPABASE_ACCESS_TOKEN"]
    req = urllib.request.Request(f"https://api.supabase.com/v1/projects/{ref}/database/query",
        data=json.dumps({"query": sql}).encode(), method="POST",
        headers={"Authorization": f"Bearer {tok}", "Content-Type": "application/json", "User-Agent": "tick-tools"})
    try:
        with urllib.request.urlopen(req, timeout=120) as r: return json.loads(r.read() or "null")
    except urllib.error.HTTPError as e:
        raise SystemExit(f"SQL error {e.code}: {e.read().decode()[:1500]}")

def push():
    query("create schema if not exists supabase_migrations; create table if not exists supabase_migrations.schema_migrations (version text primary key, name text, statements text[]);")
    done = {r["version"] for r in query("select version from supabase_migrations.schema_migrations")}
    for f in sorted((ROOT / "supabase/migrations").glob("*.sql")):
        v, _, name = f.stem.partition("_")
        if v in done: continue
        print("applying", f.name); query(f.read_text())
        query(f"insert into supabase_migrations.schema_migrations(version,name) values ('{v}','{name}')")
    print("up to date")

if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "push": push()
    elif cmd == "sql": print(json.dumps(query(sys.argv[2]), indent=1))
    elif cmd == "file": print(json.dumps(query(pathlib.Path(sys.argv[2]).read_text()), indent=1))
