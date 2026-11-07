# Ideas

Written for one user: a software engineer (until recently a grad student) who spends mostly on credit cards, pays them from
checking, sends Zelle to friends, gets paid on a fixed schedule, has a SoFi student loan and wants Splitwise-style splits
later. The rule behind every idea: **Tick suggests, it never moves money.**

Ranking is impact first, then effort. Impact is how often it saves time or money, or gives a reason to open the app.
Effort: S is under a day, M is 1–3 days, L is a week or more.

**Shipped in this PR** (Settings > Labs, each on by default and switchable): 1, 2, 3 and 4.

| # | Idea | Impact | Effort | Status |
|---|---|---|---|---|
| 1 | Card-due guard | High | S | **Shipped** (`card_guard`) |
| 2 | Truly free to spend | High | S | **Shipped** (`truly_free`) |
| 3 | Statement cycle per card, plus a utilisation heads-up | High | S | **Shipped** (`statement_cycle`) |
| 4 | What if (try an amount before you buy) | High | S | **Shipped** (`what_if`) |
| 5 | Subscription detective | High | M | Ticket |
| 6 | Zelle ledger by person (ready for splits) | High | M | Ticket |
| 7 | Duplicate charge and fee detector | High | M | Ticket |
| 8 | Weekly money recap you can share as an image | Med | M | Ticket |
| 9 | What if, inside Ask Tick | Med | M | Ticket |
| 10 | Student loan payoff simulator | Med | M | Ticket |
| 11 | Suggest-only "sweep to savings" nudges | Med | S | Ticket |
| 12 | Card rewards picker ("which card for this?") | Med | M | Ticket |
| 13 | Lock Screen widgets, Live Activity, Action Button logging | Med | L | Ticket |
| 14 | Splits (Splitwise-style), built on 6 | High | L | Ticket |
| 15 | Refund tracker | Med | S | Ticket |
| 16 | Interest-cost meter | Med | S | Ticket |
| 17 | Payday autopilot checklist | Med | S | Ticket |
| 18 | Price-hike radar across all recurring charges | Med | S | Ticket (folds into 5) |
| 19 | Night-before receipt for tomorrow's bills | Low | S | Ticket |

---

## 1. Card-due guard (shipped)
**Why:** You spend on cards and pay them from checking. The real risk isn't overspending, it's checking being short on
the day a card is due.
**What it does:** Today shows "Cards before payday", with the card statements, loan payment and bills due before the
next payday, and whether checking covers them. When checking is short, the title turns Clay and says by how much.
Tapping it opens the earliest card due. Pure function `cardGuard()` in `app/lib/domain/ideas.dart`.
**Next:** a notification the morning a shortfall first appears, and a "move from SoFi savings" suggestion with the exact
amount. Suggest only, no transfer.

## 2. Truly free to spend (shipped)
**Why:** Safe to spend only subtracts the card money due before payday. If you'd sleep better knowing what's left after
every balance, this answers that.
**What it does:** One line under the pills: "$X truly free after every card balance", or "$X short if every card
balance were paid today". `trulyFree()` = safe to spend minus the card balances that aren't due yet.

## 3. Statement cycle and utilisation heads-up (shipped)
**Why:** The balance on the statement closing date is what bureaus see. Paying before the close (not the due date)
keeps utilisation under 30% without paying any earlier in total.
**What it does:** The card screen shows when the next statement closes (from the last statement date Plaid
Liabilities reports), how much to pay and by when to report under 30%, and the pay-in-full countdown to the due date.
A notification goes out 3 days before a high-utilisation close. `statementCycle()` and `utilisationHeadsUp()`.
**Limits:** needs Liabilities (Discover, BofA, Capital One support it). Apple Card has no statement date, so the section
stays hidden there.

## 4. What if (shipped)
**Why:** "Can I buy this?" is the question you have at a store. Opening the app should answer it in two taps.
**What it does:** A "What if…" pill on Today opens the amount pad. The answer is what's left until payday, or how far
past safe to spend it would put you. It plays the price-weight haptic, which already means "an amount landing".
Nothing is saved.

## 5. Subscription detective
**Why:** Recurring card charges creep up, and free trials quietly convert.
**Plan:** The server already detects recurring charges (`intel.detect_recurring`) and keeps `price_history`.
1. A nightly job flags new recurring charges, price increases of 5% or more, and charges whose merchant hasn't been seen
   in 60 days or more but is still billing.
2. Today shows one nudge at a time, for example "Spotify went from $10.99 to $11.99".
3. A Subscriptions screen lists every recurring charge with its monthly and yearly cost, plus a "Remind me to cancel"
   button that schedules a local notification 2 days before the next charge.
**Tests:** detection fixtures for price hikes, annual plans and trials.

