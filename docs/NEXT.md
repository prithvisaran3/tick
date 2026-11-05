# NEXT: resume here

_Updated by the cards, ideas and security branch (`feat/cards-ideas-security`, 2026-11-06)._
Fresh session? Read CLAUDE.md, this file, docs/DECISIONS.md, docs/SECURITY.md and docs/IDEAS.md.

## Do these in order (you, after the PR)

Nothing was deployed and no migration was applied from the build session.

1. **Merge the PR** (`feat/cards-ideas-security` into `main`) once CI is green.
2. **Apply the database migrations first**: `supabase db push --remote`.
   This applies `20261105000001` (indexes), `20261106000001` (Plaid items and slot fix), `20261106000002` (Activity RPCs,
   cards and loans) and `20261106000003` (security).
   > Order note: you listed `railway up` before `db push`. I put the database first because the new API reads tables and
   > columns that only exist after these migrations (`plaid_items`, `audit_log`, `ingest_tokens.scope`, `accounts.*` card
   > fields). Deploying the API first would make bank links, capture and tokens fail until the push. Every migration is
   > additive, so the API that is running now keeps working against the new schema.
3. **Check the database**: `python3 tools/run_rls_tests.py`. It runs `rls.sql`, `attacks.sql` and `flows.sql` against the
   project and rolls each one back. All three should say "passed".
4. **Deploy the API**: `cd api && railway up --service tick-api --ci`.
5. **Live check**: `python3 tools/e2e_deployed.py`. It needs email sign-in for a throwaway user, so run it **before** step 7.
6. **Run on the iPhone** (`docs/RUN_ON_MAC.md`, then the checklist below). There are two new plugins (`file_picker`,
   `flutter_secure_storage`, no extra pods) and a new Swift file (`TickPrivacy.swift`), so run `cd app && flutter pub get`
   and let Xcode re-run `pod install`.
7. **Lock down Supabase Auth**: `python3 tools/auth_config.py`, read the report, then `python3 tools/auth_config.py --apply`.
   This closes new sign-ups (your account already exists; Google sign-in keeps working), turns email sign-in off, sets
   the redirect allow-list to exactly `tick://login-callback` and makes access tokens 15 minutes. Also set
   `TICK_OWNER_USER_IDS` in Railway to your user id (see `docs/SECURITY.md` §5).
8. **Link banks one at a time**, and check the counter after each one (Settings > Bank connections, and Banks >
   "You have N of 10 bank links left"). Each link should cost exactly one.
   1. **SoFi** (one link covers checking, savings and the student loan; credentials, not OAuth).
   2. **Discover** (pick plain "Discover", not "Discover - Student Loans").
   3. **Bank of America** (pick plain "Bank of America").
   4. **Capital One**.

   After each link, wait a minute, pull to refresh, and confirm that the cards show owed, due date and utilisation and
   that the counter dropped by exactly one. If a link ever shows "Your bank may still be connecting", **don't link again**:
   pull to refresh after a minute. The webhook usually finishes it.
9. Do the manual security steps in `docs/SECURITY.md` §5: 2FA everywhere, delete the tokens from the Claude
   environment, rotate the Supabase secret key, a $0 OpenRouter limit, delete the Gemini key, and the GitHub settings.

### Your Plaid counter
The "10 → 8" was a Tick counting bug, not two Items: the logs show one link session, one `item_id`, exchanged twice in the
same second (the webhook and the app raced). Only **one** Plaid Item was created (Chase). After the migration the counter
is rebuilt from distinct item_ids, so Tick will say **9 left**. Plaid's dashboard is the final word: if it shows a
different number, tell Tick by adding that item to `plaid_items` by hand.

## What I must verify on the real iPhone

Nothing below can run in the build sandbox (no Xcode, no device).

1. [ ] `flutter pub get` and the Xcode build succeed, including the new Swift `TickPrivacy.swift` and the two new pods.
2. [ ] **Sign-in survives the Keychain move**: after updating, you are still signed in (the old session is moved from
   SharedPreferences into the Keychain once). Sign out and back in with Google, kill and relaunch: still signed in.
