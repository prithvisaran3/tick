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
