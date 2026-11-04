# Tick — final report

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
- Flutter: 51 passing (domain, notifier, nudges, flows, receipt, notification plan, widget snapshot, haptic sync, 22 golden screenshots). `flutter analyze`: no issues.
- API: 94 passing (25 parser, 47 reconcile including property-based, 9 Plaid incl. webhook verification, 8 recurring/insight, 3 Ask Tick, health).
- RLS: SQL test passes against the live project (`tools/run_rls_tests.py`).
- End-to-end against live services: `/ingest` (SMS + Apple Pay merge into one row), Plaid sandbox (sync, idempotent re-sync, late SMS merges), deployed API with a real Supabase JWT (JWKS) and SSE.
- Contrast check: all pairs pass (`tools/contrast_check.py`).

## Design artifacts
- Golden screenshots (Flutter, demo data): `app/test/goldens/{today,activity,flows,ask-tick,caught,morning-receipt,incoming-upcoming,settings,onboarding-1,onboarding-2,onboarding-3}.{dark,light}.png`
- Mockup exports: `design/exports/` (same names) and `design/exports/brand-sheet.png`
- Brand: `design/brand-sheet.html`, `design/icons/_sheet.png`, `design/logo/`
- Reviews: Opus design review (P0) and correctness review (P3) are applied and logged in `docs/DECISIONS.md`; the final Opus design/UX review result is summarised below.

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
