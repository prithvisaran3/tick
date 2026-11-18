# Plan v5: the app I open every payday

Branch `feat/plan-v5`. One idea runs through every phase: **a paycheck lands, gets split across accounts, feeds goals, absorbs surprises, and
Tick says what's left.** Each phase adds one link in that chain and the next phase reads it.

```
pay statement ──> splits ──> expected deposit per account ──> Safe to spend (included checking only)
                     │                                             ▲
                     └──> savings accounts ──> goals (real balances, per-paycheck need) ──┤
planned one-offs ────────────────────────────────────────────────────────────────────────┘
goals + plan + one-offs ──> suggestions (rules pick, LLM words) ──> Insights (4 blocks)
```

## Rules that hold everywhere
- Integer cents. Every number comes from SQL or Dart/Python math with shared test vectors (`api/tests/data/*.json`); the LLM only words text.
- Every new table: forced RLS, owner-only, an RLS test in `supabase/tests/`. Server-written tables are select-only for the app.
- At most 3 sections a screen; secondary detail behind a tap. Goldens at 320 and 430, dark and light, looked at after each UI phase.

## Data model (one migration per phase)
| Phase | Change |
|---|---|
| 1 | `pay_statements.deposits jsonb` (`[{label, mask, cents}]`), `pay_statements.problems jsonb` (field names that needed a hand fix). |
| 2 | `pay_splits` (user, account_id or manual `label`+`mask`, `kind` percent/fixed/rest, `value` basis points or cents, `sort`; one `rest` per user). `expected.account_id`. SQL `pay_split_amounts(uid, net)` mirrored by Dart `splitAmounts`. |
| 3 | `account_balances` (account, day, balance; written nightly, select-only). `goals` + `mode` (balance / save_more), `start_cents`, `start_date`, `account_ids uuid[]`. `goal_moves` (pay date, cents, done / confirmed, balance before). |
| 4 | `planned_expenses` (name, cents, date, status planned/matched/dismissed, `matched_txn`, `goal_id`, `resolution` catch_up / move_deadline, `shortfall_cents`). |
| 5 | `plan_suggestions` (day, kind, facts jsonb, text, status shown/accepted/dismissed). `ask_memory` kind `suggestion` (per-kind accept/dismiss counts). |

## The math (pure functions, Dart and Python twins)
- `splitAmounts(net, splits)`: fixed lines first (capped at what's left), then percents of net (floor), the rest line takes the remainder. Sums to net exactly.
- Safe to spend = cash in included checking − bills − cards/loans due − **goal moves still to make this period** − **planned one-offs dated before payday**.
  On payday before the deposit lands, only the split lines into included checking are added, never the whole net.
- `goalStatus(goal, balances, payDates, today)`: saved = linked balances (balance mode) or linked balances − `start_cents` (save more).
  paychecks left = paydays in (today, deadline]. need per paycheck = ceil(remaining / paychecks left). Status: done / on track / behind by $X
  (behind = need per paycheck exceeds what the plan can fund). Test: $9,000 in 3 months, biweekly.
- A planned one-off that leaves less than the period's goal moves makes a shortfall. Catch up: later paychecks carry it (falls out of `goalStatus`
  because progress is real balances). Move deadline: the first payday on which the old per-paycheck amount still reaches the target.

