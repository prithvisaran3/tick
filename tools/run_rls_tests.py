#!/usr/bin/env python3
"""Run supabase/tests/rls.sql against the linked project; the script raises RLS_TESTS_PASSED to roll back cleanly."""
import pathlib, subprocess, sys
r = subprocess.run([sys.executable, str(pathlib.Path(__file__).parent / "db.py"), "file", str(pathlib.Path(__file__).parents[1] / "supabase/tests/rls.sql")], capture_output=True, text=True)
out = r.stdout + r.stderr
if "RLS_TESTS_PASSED" in out:
    print("RLS tests passed"); sys.exit(0)
print(out[-1500:]); sys.exit(1)
