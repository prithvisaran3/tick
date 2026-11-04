#!/usr/bin/env python3
"""Scan the staged diff (or given files) for secrets.

Checks (1) generic key patterns and (2) the literal values of Tick's env vars
that are present in this process's environment. Never prints a secret value;
only the variable name / pattern name and file:line.
Exit 1 on any match.
"""
import os, re, subprocess, sys

ENV_NAMES = """SUPABASE_ACCESS_TOKEN SUPABASE_SECRET_KEY SUPABASE_DB_PASSWORD
GOOGLE_OAUTH_WEB_CLIENT_SECRET GEMINI_API_KEY PLAID_SECRET PLAID_SANDBOX_SECRET
RAILWAY_TOKEN CRON_SECRET SUPABASE_PUBLISHABLE_KEY PLAID_CLIENT_ID
GOOGLE_OAUTH_WEB_CLIENT_ID GOOGLE_OAUTH_IOS_CLIENT_ID""".split()
PATTERNS = {
    "supabase_pat": r"sbp_[0-9a-f]{20,}",
    "supabase_secret": r"sb_secret_[A-Za-z0-9_\-]{10,}",
    "google_api_key": r"AIza[0-9A-Za-z_\-]{30,}",
    "google_client_secret": r"GOCSPX-[0-9A-Za-z_\-]{10,}",
    "private_key": r"-----BEGIN [A-Z ]*PRIVATE KEY-----",
    "jwt": r"eyJ[A-Za-z0-9_\-]{15,}\.eyJ[A-Za-z0-9_\-]{15,}\.[A-Za-z0-9_\-]{10,}",
    "plaid_access": r"access-(sandbox|production|development)-[0-9a-f\-]{20,}",
}

def staged_added_lines():
    out = subprocess.run(["git", "diff", "--cached", "-U0", "--no-color"],
                         capture_output=True, text=True).stdout
    cur, ln = None, 0
    for line in out.splitlines():
        if line.startswith("+++ b/"):
            cur = line[6:]
        elif line.startswith("@@"):
            m = re.search(r"\+(\d+)", line)
            ln = int(m.group(1)) - 1 if m else 0
        elif line.startswith("+") and not line.startswith("+++"):
            ln += 1
            yield cur, ln, line[1:]

def file_lines(paths):
    for p in paths:
        try:
            for i, l in enumerate(open(p, errors="ignore"), 1):
                yield p, i, l
        except OSError:
            pass

def main():
    lines = file_lines(sys.argv[1:]) if len(sys.argv) > 1 else staged_added_lines()
    literals = {n: os.environ[n] for n in ENV_NAMES
                if len(os.environ.get(n, "")) >= 8}
    hits = []
    for path, ln, text in lines:
        if path and path.endswith("tools/secret_scan.py"):
            continue
        for n, v in literals.items():
            if v in text:
                hits.append((path, ln, f"literal value of ${n}"))
        for name, pat in PATTERNS.items():
            if re.search(pat, text):
                hits.append((path, ln, f"pattern {name}"))
    for h in hits:
        print(f"SECRET? {h[0]}:{h[1]}: {h[2]}", file=sys.stderr)
    if hits:
        print("secret scan FAILED; commit aborted", file=sys.stderr)
        sys.exit(1)
    print("secret scan clean")

main()
