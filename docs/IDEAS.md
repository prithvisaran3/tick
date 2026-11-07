# Ideas

Ranked by how much each one sets Tick apart. Nothing here is built. The earlier long list, with what already shipped, is in `docs/IDEAS_ARCHIVE.md`.

| # | Idea | Effort |
|---|---|---|
| 1 | Paycheck autopilot plan | M |
| 2 | "Who owes me" from real bank rows | M |
| 3 | Subscription detective with a cancel list | M |
| 4 | Ask Tick what-if | S |
| 5 | Refund watch | M |
| 6 | Weekly recap card | S |
| 7 | Interest-cost meter | S |
| 8 | Shared trip mode | L |

## 1. Paycheck autopilot plan
- **Pitch:** when a paycheck lands, Tick shows one ordered list: this bill, that card, this much to savings, the rest is yours until next payday.
- **Why it matters:** most finance apps report the past. This tells you what to do with money the moment you have it, and it uses the moment people actually open the app.
- **Effort:** M. Payday plan, Landed and card due dates exist; the work is ordering and tick-off state.
- **Data:** payday rule, expected paycheck rows, recurring bills, card statements and due dates, goals.

## 2. "Who owes me" from real bank rows
- **Pitch:** Tick spots a restaurant charge followed by Zelle from a friend, and offers to turn it into a Tally split or mark it settled.
- **Why it matters:** no budgeting app and no split app sees both sides. Tick has the card row and the Zelle row, so friends' money stops distorting your spending.
- **Effort:** M. `looksLikeSettlement` and the settlement flow exist; the new part is suggestions on Activity.
- **Data:** transactions, P2P merchant text, Tally people and groups.

## 3. Subscription detective with a cancel list
- **Pitch:** every recurring charge in one list, sorted by what it costs per year, with price rises and "last used" hints, and a reminder before a free period ends.
- **Why it matters:** the fastest money a person can find, and the answer is visible in the first week of data.
- **Effort:** M. Needs recurrence detection on the server; Ask Tick's `find_subscriptions` is a start.
- **Data:** 6 to 12 months of transactions, recurring table, merchant names.

## 4. Ask Tick what-if
- **Pitch:** "If I buy a $900 flight, what happens to next month?" answers with the date you would run short, if any.
- **Why it matters:** turns Ask Tick from a lookup into advice, and it is a question no bank app answers.
- **Effort:** S. The What if pill already does the arithmetic; this exposes it as a tool.
- **Data:** Safe to spend inputs, upcoming bills, payday rule.

## 5. Refund watch
- **Pitch:** log a return in Wallet or from a purchase, and Tick watches for the money and nudges after 10 days if it never arrives.
- **Why it matters:** forgotten refunds are real lost money, and the Landed moment makes the good ending feel great.
- **Effort:** M. `expected` already has a refund kind and matching; needs an entry point and the nudge.
- **Data:** transactions, expected rows.

## 6. Weekly recap card
- **Pitch:** a shareable image on Sunday: spent, saved, biggest purchase, one honest sentence. Amounts can be hidden.
- **Why it matters:** gives the app a weekly habit and a brand moment. It is the one piece of Tick people would show someone.
- **Effort:** S. Weekly summary and the Morning Receipt art exist.
- **Data:** weekly totals from `tick_classified`.

## 7. Interest-cost meter
- **Pitch:** on each card: "carrying this balance costs about $4.10 a day", and how much a payment today saves.
- **Why it matters:** makes an abstract APR feel like a real bill and changes behaviour more than a utilisation bar.
- **Effort:** S. A small calculation on the card screen.
- **Data:** card balance, APR, statement balance, due date.

## 8. Shared trip mode
- **Pitch:** start a trip with friends; card purchases during those dates are offered to the group, and everyone settles with one link at the end.
- **Why it matters:** brings new people to Tick through the read-only link without needing them to sign up.
- **Effort:** L. Date-window suggestions, group lifecycle and a better public page.
- **Data:** Tally groups and share links, transactions, optionally location from Wallet capture.
