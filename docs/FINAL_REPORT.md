# Tick — final report

## Final polish session (branch `feat/final-polish`, PR #3) — read this first

### What changed, per part
- **0 Bank sync.** Root cause of "Syncing forever": Plaid rows with differing keys made PostgREST bulk inserts fail (rows now normalised, `Prefer: missing=default`, per-row fallback); plus a first-sync status race, stuck connections (cron safety net every 10 min), webhooks (initial/historical/removed/errors) and honest per-bank status in the UI. Tools: `tools/plaid_doctor.py` (read-only), `tools/repair_sync.py` (dry-run default, `--apply`). Details: `docs/SYNC_DIAGNOSIS.md`.
- **1 Money rules** in one SQL source (`tick_classified`, `tick_flows`), `docs/MONEY_RULES.md`, shared fixtures, Dart mirror property-tested; Chase↔SoFi cross-institution transfer pairing; Zelle to/from people is real money; day/month totals equal visible rows.
- **2 Activity** one continuous list with keyset paging and month headers carrying totals (5,000-row test). **3 Navigation** Today · Activity · Insights · Tally with Ask Tick as a sheet.
- **4 Statement import**: Open in Tick, Shortcuts action, CSV/OFX/Apple Card detection, preview, dedupe, undoable batches, statement-day notification (`docs/SHORTCUTS_SETUP.md`).
- **5 Settings** sparse; large title no longer clips.
- **6 Tally**: groups and 1:1, equal/exact/percent/shares, balances, simplify, settle-up records, Zelle match suggestions (name required), read-only share link and public page with "I paid" (pending only), Today "You're owed", square-up moment with heartbeat haptic.
- **7 Responsive/motion**: every screen tested at 320/375/393/430 pt and text up to accessibility XL; overflow fixes; 320/430 goldens.
- **8 Audit**: three fresh strongest-model reviewers (hostile QA, senior designer, security). High and medium findings fixed; everything else is listed in `docs/AUDIT.md` ("Open" lists).
- **9 Verification (local)**: API 302 passed; Flutter 457 passed, analyze clean; local Postgres suites (RLS, attacks, flows, money rules, tally) pass; contrast and secret scan clean. CI on PR #3 was still queued when last checked.

### Tested vs NOT tested
Tested: everything above in the sandbox, plus read-only Plaid diagnostics against the real Items. NOT tested: any Swift (Open in Tick, Shortcuts intent, widget) — not compilable here; anything on a real iPhone (120 Hz, haptics feel, Reduce Motion, Wallet "Open in Tick", Tally invite via Messages); the deployed API; migrations on the real database; real bank reconnection after the fixes.

