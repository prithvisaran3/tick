# Tick security

Real bank data flows through Tick. This file covers the threat model, every control and how it is checked, the
key-rotation and incident runbooks, the manual steps only you can do, and the open low-severity findings.

Everything here is verified by a test or a script; the "Verified by" column says which. "Device" means it can only be
checked on the iPhone (see the checklist in docs/NEXT.md).

## 1. Threat model

**What is worth stealing:**
- Plaid access tokens (read access to every linked account).
- Transaction history, balances and card details (masks only).
- The Supabase session (acts as you).
- Capture tokens (they write purchases into your ledger).
- The server secrets: Supabase secret key, Plaid secret, OpenRouter key, CRON_SECRET.

**Attackers assumed:**

| Attacker | Has | Goal |
|---|---|---|
| A1. Internet stranger | the API URL (it is in the app binary), the Supabase URL and publishable key (also in the binary) | read or write anyone's data, burn Plaid slots, run up AI cost, DoS |
| A2. Holder of a leaked capture token | one `tk_…` token (for example from a shared Shortcut) | inject fake purchases, probe other routes |
| A3. Another Tick user | a valid Supabase session of their own | read or change *your* rows through RLS gaps, RPCs, views or storage |
| A4. Someone with your unlocked or stolen phone, or a backup of it | the device, an iCloud or Finder backup, screen recordings | open Tick, read cached data, lift the session |
| A5. A hostile merchant name or note | text in a bank feed or SMS | prompt injection into AI categorisation or Ask Tick |
| A6. Leaked server secret | one of the env values (for example a key pasted into a chat) | everything that secret unlocks |

**Out of scope:**
- A compromised Supabase, Railway, Plaid or Apple.
- A jailbroken phone with a debugger attached.
- Physical coercion.

## 2. Controls

### Secrets and repo

| Control | Where | Verified by |
|---|---|---|
| Secrets only in env vars (Railway, Supabase Vault, local `.env`); `.env*` ignored everywhere except `.env.example` | `.gitignore` | CI `secrets` job checks no `.env` is tracked; `git check-ignore` run during this audit |
| Secret scan of the staged diff, the whole tree and **every commit in history**: patterns plus the literal values of Tick's env vars | `tools/secret_scan.py` (`--tree`, `--history`) | Clean on 2026-11-06 (31 commits, all refs); CI `secrets` job fails on a hit |
| Pre-commit hook blocks secrets and `.env` files | `tools/hooks/pre-commit` (`git config core.hooksPath tools/hooks`) | Runs on every commit made with `tools/commit.sh` |
| CI least privilege: `permissions: contents: read`; checkout without persisted credentials; third-party actions pinned by commit SHA | `.github/workflows/ci.yml` | Review the workflow |
| Dependencies pinned and audited: Python runtime deps `==`, dev deps separate (not in the Docker image); `pubspec.lock` committed; Dependabot weekly | `api/requirements*.txt`, `.github/dependabot.yml` | `pip-audit -r api/requirements.txt` reports **no known vulnerabilities**. CI `audit` job. `flutter pub outdated`: all direct deps current (Dart has no advisory database to audit against) |

### Database (Supabase)

