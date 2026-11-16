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
