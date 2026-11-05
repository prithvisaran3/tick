#!/usr/bin/env python3
"""Run every supabase/tests/*.sql suite (rls, attacks, flows) against the LINKED project. Each suite raises *_TESTS_PASSED at the end,
so its transaction always rolls back and nothing persists. Run it after `supabase db push` (the suites expect every migration applied).
For a throwaway local database instead, use tools/local_db.py test."""
import pathlib, subprocess, sys
ok = True
for f in sorted((pathlib.Path(__file__).parents[1] / "supabase/tests").glob("*.sql")):
    r = subprocess.run([sys.executable, str(pathlib.Path(__file__).parent / "db.py"), "file", str(f)], capture_output=True, text=True)
    out = r.stdout + r.stderr
    if "_TESTS_PASSED" in out and "_TESTS_FAILED" not in out:
        print(f"{f.name}: passed")
    else:
        ok = False; print(f"{f.name}: FAILED\n{out[-1500:]}")
sys.exit(0 if ok else 1)
