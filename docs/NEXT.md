# NEXT — resume here
Fresh session? Read CLAUDE.md, docs/FINAL_REPORT.md and this file, then continue unattended from "Open work".

## Do these by hand (in order of importance)
1. **Plaid OAuth redirect (Chase and other OAuth banks).** Hosted Link works for OAuth banks without any redirect URI (current Plaid docs: Hosted Link does not need Link re-initialisation), so linking should work as is. To be safe, and required if you ever hit an OAuth error, register this exact URI:
   `https://tick-api-production.up.railway.app/plaid/oauth-return`
   Where: https://dashboard.plaid.com > Developers > API > **Allowed redirect URIs** > Add new URI > paste it > Save. Then on Railway (project `tick-api`, service `tick-api`, Variables) add `PLAID_REDIRECT_URI` with the same value and redeploy. Do NOT set the variable before registering the URI: Plaid rejects unregistered redirect URIs and linking would fail. Production OAuth institutions also need your Plaid application profile and (for some banks) questionnaire completed in the dashboard.
2. **Run on your iPhone:** `docs/RUN_ON_MAC.md` (beginner steps). Swift (haptics plugin, widget, App Intent) is uncompiled and untested on a device.
3. **Link ONE bank** (you have 10 Items for life; production Items are only created by the Hold-to-link flow, never by tests or code).
4. **AI** runs on OpenRouter FREE models only, with data_collection=deny. Free capacity rotates; see "AI status" below. Check Settings > AI on the phone for "AI today: N of 40" and the models in use.
5. Capture token + Shortcuts: `docs/SHORTCUTS_SETUP.md`.
6. Optional: GitHub repo secrets `SUPABASE_ACCESS_TOKEN`, `SUPABASE_PROJECT_REF`, `SUPABASE_URL`, `SUPABASE_SECRET_KEY`, `PLAID_CLIENT_ID`, `PLAID_SANDBOX_SECRET` so CI also runs the RLS and live integration jobs (they skip cleanly without them).
7. Paste masked bank alerts into `tools/samples/*.txt` to tune the parsers.

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
