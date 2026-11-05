# tick

A personal finance app for iPhone. Open it in the morning and know in three seconds: am I okay, what is safe to spend until payday, what is coming in, what is going out, and the one thing to do today. Everything is captured automatically (bank texts, Apple Pay, a linked bank, receipt photos); typing is the fallback.

Built for one user for now (Prithvi). Design system and spec: `docs/SPEC.md`. Current state and manual steps: `docs/NEXT.md`.

## Layout
| Path | What |
|---|---|
| `app/` | Flutter app (Riverpod 3, go_router, supabase_flutter) plus native Swift: `ios/Runner/TickHaptics.swift` (Core Haptics), `ios/Runner/LogExpenseIntent.swift` (App Intent), `ios/TickWidget/` (WidgetKit) |
| `api/` | FastAPI on Railway: `/ingest`, Plaid, Gemini, Ask Tick (SSE), scheduled jobs |
| `supabase/` | SQL migrations (schema, owner-only RLS, vault wrappers, cron) and the RLS test |
| `design/` | Source of truth: `tokens.json`, `haptics.json`, `motion.json`, `copy.md`, brand sheet, icons, logo, mockups, exports |
| `tools/` | Generators (tokens, AHAP haptics, sounds, logo, mockups), contrast checker, secret scan, DB runner, end-to-end checks |
| `docs/` | SPEC, NEXT, DECISIONS, RUN_ON_MAC, SHORTCUTS_SETUP, FINAL_REPORT |

## Commands
```bash
python3 tools/contrast_check.py          # every colour pair in tokens.json (CI)
python3 tools/gen_tokens.py              # tokens.json + motion.json -> Dart + CSS
python3 tools/compile_ahap.py            # haptics.json -> AHAP files
cd app && flutter analyze && flutter test            # unit, widget, haptic-sync, golden screenshots
cd api && python3 -m pytest -q                       # parsers, reconcile (property-based), Plaid, intel, Ask Tick
python3 tools/run_rls_tests.py                       # RLS tests against the linked Supabase project
python3 tools/e2e_ingest.py                          # /ingest against the live database (throwaway user)
python3 tools/e2e_plaid_sandbox.py                   # Plaid SANDBOX sync end to end
python3 tools/e2e_deployed.py                        # live Railway API
```
Secrets are environment variables only (names in `.env.example`). `tools/commit.sh "message"` secret-scans the staged diff, commits and pushes.

## Running the app
Needs **Flutter 3.44 or newer** (Dart 3.12+). Beginner steps in `docs/RUN_ON_MAC.md`; what was audited and fixed in `docs/AUDIT.md`.

## Release build
```bash
cd app && flutter build ipa --release \
  --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_PUBLISHABLE_KEY=... --dart-define=API_BASE_URL=https://tick-api-production.up.railway.app \
  --obfuscate --split-debug-info=build/symbols
```
Bump `version:` in `app/pubspec.yaml` (`1.0.0+1`) for each upload. `test/`, `design/` and `docs/` are not app assets, so nothing from them ships; the debug gallery is compiled out of release behaviour (`kDebugMode`). Only public client config is passed with `--dart-define`.