## Screens
- **Import review** (1): the parsed statement with any unreadable field editable inline, deposit lines listed.
- **Profile > Pay > Where it goes** (2): split lines with live dollars, one "the rest".
- **Savings** (3, from Home's Savings card): accounts with balance, change this month, trend line; Goals below; goal editor as a sheet.
- **Home on payday** (3): one card, "Move $X to savings", Done.
- **Plan** (4, inside Safe to spend's breakdown): planned one-offs, add sheet, the one-line trade-off with two choices.
- **Insights** (6): Safe to spend; top goal; suggestion card (when there is one); this period vs last, top 4 categories + See all. Everything else is a drill-down.
- **Import > Apple Card how-to** (7).

## Ask Tick (5)
Tools `goal_status`, `paycheck_plan`, `planned_expenses`, `savings_trend`; `what_if` learns a one-off that saves nothing. Suggestions: rule-picked
candidates (goal behind, move to savings, one-off coming, room to spare), at most 2, payday and weekly, wording by the LLM with a template fallback.
Accept/dismiss counts feed `ask_memory`; a kind dismissed twice rests for 30 days.

## Order and commits
1 import fix → 2 splits → 3 savings and goals → 4 one-offs → 5 planner → 6 Insights → 7 Apple Card CSV → 8 up to five judged improvements → finish.
Each phase: migration, math + vectors, API, UI, tests, goldens, an entry in `docs/PLAN_V5.md#log`, commit and push.

## Log
### Phase 1: pay statement import (fixed)
- **What was failing.** The upload itself was fine (picker, multipart `file`, auth, 5 MB limit all reached the API). Railway logged two
  `POST /import/statement -> 422` on Nov 10 and a pypdf font warning. The parser had been written from an assumed layout: it read the PDF's text
  stream line by line, but ADP draws columns, puts a benefits box on the same rows as the deductions, writes "Deductions Statutory" as one header and
  lists deposits after Net Pay. The first realistic fixture reproduced it: taxes stopped after the first row and the statement didn't add up.
- **Fix.** Each page is read three ways (rows rebuilt from positions, pypdf's layout view, the plain stream) and the reading that parses best wins.
  The right-hand column is read as its own column. Which number on a row is "this period" is settled by what makes earnings equal gross and
  everything equal net, so hours and year-to-date-only rows can't become pay. Deposit lines and their account endings are kept
  (`pay_statements.deposits`). Password-protected PDFs, files over 5 MB and files holding several statements each get their own message.
- **Review.** Preview returns `problems` by field name. The review screen asks for exactly the missing field, lets any amount be corrected
  ("Something wrong? Fix it"), shows how far it is from adding up as you type, and sends only what changed. A corrected total replaces that group's lines.
- **Logs.** One line per read: which view won, counts, and true/false per field. Never a value. pypdf's own warnings are silenced because they echo bytes.
- **Not done:** `private/paystub.pdf` wasn't in the repo folder, so the real file was never opened. The fixtures (`tools/make_paystub_fixture.py`)
  mirror ADP's layout with made-up values in five variants: drawn row by row, drawn column by column with a Symbol font, two pages, no
  year-to-date column with one deposit, two statements in one file.
### Phase 2: paycheck splits
- `pay_splits` (migration `20261124000001`): a line is a percent, a fixed amount or "the rest". Written only through `save_pay_splits`, which
  checks the whole set (exactly one rest, percents within 100%, each account once and mine) and replaces it atomically.
- One arithmetic in three places with one vector file (`api/tests/data/pay_splits.json`): SQL `pay_split_amounts`, Python `split_amounts`,
  Dart `splitAmounts`. Fixed first, then percents of the whole net (floored), the rest line takes the remainder, so lines always sum to net.
- Profile > Pay > **Where it goes**: each line shows its dollars as you type, problems are named in one line and Save is off until it's valid.
  "Use my last pay statement" pre-fills from the statement's deposit lines, tied to accounts by their last digits; the biggest line becomes the rest.
- Payday: one expected deposit **per account** Tick can see (`expected.account_id`); a whole-paycheck row still waiting is replaced, never doubled.
  A deposit lands only the line for the account it arrived in, and needs the amount to match (the employer's name alone can't tell lines apart).
  A statement with several deposits links each one to its own bank row, each row used once.
- Safe to spend on payday adds only the lines into checking accounts that count (`paycheckIntoCash`); savings and outside accounts never do.
### Phase 3: savings and goals
- **Balances over time.** `account_balances` gets one row per account per New York day at the end of every bank sync (the sync job already runs;
  no new schedule). Savings (from Home's Savings card) shows each savings account's balance, its change this month and a small trend line.
- **Goals from real balances.** A goal has a name, an amount, an optional deadline, a mode ("Save this much" from today, or "Reach a balance") and
  the accounts it's saved in. It remembers what those accounts held when it started; saved is what they've grown since. Nothing is typed in.
- **Per paycheck.** Paydays between now and the deadline come from the pay rule (`paydaysBetween`, SQL `paydays_between`); each paycheck carries
  `ceil(remaining / paychecks left)`. Behind = saved is under the even pace so far, and the catch-up is already folded into the per-paycheck amount.
  Same arithmetic in Dart and Python with one vector file (`api/tests/data/goal_status.json`). $9,000 in 3 months, biweekly = 6 paychecks of $1,500.
- **Payday.** Home shows one card, "Move $X to savings", with Done. Done records what the linked savings held (`goal_moves`); the next sync confirms
  it when the balance has risen by at least 90% of the move, and after two days without a rise the card says Tick hasn't seen it. Safe to spend
  stops setting the amount aside once it's marked. The old fake "Move to savings" transfer is no longer written for linked goals.
- Goals made before this have no account: they keep what was typed and say "Link an account to track this from its balance".
- Profile > Goals now opens Savings; the old goals sheet is gone.
### Phase 4: planned one-offs
- `planned_expenses` (migration `20261126000001`, owner-only RLS; a trigger refuses a matched transaction or goal that isn't mine).
- Safe to spend > "Plan a one-off": name, amount, date. A one-off dated before the next payday (and not more than a week past) comes out of
  Safe to spend as its own line in "How it's calculated" until it's bought. Test: Birthday gift, $500, Nov 22 lowers Safe to spend by exactly $500.
- **Trade-off.** If the plan no longer fits (Safe to spend below zero with goal moves and one-offs taken out), the gap comes out of this paycheck's
  goal move, capped at that move. One line says so ("Birthday gift leaves $200.00 less for House move this paycheck."), with two choices:
  "Add $40 to later paychecks" (the shortfall spread over the paychecks after this one; progress is real balances, so later paychecks carry it
  automatically) or "Move deadline to Feb 19" (the first payday after the old deadline that covers it at the current amount, saved on the goal).
  Either choice stores the shortfall on the one-off, and this period's goal move shrinks by it, so the plan fits again.
- **Matching.** The purchase a one-off became (money out, within 20% or $20, within a week) is offered once through the existing Yes/No card.
  Yes drops it off the plan; No never offers that purchase for it again.
- Pill button labels now shrink to fit instead of cutting a word.
### Phase 5: Ask Tick as a planner
- New typed tools: `goal_status`, `paycheck_plan`, `planned_expenses`, `savings_trend`. Ask Tick's Safe to spend now uses the same pieces as the
  app (goal moves from real balances less any absorbed shortfall, planned one-offs this period). The pure arithmetic sits in `api/app/plan_math.py`.
- `what_if` saves nothing and says so ("Nothing changes until you plan it."). Above Safe to spend it says what the first goal would get instead
  ("Emergency fund would get $600 instead of $750 this paycheck") when the gap fits inside this paycheck's move.
- Eval: 60/60 on rules (was 54), including "Am I on track for my savings goal?", "Can I afford $300 this weekend?" and "What if I spend $500 on a
  gift this month?", with a goal and a planned one-off in the seeded ledger. Expected numbers are worked out by hand in the eval, not with the app's maths.
- **Suggestions** (`plan_suggestions`, migration `20261127000001`): on payday (or the day after) and otherwise once a week, rules in
  `api/app/suggestions.py` pick from five kinds, most urgent first: over plan, goal behind, move to savings, a one-off within a week, room to
  spare. At most two. The model rewrites the template and the rewrite is kept only if it has exactly the same dollar amounts and no new numbers.
  Accept and dismiss go to `ask_memory` (kind `suggestion`); a kind dismissed twice rests for 30 days; accepting resets it.
- App: one card, "Suggested", up to two rows (tap acts and opens the right screen), "Not now" dismisses both. It shows only when there is one.
### Phase 6: Insights, simplified
- Insights is exactly four blocks, in order: **Safe to spend this pay period** (with "How it's calculated", planned one-offs and the trade-off
  line); **the top goal** (behind first, then nearest deadline; "All goals" opens Savings); **the suggestion card** (only when there is one);
  **spent this pay period** against the same number of days of the last one, top 4 categories, "See all".
- "See all" (`/insights/more`, "Spending") holds what used to be on Insights: the month against last month and its projection, every category,
  money with friends, top merchants, subscriptions and the Pay card. Nothing was deleted; nothing on Insights repeats it.
- "0% less" now reads "About the same as the last one". Goal dates use a non-breaking space so "Dec 28" never splits.
- Goldens: insights, insights-more and savings at 320 and 430 (dark) plus 393 dark and light, checked by eye.
### Phase 7: Apple Card CSV
- The import path already read Wallet's CSV (`api/app/applecard.py`, detected by its columns) and de-duplicated against live captures. Added a
  test with Wallet's real column set that proves it against the Shortcut: a capture named "APPLE.COM/BILL" matches the CSV's "Apple Services"
  on the Apple Card account; one of two identical same-day purchases matches and the other is added; a return comes in as money back; the card
  payment comes in as a transfer; an installment on another card isn't touched; importing the same file again adds nothing.
- The how-to (Import screen and docs/SHORTCUTS_SETUP.md) now gives Wallet's actual path: Apple Card → Card Balance → a statement → Export
  Transactions, and says Shortcut captures are matched, not added again.
- Profile > Banks and cards > Apple Card pointed at a screen that was never built (`/apple-card`); it now opens the import.
