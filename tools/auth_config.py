#!/usr/bin/env python3
"""Check (and, only with --apply, fix) the Supabase Auth settings Tick relies on, through the Management API.
Default is READ-ONLY: it prints which settings differ from the target and never prints a secret.
  python3 tools/auth_config.py            # report
  python3 tools/auth_config.py --apply    # PATCH the differences (run this yourself after reading the report)"""
import json, os, sys, urllib.request, urllib.error

TARGET = {
    "disable_signup": False,                     # Google sign-in must still create the first account
    "external_email_enabled": False,             # no email/password sign-up or sign-in
    "external_phone_enabled": False,
    "external_anonymous_users_enabled": False,
    "external_google_enabled": True,
    "external_apple_enabled": False, "external_github_enabled": False, "external_azure_enabled": False, "external_facebook_enabled": False,
    "external_twitter_enabled": False, "external_discord_enabled": False, "external_gitlab_enabled": False,
    "uri_allow_list": "tick://login-callback",   # the only redirect the app uses
    "jwt_exp": 900,                              # 15-minute access tokens; the app refreshes before expiry
    "refresh_token_rotation_enabled": True,
    "security_refresh_token_reuse_interval": 10,
    "mailer_autoconfirm": False,
}

def call(method, body=None):
    ref, tok = os.environ["SUPABASE_PROJECT_REF"], os.environ["SUPABASE_ACCESS_TOKEN"]
    req = urllib.request.Request(f"https://api.supabase.com/v1/projects/{ref}/config/auth", method=method,
                                 data=None if body is None else json.dumps(body).encode(),
                                 headers={"Authorization": f"Bearer {tok}", "Content-Type": "application/json", "User-Agent": "tick-tools"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read() or "{}")

def main():
    cur = call("GET")
    diff = {k: v for k, v in TARGET.items() if k in cur and cur[k] != v}
    missing = [k for k in TARGET if k not in cur]
    for k, v in TARGET.items():
        if k in cur:
            print(f"{'OK  ' if k not in diff else 'FIX '} {k}: now={cur[k]!r} target={v!r}")
    for k in missing:
        print(f"?    {k}: not reported by this API version")
    if "--apply" in sys.argv and diff:
        call("PATCH", diff)
        print(f"applied {len(diff)} change(s)")
    elif diff:
        print(f"\n{len(diff)} setting(s) differ. Review, then run with --apply (or change them in the dashboard).")
    sys.exit(1 if diff else 0)

if __name__ == "__main__":
    main()
