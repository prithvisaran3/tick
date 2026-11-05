#!/usr/bin/env python3
"""Run on the Mac (reads .env): prints the `flutter run` command with --dart-define values for the iPhone.
Nothing is written to disk and nothing is committed. Only PUBLIC client config goes into the app: the Supabase URL and publishable key and the API URL.
(Google sign-in runs through Supabase, so no Google client ids are needed in the app any more.)"""
import pathlib, sys
root = pathlib.Path(__file__).resolve().parents[1]
envfile = root / ".env"
if not envfile.exists():
    sys.exit("No .env found. Run:  cp .env.example .env  then fill in SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY.")
env = {}
for line in envfile.read_text().splitlines():
    if "=" in line and not line.lstrip().startswith("#"):
        k, v = line.split("=", 1); env[k.strip()] = v.strip().strip('"').strip("'")
missing = [k for k in ("SUPABASE_URL", "SUPABASE_PUBLISHABLE_KEY") if not env.get(k)]
if missing:
    sys.exit("Missing in .env: " + ", ".join(missing))
api = env.get("API_BASE_URL") or "https://tick-api-production.up.railway.app"
print("cd app && flutter run \\")
print(f"  --dart-define=SUPABASE_URL={env['SUPABASE_URL']} \\")
print(f"  --dart-define=SUPABASE_PUBLISHABLE_KEY={env['SUPABASE_PUBLISHABLE_KEY']} \\")
print(f"  --dart-define=API_BASE_URL={api}")
print()
print("For a smooth-scrolling check, run the same command with --profile (or --release) instead of debug mode; add")
print("  --dart-define=TICK_PERF=true   to see Flutter's performance overlay.")
