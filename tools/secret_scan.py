#!/usr/bin/env python3
"""Scan for secrets. Modes:
  secret_scan.py               staged diff (used by tools/commit.sh and the pre-commit hook)
  secret_scan.py --tree        every tracked file in the working tree
  secret_scan.py --history     every line ever added in any commit on any branch (git log -p --all)
  secret_scan.py FILE...       the given files

Checks (1) generic key patterns and (2) the literal values of Tick's env vars
that are present in this process's environment. Never prints a secret value;
only the variable name / pattern name and file:line.
Exit 1 on any match.
"""
import os, re, subprocess, sys

ENV_NAMES = """SUPABASE_ACCESS_TOKEN SUPABASE_SECRET_KEY SUPABASE_DB_PASSWORD
GOOGLE_OAUTH_WEB_CLIENT_SECRET GEMINI_API_KEY PLAID_SECRET PLAID_SANDBOX_SECRET
RAILWAY_TOKEN OPENROUTER_API_KEY CRON_SECRET SUPABASE_PUBLISHABLE_KEY PLAID_CLIENT_ID
GOOGLE_OAUTH_WEB_CLIENT_ID GOOGLE_OAUTH_IOS_CLIENT_ID""".split()
PATTERNS = {
    "supabase_pat": r"sbp_[0-9a-f]{20,}",
    "supabase_secret": r"sb_secret_[A-Za-z0-9_\-]{10,}",
    "google_api_key": r"AIza[0-9A-Za-z_\-]{30,}",
    "google_client_secret": r"GOCSPX-[0-9A-Za-z_\-]{10,}",
    "private_key": r"-----BEGIN [A-Z ]*PRIVATE KEY-----",
    "jwt": r"eyJ[A-Za-z0-9_\-]{15,}\.eyJ[A-Za-z0-9_\-]{15,}\.[A-Za-z0-9_\-]{10,}",
    "openrouter_key": r"sk-or-v1-[0-9a-f]{20,}",
    "plaid_access": r"access-(sandbox|production|development)-[0-9a-f\-]{20,}",
    "plaid_public": r"public-(sandbox|production|development)-[0-9a-f\-]{20,}",
    "github_token": r"(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}",
    "aws_key": r"AKIA[0-9A-Z]{16}",
    "slack_token": r"xox[abprs]-[A-Za-z0-9-]{10,}",
    "stripe_live": r"sk_live_[0-9a-zA-Z]{20,}",
    "anthropic_key": r"sk-ant-[A-Za-z0-9_\-]{20,}",
    "openai_key": r"sk-(proj-)?[A-Za-z0-9]{32,}",
    "tick_capture_token": r"tk_[A-Za-z0-9_\-]{40,}",
    "assigned_secret": r"(?i)(secret|password|api_?key|token)[\"']?\s*[:=]\s*[\"'][A-Za-z0-9_\-/+]{24,}[\"']",
}
# Known-safe test fixtures (fake values that only look like secrets).
ALLOW = re.compile(r"sk-or-v1-abc|tk_x\b|tk_test|FAKE|fake-|example|placeholder|xxxxxxxx|link-production-abc123456", re.I)  # last: an old test fixture in history

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

def tree_lines():
    files = subprocess.run(["git", "ls-files"], capture_output=True, text=True).stdout.splitlines()
    yield from file_lines(f for f in files if not f.endswith((".png", ".ttf", ".otf", ".ahap", ".caf", ".wav", ".ico", ".jpg")))

def history_lines():
    """Every added line in every commit reachable from any ref (rewritten-away secrets still count: they are in the object store)."""
    p = subprocess.Popen(["git", "log", "-p", "--all", "--no-color", "-U0", "--no-ext-diff", "--format=commit %H"], stdout=subprocess.PIPE, text=True, errors="ignore")
    commit, cur = "", None
    for line in p.stdout:
        if line.startswith("commit "):
            commit = line.split()[1][:9]
        elif line.startswith("+++ b/"):
            cur = line[6:].rstrip("\n")
        elif line.startswith("+") and not line.startswith("+++"):
            yield f"{commit}:{cur}", 0, line[1:]

def file_lines(paths):
    for p in paths:
        try:
            for i, l in enumerate(open(p, errors="ignore"), 1):
                yield p, i, l
        except OSError:
            pass

def main():
    args = sys.argv[1:]
    if args == ["--tree"]:
        lines = tree_lines()
    elif args == ["--history"]:
        lines = history_lines()
    else:
        lines = file_lines(args) if args else staged_added_lines()
    literals = {n: os.environ[n] for n in ENV_NAMES
                if len(os.environ.get(n, "")) >= 8}
    hits = []
    for path, ln, text in lines:
        if path and (path.endswith("tools/secret_scan.py") or path.endswith("tests/test_security.py")):
            continue
        for n, v in literals.items():
            if v in text:
                hits.append((path, ln, f"literal value of ${n}"))
        for name, pat in PATTERNS.items():
            m = re.search(pat, text)
            if m and not ALLOW.search(m.group(0)):
                hits.append((path, ln, f"pattern {name}"))
    for h in hits:
        print(f"SECRET? {h[0]}:{h[1]}: {h[2]}", file=sys.stderr)
    if hits:
        print("secret scan FAILED; commit aborted", file=sys.stderr)
        sys.exit(1)
    print("secret scan clean")

main()
