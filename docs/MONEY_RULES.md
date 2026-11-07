# Money rules

One definition, in one place: the SQL function `tick_classified` (`supabase/migrations/20261107000001_sync_status_money.sql`). Every total
in Tick reads its `out_c` / `in_c` / `excluded` columns: Today, Activity (rows, day headers, month headers), Insights, Tally ("you're owed"
is separate), Ask Tick's tools and the weekly summary. Demo mode has no database, so `app/lib/domain/flows.dart` mirrors the rules in Dart;
`app/test/money_property_test.dart` and `supabase/tests/money_rules.sql` (generated from the same fixture as the Python tests) keep the
two identical.

Money is integer cents. Negative = money out. Days are New York days.

## Spending (`out_c` > 0)
- Card purchases (credit card account, any bank, including Apple Card from Wallet or the statement import).
- Debit and checking purchases.
- Person-to-person money only when "Include money with friends" is on (see Money with friends). Zelle to rent is Rent, always spending.
- Bills, rent, subscriptions.
- Fees and interest (own category).
- **Student loan payments are a bill**: real cash out (`flow = 'bill'`), counted as spending but never as discretionary.

## Refunds
A positive amount on a card or loan that is not an Income row is a refund. It lowers spending (`out_c` is negative), is never income, and
lowers the category it belongs to.

## Income (`in_c` > 0)
- Payroll (for example "Institute Of Nuc Payroll").
- Zelle and P2P received from people only when "Include money with friends" is on, and never when it settles a Tally balance or is a payback.
- Interest earned on savings.
- Anything the person categorised Income.
Money arriving on a card or loan is never income (it is a payment or a refund).

## Excluded (`excluded` = true; neither spending nor income)
- **Internal transfers** (`flow = 'transfer'`), both sides: between my own accounts at one bank or across banks.
  Chase "SoFi Bank TRANSFER" and SoFi "JPMORGAN CHASE BANK, NA" are one transfer.
- **Card payments**, both sides. The card's purchases were already counted; Apple Card payments from Chase count even though Apple Card
  is not on Plaid.
- **The loan side of a loan payment** ("PAYMENT RECEIVED" on the loan account).
- **Tally settlements** (`flow = 'settlement'`): the expense is tracked in Tally; the Zelle that settles it is not income or spending again.
- Pending → posted duplicates and rows already seen in an import never become rows (reconcile and import de-duplication), so they are not
  counted twice.

- **Paybacks** (`flow = 'reimbursement'`): a credit accepted as a friend paying me back for a purchase.
- **Money with friends** (Friends and family rows with no flow), unless `settings.include_friends` is on.

## Money with friends
Zelle, Venmo, Cash App and PayPal to and from people is mostly Splitwise settling, so by default it is out of spending, income, budgets,
Ask Tick and the recurring bills behind Safe to spend. `tick_classified.friends_c` keeps the signed amount, and `tick_flows` returns
`friends_in`, `friends_out` and `friends_net` for the one net line in Insights. The toggle "Include money with friends" sets
`settings.include_friends`; the SQL reads it, so every total follows.

## Paybacks
A person-to-person credit within 21 days after a purchase, no bigger than what is left of it, is suggested as a reimbursement
(`api/app/paybacks.py`). Accepting writes `txn_paybacks`; a trigger sets the credit's flow and the purchase's `reimbursed_cents`, and `out_c`
of the purchase is net of it (my real share). Several paybacks can link to one purchase, never more than the purchase. Nothing links without
the person accepting, except a credit that matches an existing Tally settlement exactly (`paybacks.auto_link`).

A Transfer-**category** never excludes anything on its own. Only the flow does. (That is how Zelle to Kaarthik used to show $0.00.)

## How a transfer is recognised (`api/app/transfers.py`)
| Case | Rule |
|---|---|
| Checking pays a card or loan | Counterpart "payment" on a credit or loan account of mine: same amount, -1 to +5 days. One payment can cover two or three cards. |
| Cash account to cash account, any bank | Two cash accounts of mine, opposite amounts, -1 to +5 days, **and evidence**: one side names the other's bank (chase, jpmorgan, sofi, bank of america, discover, capital one), either side names me, or both say "transfer". |
| Zelle to or from my own name | Paired when my own account received it; unpaired it is still not spending or income (it is my money going to an account Tick can't see). |
| Zelle to or from anyone else | Never a transfer. |
| Card payment with no counterpart (Apple Card) | Excluded when there is strong evidence: Plaid says it is a card payment, or the text names the issuer and "payment". |
| Loan payment with no counterpart | Stays a bill. |
| Anything the person edited | Never overridden. |

The pairing is idempotent, deterministic (oldest first, closest in time), and can be re-run: `tools/repair_sync.py` re-applies it to history.

## What is NOT a rule
Categories are labels. They drive budgets and charts, not whether money counts.
