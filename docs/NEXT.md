# NEXT — resume here
_Updated by the production audit (`docs/AUDIT.md`)._
Fresh session? Read CLAUDE.md, docs/FINAL_REPORT.md and this file, then continue unattended from "Open work".

## What I must verify on the real iPhone (production-audit checklist)
Nothing below could be run in the build sandbox (no Xcode, no device). Do them in order with `docs/RUN_ON_MAC.md`; tick each box.
1. [ ] `flutter pub get` works on your Flutter (3.44+). If it prints an SDK error, `brew upgrade --cask flutter`.
2. [ ] **Launch**: the Ink launch screen with the "tick" wordmark appears (no white flash), the app icon is the Ink + Volt checkmark, and the first screen is usable in under ~2 s. In Xcode's console there is no `fopen failed for data file` line; if there is, copy the whole line and the lines around it into an issue (all declared assets exist and are test-enforced, so it would point at something new).
3. [ ] **Google sign-in** (onboarding > Continue with Google): the system sign-in sheet opens, you pick an account, it closes, you land on the paycheck step. Also test: close the sheet (calm "cancelled" text, button still works), airplane mode (calm "offline" text), then retry. Kill and relaunch: you are still signed in (Settings shows "Signed in with Google") and Today shows data immediately.
4. [ ] **Freeze check**: switch tabs quickly, scroll Activity, pull down to refresh, background and reopen the app. Nothing should hang; the "System gesture gate timed out" log must not appear. If it does, note what you tapped just before.
5. [ ] **Smoothness in `--release`** (or `--profile`): Activity scrolling and tab switches feel smooth (60 to 120 fps). With `--profile --dart-define=TICK_PERF=true` the overlay bars stay green.
6. [ ] **Notifications**: the permission prompt appears about 2 s after onboarding (not at launch); a morning summary, a bill reminder (day before) and the Sunday review arrive; tapping the Payday notification opens the Payday plan.
7. [ ] **Face ID**: Settings > Face ID lock turns on only after Face ID succeeds; backgrounding and reopening asks for Face ID; the privacy blur covers the app in the app switcher.
8. [ ] **Haptics** (real iPhone, Settings > Haptics Full): the Pop at launch, Price weight when a purchase lands, Count-up on Safe to spend, Hold to confirm ramps and clicks, Caught swipes feel different per direction, Landed is a heavy stamp. Subtle is half strength; Off is silent.
9. [ ] **Plaid** (once, see item below): Hold to link opens the Plaid sheet; closing it is not an error; after linking, rows appear within a minute.
10. [ ] **Siri/Shortcuts**: "Log expense" opens Tick with the add sheet filled in; also try `tick://add?amount=18&merchant=Uber` from Safari.

## Supabase migration to apply by hand (not applied by the audit)
`supabase/migrations/20261105000001_indexes_and_cleanup.sql` adds indexes for the hot queries and three housekeeping cron jobs. It is safe to run. Apply when you are ready: `python3 tools/db.py push` (uses `SUPABASE_ACCESS_TOKEN` and `SUPABASE_PROJECT_REF`), then `python3 tools/run_rls_tests.py`.

## Do these by hand (in order of importance)
1. **Plaid OAuth redirect (Chase and other OAuth banks).** Hosted Link works for OAuth banks without any redirect URI (current Plaid docs), so linking should work as is. If a bank refuses with an OAuth error, register this exact URI:
   `https://tick-api-production.up.railway.app/plaid/oauth-return`
   Where: https://dashboard.plaid.com > Developers > API > **Allowed redirect URIs** > Add new URI > paste it > Save. Then on Railway (project `tick-api`, service `tick-api`, Variables) add `PLAID_REDIRECT_URI` with the same value and redeploy. Do NOT set the variable before registering the URI: Plaid rejects unregistered redirect URIs and linking would fail.
2. **Run on your iPhone:** `docs/RUN_ON_MAC.md`. Swift (haptics, web-auth channel, App Intent) is uncompiled and untested on a device.
3. **Link ONE bank** (you have 10 Items for life; production Items are only created by the Hold-to-link flow, never by tests or code).
4. **AI** runs on OpenRouter FREE models only, with data_collection=deny (see "AI status"). Settings > AI shows "AI today: N of 40" and the models in use.
5. Capture token + Shortcuts: `docs/SHORTCUTS_SETUP.md`.
6. Optional: GitHub repo secrets `SUPABASE_ACCESS_TOKEN`, `SUPABASE_PROJECT_REF`, `SUPABASE_URL`, `SUPABASE_SECRET_KEY`, `PLAID_CLIENT_ID`, `PLAID_SANDBOX_SECRET` so CI also runs the RLS and live integration jobs (they skip cleanly without them).
7. Paste masked bank alerts into `tools/samples/*.txt` to tune the parsers.
8. Home-screen widget: needs a paid Apple Developer account (App Groups). Steps are at the end of `docs/RUN_ON_MAC.md`.

