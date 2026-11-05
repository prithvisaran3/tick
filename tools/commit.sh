#!/usr/bin/env bash
# Usage: tools/commit.sh "message"  -> secret-scan staged diff, commit, push.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
git add -A
python3 tools/secret_scan.py
git commit -q -m "$1

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UwJh9Mm7ccJDdnjFGmSEur"
BR=$(git rev-parse --abbrev-ref HEAD)
for d in 0 2 4 8 16; do sleep $d; git push -u origin "$BR" && exit 0; done
echo "push failed" >&2; exit 1
