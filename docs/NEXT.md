# NEXT — resume here
Fresh session? Read CLAUDE.md, docs/SPEC.md (sections 0, 7, 9) and this file, then continue from "Open work".

## Manual steps left (do these first)
1. **Gemini credits are depleted** (API returns 402 RESOURCE_EXHAUSTED on every call). Top up at AI Studio. Until then everything degrades gracefully: alert parsing uses regex only (low confidence goes to Caught), categorisation uses keyword rules, Ask Tick answers the suggested questions with a deterministic fallback, receipt scan saves the photo and asks you to type the total, advice lines use local templates. After topping up, check `ai_usage` rows have `ok = true`. The model id is one constant: `api/app/config.py` `GEMINI_MODEL` (currently `gemini-3.7-flash`, the newest dated Flash the key listed and the newest I could name; `gemini-3.8-flash` was also listed but could not be tested). Override with the `GEMINI_MODEL` env var on Railway.
2. **Run on your iPhone**: follow `docs/RUN_ON_MAC.md` (Xcode signing, App Group `group.com.prithvi.tick`, widget target, `tools/setup_local.py`). Swift (haptics plugin, widget, App Intent) is uncompiled and untested on a device.
3. **Google sign-in**: the iOS OAuth client in Google Cloud must use the same bundle id as the Runner target (`com.prithvi.tick` unless you changed it).
4. **Capture**: generate the token in Settings > Capture token, then follow `docs/SHORTCUTS_SETUP.md`.
5. **Bank**: first real link uses 1 of your 10 lifetime Plaid Items (`PLAID_ENV=production`). Linking needs Hold to confirm in Settings > Banks. If an OAuth bank (Chase) refuses inside Hosted Link, register an HTTPS redirect in the Plaid dashboard and add `redirect_uri` to `create_link_token` (see `api/app/plaid.py`).
6. **Plaid webhooks** point at `https://tick-api-production.up.railway.app/webhooks/plaid` (set per link token). Verified with the Plaid-Verification JWT; unit tested with a locally signed key, not yet exercised by Plaid.
7. Merge `claude/gifted-cannon-lkg2x3` into `main` (the harness pushed to this branch, not main).
8. Optional: add repo secrets `SUPABASE_ACCESS_TOKEN`, `SUPABASE_PROJECT_REF` so the CI `rls` job runs.
9. Paste masked bank alerts into `tools/samples/*.txt` so the regex parsers can be tuned to your real formats.

## Deployed
- API: https://tick-api-production.up.railway.app (Railway project `tick-api`, service `tick-api`; redeploy: `cd api && RAILWAY_TOKEN=... railway up --service tick-api --ci`)
- Supabase project (ref in env): schema + RLS + realtime + private `receipts` bucket + Google provider + vault wrappers + pg_cron jobs (`tick-sync-all` every 6h, `tick-weekly-insights` Sundays 22:00 UTC) calling the API with `X-Cron-Secret` from Vault.

## Phase status
- [x] P0 Foundations (design files, tokens, haptics, sounds, icons, logo, mockups + Opus review, Supabase, Railway /health, CI)
- [x] P1 Shell (Google sign-in code, Face ID lock + privacy blur, tab bar, sheets, number pad, gallery, onboarding)
- [x] P2 Ledger (schema, RLS + tests, categories, quick add + natural input, Activity, Today math, Demo mode, goldens)
- [x] P3 Capture (/ingest, tokens, parsers, Gemini fallback, reconcile + property tests, Opus review applied, Caught, Shortcuts doc)
- [x] P4 Banks (link token, Hosted Link flow, Vault, sync, webhook verification, 6h backstop, balances, relink, N of 10) — sandbox-tested only
- [x] P5 Intelligence (rules, recurring + price hikes, Landed matching, nudges, local notifications, Morning Receipt + share, Payday plan notification, Flows)
- [x] P6 Ask Tick (SSE, tools, fallback, mini charts, tappable transactions, ai_usage)
- [x] P7 Native + polish (widget, App Intent, receipt scan, haptic sync tests, final Opus review)
- [x] P8 Handoff (README, RUN_ON_MAC, SHORTCUTS_SETUP, DECISIONS, this file, FINAL_REPORT)

## Open work (known gaps)
- Not verified on a device: Core Haptics patterns, WidgetKit, App Intent, Google sign-in, ASWebAuthenticationSession Plaid flow, local notifications, Face ID.
- Landed screen (stamp + heavy haptic + chime) exists (`IncomingScreen(landed:)`) but is not yet triggered from realtime: subscribe to `expected` updates where `status = landed` and push it. Server already marks expected rows landed when a matching deposit syncs.
- Payday plan screen: the notification is scheduled; there is no dedicated Payday plan sheet yet (move-to-savings action).
- Budgets and goals UI: tables, safe-to-spend use goals; no editor screens yet. Onboarding saves paycheck and rent (and demo data) only.
- Settings > Categories shows a list; no add/rename/rules editor yet. Learned rules are created on recategorise.
- `payday_rule` lives in local settings only (not synced to `settings.payday_rule`), so server-side Ask Tick fallback cannot use it for "can I afford".
- Dynamic Type to XXL, VoiceOver pass: labels are on controls, but no XXL golden run yet.
- Plaid `LINK`/`SESSION_FINISHED` webhook cannot map to a user (no client_user_id in body); the app calls `/plaid/complete` after the redirect instead.
- Ingest serialises per user with an in-process lock (one Railway replica). Scaling out needs a Postgres advisory lock RPC.

## Splitwise plan (not in v1)
Data model is ready: `people`, `transactions.splits jsonb`, `transactions.participants jsonb`, `expected(kind=iou)`. Steps: (1) people + groups tables and a people picker on a purchase; (2) split editor (equal, exact, percent) writing `splits`; (3) running balances per person derived from splits and settlements; (4) settle-up flow: Hold to confirm, creates an `expected iou` or a settlement transaction; (5) HEARTBEAT haptic (already compiled) fires once per person on settle-up; (6) share a settle link by text.

## APNs push plan (not in v1)
Local notifications cover v1. For server push: add an Apple Push key (p8) in the Apple developer account, store the key id/team id in Railway env and the p8 in Vault, add `device_tokens(user_id, token, env)` with RLS, register in the app (`UIApplication.registerForRemoteNotifications` via a small plugin), send from FastAPI with HTTP/2 to APNs on: Landed deposits (Plaid webhook), price hikes, urgent overspend. Keep the 8:00 morning summary local.

## Sign in with Apple
Required by App Store review once Google sign-in exists. Enable the capability, use `sign_in_with_apple` + `signInWithIdToken(provider: apple)`, enable the Apple provider via the Management API, and link accounts by email.

## Path to opening Tick to others
1. Replace the single-user assumptions: per-user Plaid item cap (the 10-Item Trial cap is for the whole Plaid client, so move to a paid Plaid plan first), per-user rate limits, abuse limits on `/ingest`.
2. Sign in with Apple, privacy policy and data deletion (Delete all data exists; add account deletion), App Store privacy labels.
3. Move Gemini calls behind per-user quotas using `ai_usage`.
4. Multi-replica safety: advisory locks around reconcile, a queue for Plaid sync.
5. Plaid production review (Trial to Pay-as-you-go), security questionnaire, encryption at rest is covered by Vault.
6. TestFlight, crash reporting, analytics that never contain merchant text.
