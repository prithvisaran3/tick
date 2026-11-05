#!/usr/bin/env python3
"""Throwaway LOCAL Postgres for migrations + RLS tests. Never touches the Supabase project.
Usage: local_db.py test     fresh cluster -> stub platform schemas -> every migration in order -> supabase/tests/rls.sql
       local_db.py sql 'q'  run SQL against the running local cluster
Needs PostgreSQL 16 binaries (/usr/lib/postgresql/16/bin). Installs stub pg_net/pg_cron extension files if missing."""
import os, pathlib, shutil, subprocess, sys, time
ROOT = pathlib.Path(__file__).resolve().parents[1]
BIN = pathlib.Path(os.environ.get("PG_BIN", "/usr/lib/postgresql/16/bin"))
DATA = pathlib.Path(os.environ.get("TICK_PGDATA", "/tmp/tick-localpg"))
PORT = os.environ.get("TICK_PGPORT", "54329")
LOCAL = ROOT / "supabase/tests/local"

def run(*a, **kw):
    return subprocess.run([str(x) for x in a], check=True, **kw)

def as_pg(cmd):
    """initdb/pg_ctl refuse to run as root; use the postgres OS user when we are root."""
    if os.geteuid() == 0:
        return ["su", "postgres", "-s", "/bin/sh", "-c", " ".join(f"'{c}'" for c in cmd)]
    return cmd

def psql(sql=None, file=None, db="tick", check=True):
    args = [str(BIN / "psql"), "-h", "127.0.0.1", "-p", PORT, "-U", "postgres", "-d", db, "-v", "ON_ERROR_STOP=1", "-q", "-X"]
    args += ["-f", str(file)] if file else ["-c", sql]
    return subprocess.run(args, capture_output=True, text=True, check=check)

def fresh():
    share = pathlib.Path(subprocess.run([str(BIN / "pg_config"), "--sharedir"], capture_output=True, text=True).stdout.strip()) / "extension"
    for f in LOCAL.glob("pg_*"):
        if not (share / f.name).exists():
            shutil.copy(f, share / f.name)
    subprocess.run(as_pg([str(BIN / "pg_ctl"), "-D", str(DATA), "-m", "immediate", "stop"]), capture_output=True)
    shutil.rmtree(DATA, ignore_errors=True)
    DATA.mkdir(parents=True)
    if os.geteuid() == 0:
        shutil.chown(DATA, "postgres", "postgres")
    run(*as_pg([str(BIN / "initdb"), "-D", str(DATA), "-U", "postgres", "--auth=trust", "-E", "UTF8"]), capture_output=True)
    run(*as_pg([str(BIN / "pg_ctl"), "-D", str(DATA), "-o", f"-p {PORT} -k /tmp -c listen_addresses=127.0.0.1", "-l", str(DATA / "log"), "-w", "start"]), capture_output=True)
    psql("create database tick", db="postgres")
    psql(file=LOCAL / "stub.sql")
    for m in sorted((ROOT / "supabase/migrations").glob("*.sql")):
        r = psql(file=m, check=False)
        if r.returncode:
            sys.exit(f"migration {m.name} failed:\n{r.stderr[-2000:]}")
    print(f"applied {len(list((ROOT / 'supabase/migrations').glob('*.sql')))} migrations")

if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "test"
    if cmd == "test":
        fresh()
        r = psql(file=ROOT / "supabase/tests/rls.sql", check=False)
        out = r.stdout + r.stderr
        if "RLS_TESTS_PASSED" in out:
            print("RLS tests passed (local)"); sys.exit(0)
        print(out[-3000:]); sys.exit(1)
    elif cmd == "fresh":
        fresh()
    elif cmd == "sql":
        r = psql(sys.argv[2], check=False); print(r.stdout, r.stderr)