## AI status (read this)
- Provider: OpenRouter, only model ids ending in `:free`, chosen at runtime from `GET /api/v1/models` (cached 24h), top 3 sent as the `models` fallback array. Gemini code stays behind the `AIProvider` interface (`AI_PROVIDER=gemini` to re-enable, currently a stub); `GEMINI_API_KEY` is no longer required.
- Privacy: requests set `provider.data_collection = "deny"`. With that setting, free NVIDIA models are filtered out by OpenRouter ("Free model training"), and Google's free Gemma models were rate-limited upstream on 2026-11-04. Models verified working under `deny` that day: `dots-studio/dots-3-note-preview:free`, `recursive/flint-v1.0:free` (both reasoning models; the code leaves token headroom). `api/app/ai.py` has `PREFERRED` and `AVOID_PREFIXES` for this; re-verify with `python3 tools/ai_smoke.py` (max 3 calls) when models rotate.
- Limits: 20 requests/min and 50/day are upstream; Tick enforces 15/min and `AI_DAILY_CALL_LIMIT=40` (counted from `ai_usage` where `ok = true`). 429 or error: one retry after 1.5s, then silent fallback to non-AI. A rate-limited model is skipped for 10 minutes.
- Rule-first: regex parsers and learned rules first; AI only when confidence < 0.8; results cached in `ai_cache` by input hash; one batched call for all uncategorised merchants of a sync; Morning Receipt advice generated once a day by `/jobs/daily-advice` (pg_cron, noon UTC) and weekly insight once a week; the app never calls AI on open.
- Privacy filter `ai.scrub()` strips card digits, long numbers, emails, phones and URLs. Ask Tick sends only tool results and the last 6 messages.
- Not verified: the receipt-photo vision call (needs a free vision model that passes `deny`), and `parse_alert_ai` returned empty text once under a reasoning model (falls back to the regex result and Caught).
- Smoke test results (2026-11-04): categorize and tool-call worked through `dots-studio/dots-3-note-preview:free`; live categorisation through the deployed API worked (`tools/e2e_ai_live.py`).

## Deployed
- API: https://tick-api-production.up.railway.app (Railway project `tick-api`; redeploy: `cd api && railway up --service tick-api --ci` with `RAILWAY_TOKEN`). Env: Supabase, Plaid, `OPENROUTER_API_KEY`, `CRON_SECRET`, `AI_PROVIDER`, `AI_DAILY_CALL_LIMIT`.
- Supabase: 22 tables with forced owner-only RLS (+ server-only tables), vault wrappers, pg_cron: `tick-sync-all` (6h), `tick-weekly-insights` (Sun 22:00 UTC), `tick-daily-advice` (12:00 UTC), calling the API with `X-Cron-Secret` from Vault.

## Phase status
All phases P0-P8 done, plus the finishing session: AI on OpenRouter, Plaid hardening, Payday plan, budgets and goals editors, categories and rules editor, torn receipt edge, Pick date, short account labels, CI green without secrets.

## Open work (known gaps, all need a device or are low priority)
- Nothing has run on a device: Core Haptics patterns, WidgetKit, App Intent, Google sign-in, ASWebAuthenticationSession Plaid flow, local notifications and their tap routing, Face ID.
- Plaid has only been exercised in sandbox; real webhook delivery to `/webhooks/plaid` (signature verification is unit-tested with a locally signed key, key rotation and rate limiting tested) is unverified until the first real link.
- Receipt photo scanning needs a free vision model that passes `data_collection=deny`; until then the photo is saved and you type the total.
- Ingest serialises per user with an in-process lock (one Railway replica). Scaling out needs a Postgres advisory-lock RPC.
- Goal editor `Add` label should read `Tick` for edits (copy polish); widget extension uses the system rounded font (bundle Cabinet Grotesk into the extension for exact type).
- Budgets are not part of Safe to spend (only goals and bills are).

## Splitwise plan (not in v1)
Data model is ready: `people`, `transactions.splits jsonb`, `transactions.participants jsonb`, `expected(kind=iou)`. Steps: (1) people + groups tables and a people picker on a purchase; (2) split editor (equal, exact, percent) writing `splits`; (3) running balances per person; (4) settle-up flow with Hold to confirm; (5) HEARTBEAT haptic (already compiled) once per person on settle-up; (6) share a settle link by text.

## APNs push plan (not in v1)
Local notifications cover v1. For server push: Apple Push key (p8), key id/team id in Railway env, p8 in Vault, `device_tokens(user_id, token, env)` with RLS, register via a small iOS plugin, send from FastAPI over HTTP/2 on Landed deposits (Plaid webhook), price hikes and urgent overspend. Keep the 8:00 morning summary local.

## Sign in with Apple
Required by App Store review once Google sign-in exists: enable the capability, `sign_in_with_apple` + `signInWithIdToken(provider: apple)`, enable the Apple provider via the Management API, link accounts by email.

## Path to opening Tick to others
1. The 10-Item Plaid Trial cap is per client: move to a paid Plaid plan first; add per-user rate limits and abuse limits on `/ingest`.
2. Sign in with Apple, privacy policy, account deletion, App Store privacy labels.
3. Per-user AI quotas from `ai_usage` (the free pool is shared across users and tiny; a paid model behind the same interface is the real answer).
4. Multi-replica safety (advisory locks around reconcile, a queue for Plaid sync).
5. Plaid production review and security questionnaire; Vault already encrypts tokens at rest.
6. TestFlight, crash reporting, analytics that never contain merchant text.