3. [ ] **Activity**: the month strip (Nov 2026, Oct 2026, …, All time) with in, out and net; scroll far down and pages keep
   loading with a skeleton row at the end; the account-type and per-account chips ("Chase ••1173") filter the list
   **and** the totals; search finds merchants, notes and categories; airplane mode still shows this month's first page.
4. [ ] **Cards on Today and Banks**: owed, due date, utilisation bar (Clay above 30%); tap a card for the statement, minimum,
   APR, the statement cycle (closing date, "pay $X by …" to report under 30%) and spend by month.
5. [ ] **Safe to spend** subtracts the card statements due before payday (the "cards due" pill), and the loan payment if it's
   due before payday. "Truly free" shows what's left after every card balance.
6. [ ] **Card-due guard**: when checking can't cover the cards and bills due before payday, Today says by how much (Clay).
7. [ ] **What if…** pill: enter an amount and see what's left until payday, with the price-weight haptic.
8. [ ] **Notifications**: a card due-date reminder 2 days before at 9:00; a utilisation heads-up 3 days before a
   high-utilisation statement closes; tapping either opens that card.
9. [ ] **Link confirm**: "Link a bank" shows "This uses 1 of your N remaining links" and needs a hold to continue.
10. [ ] **Apple Card**: buy something with Apple Pay on Apple Card. It lands on the "Apple Card ••…" account. Then Settings
    > Import Apple Card statement with a real CSV: "Imported N, skipped M duplicates", and nothing shows twice.
11. [ ] **Privacy**:
    - [ ] Hide amounts turns every amount into `$••••`, including notifications.
    - [ ] Start a screen recording from Control Center: amounts hide while it runs.
    - [ ] Face ID "Ask after 1 min": quick app switches don't ask; after a minute away they do.
    - [ ] The app switcher shows the cover.
12. [ ] **Files**: in Xcode's Devices window, download the app container: `Library/Application Support/ledger_cache.json`
    exists and is excluded from backup. (File protection can't be seen there; trust the code or check with a locked-phone
    background refresh.)
13. [ ] **Panic** (try it once): Settings > Panic. You are signed out everywhere; the old Shortcuts token is refused (401) at
    once; sign in again and make a new token.
14. [ ] Everything from the previous checklist still holds: launch speed, Google sign-in, haptics, Face ID,
    `--release` smoothness.

## Later
- **FinanceKit for Apple Card.** Apple Card data is only readable through FinanceKit, which needs the
  `com.apple.developer.financekit` entitlement. Apple grants it on request to organisations, so a personal app with a free
  account almost certainly can't get it.
  - To try: enrol in the paid Apple Developer Program, request the entitlement (developer.apple.com > Contact > FinanceKit),
    then add a small Swift plugin that reads `FinanceStore` transactions and posts them to `/ingest` as source `applecard`.
  - Until then: Wallet capture plus the statement CSV import.
- The ideas left as tickets in `docs/IDEAS.md` (subscription detective, Zelle ledger, duplicate and fee detector,
  weekly recap image, Ask Tick what-if, loan payoff, sweep nudges, rewards picker, splits).
- Lock Screen widgets, Live Activity and Action Button: need a paid Apple account (App Groups).
- Ingest and import serialise per user with an in-process lock (one Railway replica). Scaling out needs a Postgres
  advisory lock.
- The food-pace nudge still sums the rows on the phone (it is a heuristic, not a displayed total). Move it to the server
  with the subscription detective.

## AI status
Unchanged from the last session:
- OpenRouter `:free` models only, `data_collection=deny`, 15 a minute and 40 a day, rules first.
- New in this session: prompts mark merchant and note text as untrusted, Ask Tick can only read, and model-written
  merchant names are bounded (`docs/SECURITY.md`).
- Re-verify the models with `python3 tools/ai_smoke.py` when they rotate.

## Deployed (as of this branch: NOT redeployed)
- API: https://tick-api-production.up.railway.app (Railway project `tick-api`).
- Supabase: migrations up to `20261104000007` applied; `20261105000001` and the three `20261106*` are waiting for `db push`.

## Splitwise, APNs, Sign in with Apple, opening Tick to others
See the plans in the git history of this file (`git show main:docs/NEXT.md`) and `docs/IDEAS.md` #6 and #14.