### Not done / known gaps
Tally reminders to friends are a share-sheet only; no receipts per Tally expense; Open items in `docs/AUDIT.md` (notably: Ask Tick totals can include excluded transfers, import undo doesn't revert re-homed captures, demo-only category ids make two nudges silent on live data, Plaid sync overwrites `include_in_safe`/name, Swift-side file protection for imported statements).

### Exact next steps (also `docs/NEXT.md`)
1. Merge PR #3 once CI is green.
2. `supabase db push --remote` (applies 20261105000001, 20261106000001–3, 20261107000001, 20261108000001).
3. `python3 tools/run_rls_tests.py`
4. `cd api && railway up --service tick-api --ci` (set `PUBLIC_BASE_URL` first, or share links return 503).
5. `python3 tools/e2e_deployed.py`, then `python3 tools/plaid_doctor.py`
6. `python3 tools/repair_sync.py` (dry run, read it), then `python3 tools/repair_sync.py --apply`
7. `cd app && flutter pub get`, run on the iPhone (device 00008150-001C1DCE1102401C) with the usual dart-defines.
8. Reconnect any bank that shows "Reconnect needed" (update mode). Only then link Capital One (6 Item slots remain).
9. On-device checklist: Open in Tick from Wallet and Files; Tally invite via Messages and "I paid"; square-up marks + heartbeat; Activity scroll smoothness; Reduce Motion and larger text on Today/Activity/Tally.

---

**Finishing session (2026-11-04, later):** AI moved to OpenRouter free models; Plaid link-session mapping and webhook-key hardening; Payday plan, budgets and goals editors, categories and rules editor, torn receipt edge, Pick date, short account labels, onboarding bills row; CI green without secrets. Details at the end of this file and in `docs/NEXT.md` / `docs/DECISIONS.md`.

Built unattended on branch `claude/gifted-cannon-lkg2x3` (the harness designates this branch; merge to `main` yourself).

## Status by phase
| Phase | Status | Notes |
|---|---|---|
| P0 Foundations | **Done** | Design tokens, haptics (8 patterns → AHAP), motion, copy, 28 icons, logo + iOS icon set + splash, brand sheet, 22 mockups, Opus design review applied, contrast CI, secret scan, GitHub Actions, Supabase linked + schema + RLS + Google provider + `receipts` bucket + realtime, FastAPI deployed on Railway |
| P1 Shell | **Done (device-untested)** | Google sign-in code, Face ID lock + privacy blur, custom tab bar / sheets / number pad / hold-to-confirm, debug gallery, onboarding (3 steps) |
| P2 Ledger | **Done** | Full schema + RLS + RLS tests, categories, quick add + natural input, Activity (search, filters, swipe), Today math (unit-tested), Demo mode, goldens |
| P3 Capture | **Done** | `/ingest` (token auth, rate limit, ingest_logs), 8 bank parsers, Gemini fallback, reconcile with property tests, Opus correctness review applied, Caught, Shortcuts guide |
| P4 Banks | **Done (sandbox-tested only)** | Link token, Hosted Link flow, Vault storage, `/transactions/sync`, webhook JWT verification, 6h cron backstop, balances, relink, "N of 10" |
| P5 Intelligence | **Mostly done** | Rules + learned rules, recurring + price hikes, Landed matching + screen, nudges, local notifications, Morning Receipt + share, Flows. Payday plan is a notification only (no sheet) |
| P6 Ask Tick | **Done** | SSE chat, 9 tools, deterministic fallback (Gemini is out of credits), mini charts, tappable transactions, suggested questions, ai_usage |
| P7 Native + polish | **Partial** | Widget + App Intent Swift written (uncompiled), receipt scanning, haptic sync tests, final Opus review. No XXL Dynamic Type run |
| P8 Handoff | **Done** | README, RUN_ON_MAC, SHORTCUTS_SETUP, DECISIONS, NEXT |

## Deployed
- API: https://tick-api-production.up.railway.app (`/health`, `/ingest`, `/ask`, `/plaid/*`, `/webhooks/plaid`, `/receipts/*`, `/intel/*`, `/jobs/*`).
- Supabase: 19 tables with forced owner-only RLS, vault wrappers for Plaid tokens, pg_cron jobs (6-hourly sync, weekly insights) calling the API with `X-Cron-Secret` from Vault, Google provider enabled, `tick://` redirects allow-listed, Realtime on transactions/expected/messages/connections, private `receipts` bucket.

## Tests
- Flutter: 55 passing (domain, notifier, nudges, flows, receipt, notification plan, widget snapshot, haptic sync, Dynamic Type 1.6x, 22 golden screenshots). `flutter analyze`: no issues.
- API: 94 passing (25 parser, 47 reconcile including property-based, 9 Plaid incl. webhook verification, 8 recurring/insight, 3 Ask Tick, health).
- RLS: SQL test passes against the live project (`tools/run_rls_tests.py`).
- End-to-end against live services: `/ingest` (SMS + Apple Pay merge into one row), Plaid sandbox (sync, idempotent re-sync, late SMS merges), deployed API with a real Supabase JWT (JWKS) and SSE.
- Contrast check: all pairs pass (`tools/contrast_check.py`).

## Design artifacts
- Golden screenshots (Flutter, demo data): `app/test/goldens/{today,activity,flows,ask-tick,caught,morning-receipt,incoming-upcoming,settings,onboarding-1,onboarding-2,onboarding-3}.{dark,light}.png`
- Mockup exports: `design/exports/` (same names) and `design/exports/brand-sheet.png`
- Brand: `design/brand-sheet.html`, `design/icons/_sheet.png`, `design/logo/`
- Reviews: Opus design review (P0) and correctness review (P3) are applied and logged in `docs/DECISIONS.md`; the final Opus design/UX review (15 findings) was applied: tab bar clipping, golden harness (double padding, shadows), body-text tabular figures, disabled buttons, receipt overflow, wordmark Volt dot, chevron icons, 44pt tap targets, heatmap, Ask Tick empty state, copy fixes. Not applied: Pick-date chip, receipt zigzag edge, merging the "3 to check" card into the section label, short account labels in rows (logged in NEXT.md).

## Your 15 minutes
1. On a Mac with Xcode and Flutter: `git clone https://github.com/prithvisaran3/tick.git && cd tick && git checkout claude/gifted-cannon-lkg2x3`.
2. `cp .env.example .env` and fill in your values.
3. `python3 tools/setup_local.py` (writes the Google URL scheme config and prints your `flutter run` command).
4. `cd app && flutter pub get && cd ios && pod install && open Runner.xcworkspace`.
5. Runner target: pick your Team, add the **App Groups** capability `group.com.prithvi.tick`.
6. Check the Google iOS OAuth client's bundle id matches Runner (`com.prithvi.tick`).
7. Plug in the iPhone and run the command from step 3. Sign in with Google, enter your paycheck, allow notifications.
8. Settings > Capture token > Make new token, copy it, and set up the two Shortcuts automations (`docs/SHORTCUTS_SETUP.md`).
9. File > New > Target > Widget Extension `TickWidget`, swap in `app/ios/TickWidget/TickWidget.swift`, iOS 17, App Group (`docs/RUN_ON_MAC.md` step 4).
10. **Top up Gemini credits** (AI Studio). Without them, AI features run on their fallbacks.
11. Settings > Banks > Hold to link your first bank (uses 1 of 10 lifetime links).
12. Add a text alert and an Apple Pay purchase; confirm one row appears (or Caught if low confidence).
13. Paste a few masked bank alerts into `tools/samples/*.txt`.
14. Merge `claude/gifted-cannon-lkg2x3` into `main`.
15. Skim `docs/NEXT.md` for the known gaps.

## Known gaps and next steps
See `docs/NEXT.md` ("Open work"). Biggest: nothing was run on a device; Gemini is out of credits so AI paths are untested against the real model; budgets/goals editors and a Payday plan sheet are missing; Dynamic Type XXL not verified.


## Finishing session
- **AI**: OpenRouter free models only (`:free` and zero price enforced twice), provider interface (Gemini disabled), 15/min and 40/day limits from `ai_usage`, input-hash cache, scrubbed inputs, `data_collection=deny`, one batched categorisation call per sync, advice and weekly insight generated by scheduled jobs and stored, Settings shows "AI today: N of 40" and the models in use. Free models in use on 2026-11-04: `dots-studio/dots-3-note-preview:free`, `recursive/flint-v1.0:free`, with `google/gemma-4-31b-it:free` as third fallback (rate-limited upstream that day). Smoke test: categorisation and tool calling worked; live categorisation through the deployed API worked.
- **Plaid**: link token to user mapping (`plaid_link_sessions`), SESSION_FINISHED and update-mode webhooks resolved through it, webhook key cache/negative cache/rate limit, tests for stale/tampered/wrong-alg/rotated keys and the route. Redirect URI to register (optional): `https://tick-api-production.up.railway.app/plaid/oauth-return` at dashboard.plaid.com > Developers > API > Allowed redirect URIs, then set `PLAID_REDIRECT_URI` on Railway.
- **New screens** (dark and light goldens): Payday plan, Budgets and goals, Categories and rules, Landed, Ask Tick with an answer; custom date picker and amount/text sheets.
- **Tests**: Flutter 74 passing (analyze clean); API 117 passing; RLS test passes; live checks pass (ingest, Plaid sandbox, deployed API, live AI categorisation).
- **CI**: the `api` job failed on GitHub (pytest could not import `app`); fixed with `pytest.ini` and `python -m pytest`; Flutter pinned to 3.47.9; integration jobs skip without secrets.
