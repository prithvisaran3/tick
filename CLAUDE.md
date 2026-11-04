# Tick — CLAUDE.md
Personal finance iPhone app for Prithvi (sole user). Full spec: `docs/SPEC.md` (authoritative; Section 7 = design system).

## How to resume
Read this file, then `docs/NEXT.md` (manual steps + phase checklist), `docs/DECISIONS.md`. Continue at the first unchecked phase. Unattended: never ask questions; decide, log in DECISIONS.md, continue. Update NEXT.md at the end of every phase; commit with `tools/commit.sh "msg"` (secret-scans, commits, pushes the current branch `claude/gifted-cannon-lkg2x3`).

## Stack
- `app/` Flutter (Dart 3, Riverpod 2, go_router, freezed, supabase_flutter). Custom widgets only — no visible Material look.
- `api/` Python 3.12 FastAPI on Railway (ingest, Plaid, Gemini, jobs, Ask Tick SSE). Supabase JWT on authed routes.
- `supabase/` migrations (applied with `supabase db push`), tests (RLS), seed.
- `design/` brand source of truth: tokens.json, haptics.json, motion.json, copy.md, brand-sheet.html, icons/, logo/, mockups/, exports/.
- `tools/` generators (`gen_tokens.py`, `compile_ahap.py`, `gen_sounds.py`), `contrast_check.py`, `secret_scan.py`, `commit.sh`.
- `ios/` native Swift lives under `app/ios` (TickHaptics plugin, widget, App Intent) — cannot be compiled here.

## Tooling (sandbox)
Flutter at `/opt/tools/flutter/bin` (add to PATH). Supabase CLI + Railway CLI via npm global. Python: `pytest` in `api/`. Playwright Chromium at /opt/pw-browsers.
Commands: `cd app && flutter analyze && flutter test` · `cd api && pytest` · `python3 tools/contrast_check.py` · `python3 tools/gen_tokens.py` · `python3 tools/compile_ahap.py` · `python3 tools/render_mockups.py`.

## Rules
- Secrets live only in env vars (names in `.env.example`). Never print/write/commit values. Never pass values to subagents.
- Money = integer cents, negative = out. All timestamps UTC in DB, America/New_York for display/“day” boundaries.
- Generated files (`app/lib/design/tokens.g.dart`, `.ahap` files) are never hand-edited; edit design/*.json and regenerate.
- Design: Ink #0E0E12, Volt #C8FF2E (fill only, text on Volt = Ink), Paper #F5F3EC, Graphite #5B5B66, Clay #FF6B4A, Sky #7AA7FF. Cabinet Grotesk/Satoshi/Geist Mono (fallback Bricolage Grotesque + JetBrains Mono, see DECISIONS). Radius 24 cards / 999 pills. Springs, no slideshow easing. Wordmark always lowercase "tick".
- Copy: lead with number/action, sentence case, max six branded terms (Safe to spend, Morning Receipt, Caught, Landed, Payday plan, Ask Tick). No humor on errors/money problems.
- Plaid: never create/remove production Items automatically; tests use PLAID_SANDBOX_SECRET; 10-item lifetime cap.
- Dedupe/reconcile, RLS, money math and Plaid tokens are written by the main session only.

## File map
See `docs/NEXT.md` for current state; each directory has its own README where useful.