## 6. Zelle ledger by person
**Why:** Zelle to and from friends is noise in spending today (it's categorised Transfer). It's really "who owes whom".
**Plan:**
1. Parse the counterparty from Zelle descriptions ("Zelle payment to Sam K", "Zelle from SAM K").
2. Add a `people` link (the table already exists) with fuzzy name matching and a manual merge.
3. A Person screen shows the running balance, history and an "expected" IOU (the `expected` table already supports `iou`).
4. The Landed moment plays when a friend pays you back.
**Risk:** names in bank descriptions are truncated. Ask once to confirm a new person.

## 7. Duplicate charge and fee detector
**Why:** Double charges, foreign transaction fees and late fees are real money and easy to miss.
**Plan:** server-side rules over the last 7 days:
- the same merchant and amount twice within 48 hours on the same card;
- any "Fees and interest" row (the category ships in this PR);
- a fee on a card that has no foreign-fee waiver.

Each finding is a Caught card ("Two $42.18 at Whole Foods on Discover"), with "Looks right" or "Dispute in the bank
app" as the answers. Reuses the Caught swipe language.

## 8. Weekly money recap as an image
**Why:** A reason to open the app on Sunday, and a way to share a win.
**Plan:** Render the weekly review as a Receipt-style image (the receipt paper and the tear haptic already exist):
spent, top three categories, card bills paid, and safe to spend for the week ahead. `share_plus` is already a
dependency. Amounts can be hidden when sharing (reuse the hide-amounts setting).

## 9. What if, inside Ask Tick
**Why:** Natural questions like "if I buy a $1,200 laptop on Savor, what's left on payday, and what's my utilisation?"
**Plan:** Add a read-only `what_if(amount, card?)` tool to Ask Tick (`api/app/ask.py`). It computes the same thing as
idea 4 on the server, plus utilisation for the named card. It stays read-only like every Ask tool.

## 10. Student loan payoff simulator
**Why:** Seeing "pay $100 more a month and finish 14 months sooner, saving $1,820 in interest" changes behaviour.
**Plan:** On the Loans card: rate and balance from Liabilities, and a slider for the extra monthly amount. A pure
amortisation function with tests against a known schedule.

## 11. Suggest-only "sweep to savings"
**Why:** After payday, checking often holds more than the cards and bills need.
**Plan:** On payday plus one day: "Checking has $X more than what's due before the next payday. Move $Y to SoFi
savings?" The button opens the SoFi app (URL scheme), never a transfer. Builds on the card-due guard maths.

## 12. Card rewards picker
**Why:** Savor earns more on dining and groceries, Discover rotates categories. You may be leaving cash back on the table.
**Plan:** A small static table of reward rules per card (editable), and a "best card for Restaurants" hint on the
what-if sheet and the quick-add sheet. A monthly "you'd have earned $X more" line.

## 13. Lock Screen widgets, Live Activity, Action Button
**Why:** Safe to spend at a glance, and logging cash in one press.
**Plan:** The widget code exists, but it's gated behind App Groups (`--dart-define=TICK_WIDGETS=true`), which need a
paid developer account. With a paid account:
1. Add a Lock Screen accessory widget showing safe to spend.
2. Add a Live Activity on payday.
3. Wire the App Intent (already present) to the Action Button.

**Blocker:** a free Apple account can't use App Groups.

## 14. Splits (Splitwise-style)
**Why:** You asked for it later. It's the natural next step after 6.
**Plan:** The `transactions.splits` and `participants` columns exist. Build "Split this" on a transaction (equal,
amounts or shares), people from idea 6, balances per person, and settle up by matching Zelle (idea 6). The heartbeat
haptic is already reserved for settle-ups.

## 15. Refund tracker
**Why:** Returns you're waiting on are money you're owed.
**Plan:** When you mark a purchase "returning", create an `expected` refund. Match it when the card refund arrives (the
`refund` tag ships in this PR). Nudge after 14 days without one.

## 16. Interest-cost meter
**Why:** A card that carries a balance at 28.99% costs real money every day.
**Plan:** On a card with a balance after the due date: "Carrying $1,923 costs about $1.53 a day." Uses the APR from
Liabilities (shipped). A pure function with tests.

## 17. Payday autopilot checklist
**Why:** Payday is when the decisions happen.
**Plan:** Extend the Payday plan screen with a checklist: pay each card due before the next payday (from the card-due
guard), the loan payment, then the savings goals. Every item links out to the bank's app. Tick ticks items off when
the matching transfers arrive (the transfer pairing from this PR).

## 18. Price-hike radar
Folds into 5. Watch every recurring charge's `price_history` for increases, and send one calm nudge per change.

## 19. Night-before receipt for tomorrow's bills
**Why:** A 9 pm heads-up such as "Tomorrow: Internet $64, Discover $640 due".
**Plan:** Reuse the notification planner. It only fires when something is due tomorrow, and it respects the
one-nudge-a-day rule.
