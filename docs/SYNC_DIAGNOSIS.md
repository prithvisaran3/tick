# Bank sync diagnosis

Run on 2026-11-06 with `python3 tools/plaid_doctor.py` against production. It is read-only: `/item/get`, `/accounts/get`, a throwaway
`/transactions/sync` (empty cursor, never saved) and SELECTs. The output below is redacted (no tokens, names, merchants or amounts).

## What Plaid says vs what Tick holds

| Bank | Plaid Item state | Plaid rows | Tick rows | Tick's own status |
|---|---|---|---|---|
| Chase ••1173 | healthy, transactions only | 220 | 220 | "Syncing" in the app, but the row says `active` and synced |
| SoFi (savings ••3264, checking ••9923, loan ••6393) | healthy, transactions + liabilities | 3 + 4 + 0 | 3 + 4 + 0 | `active`, synced, shown as "Syncing 3 accounts" |
| Discover ••1545 | healthy, transactions + liabilities, webhook set | 32 | **0** | `error` / `SYNC_FAILED`, no cursor |
| Bank of America (card ••5498, checking ••9681) | healthy, transactions + liabilities, webhook set | 75 + 24 | **0** | `error` / `SYNC_FAILED`, no cursor |

No Item has an error at Plaid, every Item has a webhook URL, and every Item has consented to `transactions` (and `liabilities` for the four
new ones). Plaid delivered `SYNC_UPDATES_AVAILABLE` / `HISTORICAL_UPDATE` for each. The banks are fine; Tick failed to save what they sent.

## Root causes

1. **Discover and Bank of America: one bulk insert was refused, so nothing was saved (the real bug).**
   The sync writes each page of new transactions in one PostgREST bulk insert. PostgREST requires every object in a bulk insert to carry the
   same keys. A row only got a `tags` key when it had tags (`business`, or `refund` for a card refund, which was added with the card work).
   Chase and SoFi have no tagged rows (checked: 0 of 220, 0 of 7), so their keys matched and they synced. Discover has 10 tagged rows out of
   32 and Bank of America has 7 of 99, so each page mixed shapes, the insert returned 400, the exception was swallowed by `_safe_sync`, the
   connection was marked `SYNC_FAILED` and the cursor was never saved. Accounts and Liabilities were saved first, which is why balances,
   limits and due dates showed while "No purchases" did.
   Fix: every row has every key (`_normalise`), the insert sends `Prefer: missing=default`, and if the database ever refuses a page the sync
   falls back to row by row and skips only the row it refuses. Regression tests reproduce PostgREST's rule in the fake database.
2. **The app could not tell the truth.** "Syncing" was printed for every connection that was not in error, regardless of what had happened. The
   `status` column only said `active` / `error` / `login_required`, and only one code path ever wrote it. Chase was healthy but still
   said "Syncing" forever.
   Fix: a real state machine on `connections.sync_state` (`pending`, `syncing`, `ok`, `partial`, `login_required`, `bank_issue`, `error`) with
   `last_attempt_at`, `last_error`, `initial_complete`, `historical_complete`, `last_webhook_code/at` and `last_added`. Every sync records its
   outcome (including unexpected exceptions, by class name only), and Banks shows plain words, a last-synced time, the transaction count
   per account, and never a spinner for more than ten minutes.
3. **Webhook coverage was partial.** Only some codes were handled and none recorded. Now every documented code is handled and recorded
   (`SYNC_UPDATES_AVAILABLE` with its `initial_update_complete` / `historical_update_complete` flags, `INITIAL_UPDATE`, `HISTORICAL_UPDATE`,
   `DEFAULT_UPDATE`, `TRANSACTIONS_REMOVED`, Item `ERROR`, `PENDING_EXPIRATION`, `PENDING_DISCONNECT`, `USER_PERMISSION_REVOKED`,
   `USER_ACCOUNT_REVOKED`, `NEW_ACCOUNTS_AVAILABLE`, `LOGIN_REPAIRED`, `WEBHOOK_UPDATE_ACKNOWLEDGED`, Liabilities updates).
4. **No retry safety net for a missed webhook.** The 6-hourly job re-synced everything but nothing retried a connection that was stuck.
   Added a 10-minute job that retries only connections that are not up to date and were last tried more than 10 minutes ago.
5. **Pagination.** The loop already followed `has_more` and saved the cursor only at the end. Added the documented restart when Plaid
   reports `TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION` (start the page set over from the saved cursor; rows are idempotent).

## Not causes (checked)
- Account-type filters and sign handling for credit cards: a replay of the real Discover and Bank of America data through the mapping and
  the reconcile step produced every row with no error.
- Ownership / RLS on insert: the server writes with the service key.
- Unknown `account_id`s: accounts are upserted before transactions.
- OAuth / redirect URI: both OAuth banks (Discover, Bank of America) linked and returned data through Hosted Link without
  `PLAID_REDIRECT_URI`. If a bank ever asks for it, see docs/NEXT.md ("Plaid OAuth redirect").
- Items needing re-authentication: none today (no Item error at Plaid). The app now offers "Reconnect" (Link update mode, no new link) when it
  happens, and "Fix" with account selection when more accounts can be shared.

## Repair (after deploying)
`python3 tools/repair_sync.py` (dry run), then `--apply`: a fresh full sync per Item from an empty cursor, idempotent, then the money rules are
re-applied to existing rows. It never creates or removes an Item.