| Control | Verified by |
|---|---|
| RLS **enabled and forced** on every table in `public`, found from the catalogue, so a new table is checked automatically | `supabase/tests/attacks.sql` §1 |
| Owner-only policies. User B can't read, update, delete or insert A's rows in **any** table with `user_id`, including through foreign keys | `attacks.sql` §5–6, `rls.sql` |
| `anon` gets nothing: no table privileges, no function execute (revoked in bulk, plus default privileges for future objects) | `attacks.sql` §3, §8 |
| Every `SECURITY DEFINER` function pins `search_path`. Only the read RPCs (`tick_flows`, `tick_activity_page`, `tick_months`, `tick_filtered`, `tick_links_used`) are executable by `authenticated`, and they are `SECURITY INVOKER` (RLS applies) or check `auth.uid()` | `attacks.sql` §3, §7 |
| Views must be `security_invoker`. There are none today; the test fails the day one appears without it | `attacks.sql` §2 |
| Plaid access tokens live **only** in Vault, behind `tick_vault_get`/`_upsert`/`_delete`, which only `service_role` may execute. No column named like a token, secret, password, account or routing number exists | `attacks.sql` §3–4; `test_security.py` |
| Only masks are stored. `_ensure_accounts` copies `mask`, never `numbers` (Tick doesn't request Plaid Auth) | `test_cards.py::test_accounts_store_owed_as_negative_and_only_masks` |
| Capture tokens: server-minted, only the SHA-256 stored, scope `ingest`. The app can list and revoke but never insert or rewrite | `attacks.sql` §6; `test_security.py` |
| Append-only `audit_log` (sign-in by trigger; token created and revoked, bank linked and removed, data deleted, sessions revoked, bad-token bursts). No PII: an allow-list of detail keys | `attacks.sql` §9; `api/app/audit.py` |
| `plaid_items` is append-only: the lifetime link counter can't be lowered by deleting rows | `attacks.sql` §9; `test_plaid_links.py` |
| Storage: `receipts` is private, 8 MB limit, image MIME allow-list, `<user_id>/` folders only. The API sniffs magic bytes and ignores the client's Content-Type | `attacks.sql` §10; `test_hardening.py` |

The RLS and attack suites run on a throwaway local Postgres (`python3 tools/local_db.py test`, also in CI) and against the
live project after `supabase db push` (`python3 tools/run_rls_tests.py`; every suite rolls back).

### Auth configuration (Supabase)

Target settings: Google only, email sign-up off, redirect allow-list exactly `tick://login-callback`, 15-minute access
tokens, refresh-token rotation on (reuse interval 10 s), every unused provider off.

`python3 tools/auth_config.py` checks them read-only. On 2026-11-06 three differ, and they are **not changed by me**
(this is a production change; see Manual steps):
- email provider on;
- allow-list has the wildcard `tick://**`;
- JWT expiry 3600 s.

### API (FastAPI on Railway)

| Control | Verified by (`api/tests/`) |
|---|---|
| Every user route requires a Supabase JWT, found by walking all routes; `/jobs/*` require CRON_SECRET (`hmac.compare_digest`) | `test_security.py::test_every_user_route_requires_auth` |
| JWT: asymmetric algorithms only; signature checked against JWKS; `iss`, `aud=authenticated`, `exp`, `iat` and `sub` required; `role=authenticated`. A bad signature is final: the Auth-server fallback is used only when JWKS can't be fetched | `test_security.py` (forged HS256, `alg:none`, wrong key, wrong iss, aud and role, expired; a network call fails the test) |
| Capture token: 32 random bytes, shown once, SHA-256 stored, scope `ingest`, rotate (`POST /tokens` revokes older ones), revoke, cache dropped on revoke and panic | `test_security.py::test_capture_token_*`, `test_panic_*` |
| Strict CORS: no browser origin allowed (never `*`) | `test_cors_never_allows_a_browser_origin` |
| Security headers on every response (HSTS, nosniff, frame DENY, CSP `default-src 'none'`, no-referrer, `Cache-Control: no-store`); `/docs` and `/openapi.json` off | `test_security_headers_*` |
| Request size limits: 256 KB default; 64 KB `/ask`; 2 MB CSV import; 8 MB receipt photos; chunked bodies counted too | `test_request_size_limits` |
| Strict pydantic bodies (`extra="forbid"`, patterns on ids and link tokens) | `test_strict_bodies_reject_unknown_fields` |
| Rate limits per user (per route) and per IP (300 a minute). The IP is the right-most `X-Forwarded-For` entry, which Railway's edge appends, so a forged header can't reset it | `test_per_ip_rate_limit_and_spoofed_forwarded_for`, `test_per_user_rate_limits` |
| Bad-token bursts (20 401/403s a minute from one address) block the address for 15 minutes and write `bad_token_burst` to the audit log | `test_bad_token_burst_*` |
| Calm errors: no stack traces or exception text to clients | `test_hardening.py` |
| `/health` returns `{"ok": true}` only | `test_security_headers_*` |
| Plaid webhooks: ES256 JWT by `kid`, body SHA-256, `iat` within 5 minutes, key lookups rate-limited; **nothing is read or written before verification** | `test_plaid.py`, `test_plaid_webhook_has_no_side_effects_before_verification` |
| Logs redacted: Bearer tokens, JWTs, capture tokens, Plaid tokens, API keys, emails, dollar amounts, masks, and `merchant=`/`note=` style fields. httpx request URLs (which carry ids) dropped below WARNING. No query strings or bodies in the access log | `test_logs_never_contain_*` (fake secrets sent in headers, body and query, plus an exception) |
| AI safety: Ask Tick has only read tools, and dispatch is by allow-list (an unknown tool or `__init__` gets `{"error": "unknown tool"}`). The system prompt marks tool data as untrusted. AI categories must come from the allowed list; model-written merchant names are bounded (40 chars, safe characters, must resemble the original) | `test_ask_tick_is_read_only_*`, `test_model_written_merchant_names_are_bounded` |
| Plaid Link: a link-session claim makes the exchange idempotent; the slot counter is distinct item_ids; app POSTs to `/plaid/*` are never retried | `test_plaid_links.py`, `app/test/data_test.dart` |
| Delete all my data: Plaid `/item/remove` per Item, Vault deletion, every row and receipt, audit entry. The slot counter is kept and the app warns that the slot is not returned | `test_delete_all_*` |

### App (iOS)

| Control | Verified by |
|---|---|
| Supabase session and PKCE verifier in the **Keychain**, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, not synced. A session found in SharedPreferences from older builds is moved, then deleted | `app/test/security_test.dart`; Device |
| No secrets in SharedPreferences (settings only) or in the offline cache (ledger rows; never tokens) | `security_test.dart`, `ledger_codec.dart` review |
| Offline cache files get `NSFileProtectionComplete` and are excluded from iCloud and device backups (`TickPrivacy.swift`) | `security_test.dart` (called after every write); Device |
| Face ID lock with "Ask for Face ID after: Always, 1, 5 or 15 min"; cannot be turned on unless Face ID works | `security_test.dart::shouldRelock`; Device |
| App-switcher snapshot is fully covered (stronger than a blur) when Privacy blur or Face ID is on | Device |
| Hide amounts: every formatted amount and notification reads `$••••`. Also automatic while the screen is recorded, mirrored or AirPlayed (`UIScreen.isCaptured`) | `security_test.dart`; Device |
| Release builds: no `print`/`debugPrint` anywhere; the only dart-defines are the Supabase URL, the publishable key, the API URL and two switches | `assets_test.dart`, `security_test.dart` |
| Panic button: the server revokes all capture tokens; Supabase global sign-out ends every session; this phone's cache is wiped; shows how to cut Plaid's access at my.plaid.com | `test_panic_*`; Device |
| Delete all my data: server-side, including Plaid `/item/remove`; warns the slot is never returned | `test_delete_all_*`; Device |
| Notification taps only route `card:<id>` payloads matching `^[A-Za-z0-9-]{1,64}$` | `router.dart` review |

**Not done on purpose:**
- **Certificate pinning.** Supabase and Railway rotate certificates and intermediates without notice. A pinned leaf or
  intermediate would brick the app until an App Store update, and with a free Apple account, sideloaded builds expire
  every 7 days anyway. Pinning to public CAs adds little over the system trust store plus HSTS. Revisit if Tick ships
  through TestFlight with a backup pin and a remote kill switch.
- **Blocking screenshots.** iOS has no supported API for it. Tick hides amounts during recording instead, and offers
  Hide amounts.

## 3. Key rotation runbook

Rotate one key at a time. After each one, run `python3 tools/e2e_deployed.py`.

| Secret | Where it lives | How to rotate |
|---|---|---|
| Supabase secret key (`sb_secret_…`) | Railway env `SUPABASE_SECRET_KEY` | Supabase dashboard → Settings → API Keys → create a new secret key → set it in Railway → redeploy → delete the old key in Supabase |
| Supabase publishable key | app `--dart-define`, Railway | Create a new publishable key, rebuild the app with it, then disable the old one |
| Plaid secret | Railway `PLAID_SECRET` | Plaid dashboard → Keys → rotate production secret → update Railway → redeploy. Access tokens stay valid |
| Plaid access token (one Item) | Vault | Only if that token leaked: `/item/access_token/invalidate` mints a new one for the same Item without using a slot. Store it with `tick_vault_upsert`. Never `/item/remove` unless you want the bank gone |
| OpenRouter key | Railway `OPENROUTER_API_KEY` | openrouter.ai → Keys → create a key with a **$0 credit limit** (free models only) → update Railway → delete the old one |
| Gemini key (unused) | nowhere in prod | Delete it in Google AI Studio; regenerate only if you turn Gemini back on |
| CRON_SECRET | Railway + Supabase Vault `tick_cron_secret` | `python3 -c "import secrets;print(secrets.token_urlsafe(48))"`, set the new value in Railway **and** in Vault (`select vault.update_secret(id, 'new')`), redeploy. Must be 32 characters or more (the API warns at startup otherwise) |
| Capture tokens | `ingest_tokens` (hash) | Settings → Capture token → Make new token (the old one stops at once), then paste the new one into each Shortcut |
| Supabase access token / Railway token | your laptop, CI secrets | Revoke in the dashboard, create a new one, never paste it into a chat |
| Google OAuth client secret | Supabase Auth → Google | Google Cloud → Credentials → reset secret → paste into Supabase |

## 4. Incident runbook

1. **Contain (minutes).**
   - Phone lost or a token leaked: Tick → Settings → **Panic: lock everything**.
   - A server secret leaked: rotate it (section 3) right away.
   - A Plaid token leaked: invalidate it (`/item/access_token/invalidate`).
2. **Cut bank access if needed.**
   - my.plaid.com → remove Tick: Plaid revokes every Item for you.
   - Or Settings → **Delete all data**: Plaid `/item/remove` for every Item. Removing never returns a slot.
3. **Look.**
   - Read `select event, detail, at from audit_log order by at desc limit 200;` (no PII by design).
   - Check Railway logs for 401/429 bursts (they're redacted) and `ingest_logs` for unexpected captures.
4. **Clean up.** Delete injected transactions, then rotate whatever was exposed even if it looks unused.
5. **Write it down** in docs/DECISIONS.md: what happened, when, what was rotated.

## 5. Manual steps (only you can do these)

- [ ] **FileVault on** for the Mac that builds Tick.
- [ ] **2FA or passkeys** on Google, GitHub, Supabase, Railway and Plaid.
- [ ] **Delete `SUPABASE_ACCESS_TOKEN` and `RAILWAY_TOKEN` from the Claude cloud environment** (claude.ai → Claude Code → environment settings). Keep them only on your Mac.
- [ ] **Regenerate the exposed Gemini key** (Google AI Studio). Tick doesn't use Gemini by default, so simply delete it.
- [ ] **Set a $0 credit limit on the OpenRouter key** (free models only; caps any leak at $0).
- [ ] **Rotate the Supabase secret key** (section 3) and update Railway.
- [ ] **Supabase Auth:**
  - [ ] Run `python3 tools/auth_config.py`, read it, then run `python3 tools/auth_config.py --apply`.
  - [ ] This turns off email sign-in, sets the redirect allow-list to exactly `tick://login-callback` and makes JWTs 15 minutes.
- [ ] **GitHub repo settings** (the session's GitHub access can't change them):
  - [ ] Settings → Code security: turn on Secret scanning, Push protection, Dependabot alerts and Dependabot security updates.
  - [ ] Settings → Branches: protect `main`: require a PR, require the `ci` checks (secrets, migrations, audit, api, app), block force-push and deletion.
  - [ ] Settings → Actions → General: Workflow permissions = "Read repository contents".
  - [ ] Settings → Actions → General: allow only actions pinned by SHA (or GitHub-owned plus selected).
- [ ] Locally, once: `git config core.hooksPath tools/hooks`.
- [ ] CRON_SECRET: make sure it is 32 characters or more (rotate per section 3 if not).

## 6. Hostile review and open findings

A separate reviewer with no context of this work attacked `api/`, `supabase/` and `app/`. Every high and medium finding was
fixed and is listed in section 6a; the lows are in section 6b.

### 6a. Fixed (high and medium)

*(filled in after the review: see below)*

### 6b. Open lows

*(filled in after the review: see below)*
