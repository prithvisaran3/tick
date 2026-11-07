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

## Phase 2: shared groups
Done: data model, RLS, search, invites, activity, guests, API port, and the app's data layer, search, inbox and handle screens. Group
management screens are in phase 3.
- `20261110000001_tally_shared.sql`. Members are rows with an id; a member is a Tick user (`member_user_id`) or a guest. Expenses, shares and
  settlements point at member ids, because "me" now depends on who is reading. `tools/test_tally_migration.py` seeds old-shape data, applies the
  migration and checks every row and balance survived, including a person who had left the group but still has history.
- `is_tally_member` and friends are SECURITY DEFINER. `supabase/tests/tally_shared.sql` covers member vs stranger, creator vs owner, removed
  member, leave and remove blocked with a balance, invite flow, search, and the activity log.

Decisions
- `user_id` on Tally rows stays the group owner (the tenant); `created_by` is the writer. That kept every composite key and account deletion.
- Old columns are renamed `legacy_*`, not dropped, so a bad migration can be undone. Drop them one release later.
- Writes are narrow: expenses and shares change only through `tally_save_expense` so an amount can't drift from its shares. Direct grants are
  insert plus `deleted_at` (and `status` on settlements). Nobody hard deletes, including the owner.
- A guest's phone and email stay in the adder's private `people` book. Other members only ever see the name.
- Search matches email against `auth.users`, not the editable profile copy, so nobody can claim someone else's address.
- Inviting checks `discoverable` too, so a hidden person can't be invited by id. Pending invites are capped at 30 per inviter.
- Any member can add a guest or invite someone. Only removal is owner-only, as specified.
- The owner can't leave (they delete the group instead). Transferring ownership isn't built.
- Any member can make a share link. The row belongs to the group owner.
- "Delete all my data" now removes groups I own. Before this, deleting `people` would have failed on the restrict keys once Tally had rows.
  Groups I only belong to keep my member row with my name and no account link.

Check before `supabase db push`
- The migration stops if its role lacks BYPASSRLS, because the helpers would recurse. This was only tested locally as a superuser.

Known gaps
- Phone numbers on profiles aren't verified, so someone could enter another person's number and be found by it. The searcher sees their name
  and handle before inviting.
- A settlement holds one bank row. In a group of two Tick users only one side's Zelle can be linked; the other stays a Friends and family row,
  which is out of the totals by default anyway.
- Avatars: the column and search field exist, there is no upload yet, so everyone gets initials.
