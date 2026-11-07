# Tally v2

Branch `feat/tally-v2`. Nothing here is deployed: migrations are not pushed, the API is not released.

## How this was tested
- SQL: `tools/local_db.py test` against a throwaway Postgres 16 (binaries in a scratch folder, `PG_BIN` and `TICK_PGDATA` set).
- API: `cd api && pytest`.
- App: `flutter analyze`, `flutter test`. On this Mac 67 tests fail before any of this work (66 goldens rendered elsewhere, and
  `bank_status_test`). Those same tests still fail; nothing new does.

## Phase 1: friends-and-family money
Done.
- Insights shows Friends and family as one net line in "Money with friends", out of the totals by default, with the toggle
  "Include money with friends" (`settings.include_friends`). The rule is in `tick_classified` (`20261109000001_friends_money.sql`), so
  Activity totals, budgets and Ask Tick follow it. Safe to spend reads balances, not spending; what it follows is recurring detection, which
  no longer builds bills from these rows, and old P2P recurring rows are ended.
- Paybacks: `api/app/paybacks.py` suggests, `tick_payback_link` links under row locks, a trigger keeps `reimbursed_cents` and the flow true.
  Activity shows the newest question; the transaction detail shows questions, links and Unlink.
- Splitwise: `api/app/splitwise.py`, wired into `/import/statement`, deduplicated by row ref, undoable by batch.

Decisions
- "Zelle payment to Rent" would have vanished from spending under the new rule, so P2P to rent is categorised Rent (ingest, import, and a
  one-off update in the migration that skips rows whose category was edited by hand).
- A payback is one whole credit against one purchase. Splitting one Zelle across two purchases isn't supported.
- `VENMO CASHOUT` stays Friends and family, so it is out of income by default, and it is never suggested as a payback.
- "Not a payback" dismisses the credit for good, not one pairing.
- The rule keys on the category NAME 'Friends and family'. Renaming that category turns the rule off for it.
- In Activity a friends row keeps its amount but doesn't count in the day total, like a transfer. It isn't dimmed yet.

Assumed
- **The Splitwise format is assumed.** `imports/splitwise/` has no sample, so `api/tests/data/splitwise_roommates.csv` is a fixture written
  from the description. Check it against a real export before trusting an import.
- Multi-payer Splitwise rows become one expense per payer: balances stay exact, the original total is not kept on one row.

Deferred
- Demo mode has no payback suggestions (they come from the server).
