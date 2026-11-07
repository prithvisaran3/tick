# Tally v2

Branch `feat/tally-v2`. Nothing here is deployed: migrations are not pushed, the API is not released.

## How this was tested
- SQL: `tools/local_db.py test` against a throwaway Postgres 16 (binaries in a scratch folder, `PG_BIN` and `TICK_PGDATA` set).
- API: `cd api && pytest`.
- App: `flutter analyze`, `flutter test`. On this Mac 67 tests fail before any of this work (66 goldens rendered elsewhere, and
  `bank_status_test`). Phase 5 fixed those; the full suite now passes.

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

## Phase 3: Tally features
Done.
- Groups: create with type-ahead search, emoji and colour; add, remove, rename, archive, delete with a confirm and five seconds of undo; leave.
- Expenses: edit, delete with undo, note, category, receipt photo. Other members open a receipt through a signed link
  (`/tally/expenses/{id}/receipt`), because the bucket is private. There is no viewer for that link in the app yet.
- Settle up per person: simplified amount, partial amounts, method. Payments can be changed or deleted with undo.
- Remind: inbox and badge for Tick users, prefilled message for guests, three tones, one per person per group per 24 hours, enforced in SQL,
  with the amount taken from the balance.
- Balances: totals, per-person ledger (tap a name), group activity feed.
- A pending "I paid" whose exact amount lands from that person is offered as "Mark received" on Activity (`/paybacks/received`).

Deep links, checked against docs on 2026-11-06
- Venmo: the documented web payment link, `https://venmo.com/?txn=pay&amount=..&note=..` (venmo.com/paymentlinks). Tick doesn't store Venmo
  usernames, so there is no recipient. The undocumented `venmo://paycharge` form isn't used. Not tested on a phone.
- Cash App: no amount-in-URL format is documented, only blog and forum mentions of `cash.app/$tag/amount`, so Tick copies the amount and opens
  cash.app.
- Zelle: copies the amount and says to open your bank app.

Decisions
- Multi-payer expenses aren't built. It wasn't cheap: balances, the sheet and the RPC all assume one payer.
- A member marking "I paid" is confirmed at once, as the spec says anyone can add a settlement. Only the public page creates pending ones.
- `url_launcher` is a new dependency in `pubspec.yaml`. `pubspec.lock` holds it uncommitted, alongside your local changes.
  iOS needs a `pod install`, which a normal build runs.

Follow-up
- **APNs.** No push notifications: the free Apple Personal Team can't send them. Reminders and invites wait in the inbox until the app is opened.

## Phase 4: better than Splitwise
All five built.

1. Split from the card charge. "Split this" on a purchase prefills the expense and keeps the link. The friend's payback then ranks that purchase
   first. **Decision:** the brief says Tick "pairs it automatically", but phase 1 says never auto-link without acceptance unless a settlement
   already matches. Phase 1's rule won, because money rules shouldn't move on a guess. So it is one tap: accepting the payback nets the purchase
   and, when it is exactly that friend's share, settles them too (`settle_split`). If a settlement already exists and matches exactly, it does
   happen on its own (`auto_link`, `_net_the_purchase`).
2. Recurring shared bills. Choose Repeat on a new expense. `tally_recurring`, `tally_post_recurring`, and a daily job (`/jobs/tally-recurring`, in
   `api/app/tally_bills.py`). A charge on the payer's bank that names the bill, is within 5% and within 5 days posts it early and links it.
   Otherwise it posts on its date. A retry of the same date does nothing. A bill stops itself if its payer or a sharer has left. The expense keeps
   the bill's amount even when the charge differs by a little. A charge that arrives after the bill already posted isn't linked back.
3. Receipt itemised split. "Split a receipt" in a group: `/tally/receipts/items` reads lines with the existing OpenRouter vision models, tap items
   onto people, tax and tip shared in proportion, exact to the cent. Any failure opens the ordinary split. I am always the payer here, and the
   photo isn't stored. Extraction wasn't tried against a real model or receipt.
