# UX v4

Branch `feat/ux-v4`. Nothing deployed.

## Phase 1: Home shows balances; Safe to spend moves to Insights
Done.
- Home: "Cash" leads (checking accounts that count, available balance or current when the bank gives none), counting up on open, one quiet row per account
  (tap for its transactions; the number opens every account). Savings is its own card. Cards is one row (owed, next due) and never comes off Cash. Then one
  suggestion at most (Payday plan near payday, else the top nudge) and the last 5 purchases with See all. The bill pills, strips, card guard, owed-to-me card and
  what-if left Home: card guard, truly free and what-if now live inside Insights' "How it's calculated"; owed-to-me is on Tally; bills are in the breakdown.
- Insights opens with "Safe to spend this pay period": amount, period from `pay_period`, days to payday, and a breakdown (each checking account, each bill before
  payday, each card and loan payment due, each goal) whose signed lines sum to the headline. `computeSafeToSpend` now builds those lines and derives its totals
  from them, so they can't drift.
- The widget, the Morning Receipt and the intro lead with Cash, with Safe to spend second.

Real data (read-only DB check): 4 checking (Bank of America, Capital One, Chase, SoFi), 1 savings (SoFi), 4 cards (Apple Card manual, Bank of America, Capital
One, Discover) and 1 student loan. Checking plus savings is $1,837.06 as expected. No classification bug: savings is typed savings and switched off for Cash,
cards and the loan are typed credit and loan. Capital One checking has no available balance from the bank, so its current balance counts.

## Phase 2: Profile
Done. Tap your avatar on Home (or the gear in Profile for Settings). Settings now holds app preferences only: security, appearance, Ask Tick, data, labs, about.
- You: avatar, name (also saved to the profile), @handle with an "Available / taken" check as you type (`GET /people/handle/check`, rate-limited),
  findable toggle, Zelle email or phone.
- Pay: schedule with the same editor and live preview as onboarding, take-home (exact or "it varies", with a suggestion from the last three paychecks it
  can see), the account pay lands in, who pays you (suggested from deposits; Landed now accepts a deposit that names the employer even when the amount
  varies), an optional second income with its own schedule (its paychecks get their own expected rows from the same SQL), and Pay statements.
  Saving writes `settings.payday_rule`, refreshes the SQL pay period, and says "Next payday Fri, Nov 13 · $X expected". Past transactions never change.
- Money setup: goals (add, edit, pause, delete with undo; paused goals plan nothing), recurring bills (amount, next date, not recurring with undo), and which
  checking accounts count in Cash.
- Categories and rules: category rules (amount, delete with undo), what Ask Tick learned (tap to forget, with undo), and Suggested rules when Phase 10 has any.
- Banks and cards: banks (owner only; others read "Banks are linked by this Tick's owner"), Apple Card, the capture token.
- Help: Show tips again, Watch the intro.
- Holidays now include the federal observed rule both ways: a Saturday holiday is observed the Friday before (July 4th 2026 → Fri Jul 3), a Sunday one the
  Monday after. SQL (`20261119000001_profile.sql`) and Dart share the test cases.

Decision: a take-home change moves the Payday plan, not Safe to spend: Safe to spend is cash until payday and doesn't count pay that hasn't landed. The test
checks the plan.

### Every onboarding question, and where it's edited now
| Onboarding asked | Edited in |
|---|---|
| Sign in with Google | Profile > You (if not signed in) |
| How often you're paid | Profile > Pay > Schedule |
| Your next payday (or two days a month) | Profile > Pay > Schedule |
| Take-home per paycheck | Profile > Pay > Take-home |
| Rent (monthly) | Profile > Money setup > Recurring bills (it's saved as the Rent bill) |
| Other bills and subscriptions | Profile > Money setup > Recurring bills |
| Savings each payday | Profile > Money setup > Goals ("Savings") |
| Your handle (sheet at the end) | Profile > You > Handle |
| Link a bank / import / skip | Profile > Banks and cards, and Import from Activity |
| The intro | Profile > Help > Watch the intro |

## Phase 3: Pay statements
Done, files only (no ADP sign-in).
- In: a PDF through the same paths as statements: share sheet "Open in Tick" (PDF is now a document type), Files, Mail, the Import screen, and the "Import
  statement to Tick" Shortcut (accepts PDF). A PDF is treated as a pay statement; bank statements stay CSV or OFX, and a PDF that isn't a pay statement says so.
- Reading: `pypdf` takes the text layer. `api/app/paystubs.py` reads ADP's earnings statement deterministically (pay date, period, every earning, tax and
  deduction with YTD, net). **The ADP layout is assumed**: `imports/paystubs/` had no real statement, so the fixture (`tools/make_paystub_fixture.py`,
  made-up values and person) follows the standard layout. Anything else goes to the AI provider as text with name, address, SSN fragments, employee ID and long
  numbers stripped first, strict JSON back. A PDF with no text layer is refused with a reason rather than sent as an image, because personal details can't be
  removed from an image first. If gross − taxes − deductions ≠ net within a cent, the statement is saved as "Check this one" instead of silently.
- Stored: `pay_statements` + `pay_statement_lines` (owner-only RLS, app can read and delete, only the server writes), deduped on pay date + net + employer.
  The PDF is kept only with "Keep the PDF" on (private `paystubs` bucket, owner folder).
- Matching: the net-pay deposit within $1 and 3 days, in the pay account; it reads "Paycheck · Nov 13" and its detail shows the breakdown. Later expected
  paychecks (Landed) take the latest net. Profile > Pay shows "Latest: Nov 13 · $X net".
- UI: the statements list and a waterfall per statement (groups open to lines, YTD toggle); Insights has one Pay card, collapsed, opening to this year's gross,
  taxes, 401(k), net and "You keep N% of gross", with a by-month view. Ask Tick: "how much tax have I paid this year", "what was my last net pay", "how much
  went to 401k", "gross pay last year" (eval now 54/54 on rules).

### Plaid Payroll Income (investigated, not built)
- Your Items today hold `transactions` (Chase) and `liabilities` + `transactions` (Bank of America, SoFi, Discover, Capital One), from the read-only doctor.
  Income isn't among them; whether your plan has it enabled for production can only be seen in the Plaid Dashboard (Team settings > Products), which I can't
  open. Plaid's pricing lists Income as included on Pay as You Go, Growth and Custom plans; Payroll Income is a one-time fee per connection.
- It's a separate Link session with the `income_verification` product (`income_source_types: payroll`) and can't share a session with other products. It
  covers roughly 80% of US workers through payroll providers; Plaid's sample responses show ADP as an institution, but I couldn't confirm ADP is supported for
  every employer.
- Item slots: the payroll response carries an `item_id`, so it most likely creates an Item and would use one of your 10 lifetime slots. Ask Plaid support
  before relying on that.
- Plaid now steers new customers to Consumer Report Income instead, which reads bank deposits, so it doesn't need ADP at all.
Sources: https://plaid.com/docs/income/payroll-income/ · https://plaid.com/docs/account/billing/ · https://plaid.com/pricing/ · https://plaid.com/docs/income/
