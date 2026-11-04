#!/usr/bin/env python3
"""Run on the Mac (reads .env): writes app/ios/Flutter/Local.xcconfig (gitignored) with the reversed Google iOS client id,
and prints the flutter run command with --dart-define values. Never commit the outputs."""
import pathlib, sys
root = pathlib.Path(__file__).resolve().parents[1]
env = {}
for line in (root / ".env").read_text().splitlines():
    if "=" in line and not line.startswith("#"):
        k, v = line.split("=", 1); env[k.strip()] = v.strip().strip('"').strip("'")
ios = env["GOOGLE_OAUTH_IOS_CLIENT_ID"]
rev = "com.googleusercontent.apps." + ios.removesuffix(".apps.googleusercontent.com")
(root / "app/ios/Flutter/Local.xcconfig").write_text(f"GOOGLE_REVERSED_CLIENT_ID={rev}\n")
api = env.get("API_BASE_URL", "https://tick-api-production.up.railway.app")
print("cd app && flutter run \\")
for k in ("SUPABASE_URL", "SUPABASE_PUBLISHABLE_KEY", "GOOGLE_OAUTH_IOS_CLIENT_ID", "GOOGLE_OAUTH_WEB_CLIENT_ID"):
    print(f"  --dart-define={k}={env[k]} \\")
print(f"  --dart-define=API_BASE_URL={api}")
print()
print("Note: OPENROUTER_API_KEY is a SERVER secret (already set on Railway). The app never receives it, so it is not in the command above.")