4. Smart settle plan. "Settle everything" on Tally: each group simplified, then netted per person across groups. The same person is matched by
   Tick account, then address book entry, then name. Only my own payments show. "Mark as paid" records each group's settlement with method Other.
5. Group insights: who usually pays, six months of spend, and my real share against what I fronted, on the group screen.

## Phase 5: polish
Same look; new timing lives in `design/motion.json` and is generated into `motion.g.dart`. The durations and curves hard-coded in routes, sheets and
the square-up moment moved there too.
- `design/widgets/motion.dart`: `TickHero` (flies on the standard spring), `RollingNumber` (lands exactly, never overshoots the target), `StaggerIn`
  (first load only, per list), `SpringCurve`. Page transitions now use the spring instead of `easeOutBack`.
- Shared elements: group card to group screen, expense row to a new expense detail screen (`/tally/:id/expense/:eid`). The detail also opens the
  receipt, which closes the "no viewer" gap from phase 3.
- Balances roll. A member reaching zero shows "Settled up" with a Volt tick and the success haptic, then the row goes. A whole group settling uses only the
  existing square-up moment, so the two never stack.
- Expense rows swipe to edit and delete, with a haptic at the threshold and undo. Activity rows get the same haptic. Group screen gets pull to refresh.
- Skeletons on Tally, the group screen and Import. Empty states for expenses and "No tallies yet". Errors carry the specific reason plus Retry on Tally,
  Insights and group activity; failed saves now say why in the expense and settle sheets, which used to fail silently.
- Insights hero rolls, categories and Banks tiles stagger.
- Reduce Motion: no Hero flight, fades instead of movement, numbers cross-fade. `dynamic_type_test` now covers the new Tally screens at 320 to 430pt up
  to text x2.35. It and `motion_test` found two real bugs, now fixed: an entrance that left rows mid-state, and a settled row that never finished.
- Copy: the public page's "Slow down a little" and "That's plenty for now" became plain lines. The rest passed the check.

Goldens were regenerated on this Mac and reviewed by eye. In them the emoji and the ✓ render as boxes because the test fonts lack those glyphs; on a phone
the system font draws them.
`bank_status_test` was stale: 207ac1b deliberately removed link wording from the Reconnect line and the test kept the old sentence. The test now pins the
new copy and also fails if link wording returns.

## Zelle first
Friends pay by Zelle, so Settle up leads with Zelle and Cash; Venmo, Cash App and Other sit under "Other method" (code kept).
- `20261113000001_tally_zelle.sql`. `tally_zelle_notes` is my private note per member, set on the person screen. It falls back to what they share, then to the
  email or phone in my people book. `profiles.zelle` is "Your Zelle email or phone" in Settings: it goes in reminders to guests and **co-members can read it**
  through `tally_zelle_book`, so friends on Tick know where to pay. Strangers and ex-members can't.
- `paybacks.match_balances`: a person-to-person credit from the last 30 days, the same as or less than what that person owes me, asks "Mark Asha as settled?" on
  Activity. One tap records it (`/paybacks/settle`, which rechecks the balance). It replaces the reimbursement question for that credit. Names match on whole
  words, so "Jo" no longer matches "Major" anywhere in pairing. Two different people who fit equally get no suggestion. A credit more than they owe gets none either.

## Not verified
- Nothing ran on a device or simulator. Motion feel, the Venmo link, Messages prefill, camera and share sheet need a phone.
- The migrations have only run on local Postgres 16, not on Supabase.
- The Splitwise format is assumed (see phase 1). Receipt extraction hasn't met a real model or receipt.

## Before deploying, in order
1. Push the migrations. `20261110000001` stops if the role lacks BYPASSRLS.
2. Release the API in the same window: the old API and old app both read columns phase 2 renamed, so Tally breaks until both are out.
3. Build the app. `url_launcher` means a new pod.
4. `20261112000001` schedules `tick-tally-recurring` through `tick_call_api`, the same way as the other jobs.
