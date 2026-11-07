# Polish v3

Branch `feat/polish-v3`.

## Phase 1: payday schedule
Done. `pay_period(user, date)` in SQL (`20261114000001_pay_period.sql`) is the one definition: start, end, next payday, on `date` values in New York days.
Biweekly and weekly anchor on one date, twice a month takes two days and pays the business day before on a weekend or US bank holiday. The Payday editor shows the
current period and next three paydays live, in onboarding and Settings > Payday. `tools/set_payday.py` is a dry run unless `--apply`.

Decision: Python has no payday maths left (`api/app/pay.py` only calls SQL). Dart keeps one mirror, `domain/payday.dart`, because demo mode, offline and the live
preview can't wait for the server. Live Safe to spend reads SQL through `payPeriodProvider`; the mirror runs the same vectors as the SQL (`api/tests/data/pay_period.json`).
Monthly paydays don't shift for weekends: the brief asked for that on twice a month only.

## Phase 2: person-aware categories
Done. `category_rules` (`20261115000001_category_rules.sql`): person with aliases, amount band, day window with month-end wrap, memo keywords, priority. `tick_apply_category_rules` runs
after pairing on each sync and import, and whenever a rule changes; a row categorised by hand never moves. Activity asks "Looks like rent or a bill to Kaarthik" (Rent / Other bill / Not
recurring). Moving a row to Rent offers "Always for Kaarthik around $X?".

Decisions
- Rules write the row's category (`category_rule_id` remembers which rule), so every screen shows it without another join.
- A manual category on a Zelle row no longer learns a blanket merchant rule, which would have turned every payment to that person into rent.
- "Other bill" uses the Other category. Aliases match exactly, so Kaarthik Kumar can't fall into Kaarthik Roshan's rule.
- `tools/seed_rent_rule.py` is the seed. It needs the migration live, so it runs at deploy.

## Phase 3: Ask Tick
Done. `api/app/ask_brain.py`: `parse_range` makes every date, typed tools compute every number from `ask_rows` (the SQL money rules plus the person), and templates write every sentence.
The router only picks a tool: rules, then the learned matcher, then this phone's model, then a free OpenRouter model. `ask_log` and `ask_memory` hold what it learned; Settings > Ask Tick shows the
share answered without a model, 👍 rate, a cloud toggle and Clear. A nightly job rebuilds the matcher index and promotes a shape with three 👍 and one tool to an exact rule.
Eval: `python3 api/tests/ask_eval.py`, 50 questions plus paraphrases. Rules 50/50, learned 2/2.

Decisions
- Templates phrase every path, including cloud. The model never writes a sentence, so it can't restate a number wrongly, and bank text never reaches it, which closes prompt injection through merchant names.
- Tools sum classified rows in Python rather than a SQL function per tool: the rows and every rule about them come from SQL; the sum is plain code that's the same for every path.
- `safe_to_spend` here is cash minus bills, card statements due and goals before payday. It has no loan step, so it can differ slightly from Today, which also subtracts loan payments.
- Cloud few-shot sends the shape of the three closest 👍 questions, scrubbed, and only with the toggle on. Everything else in `ask_log` stays put.
- A correction for the category or person needs the word it was about; the sheet asks for the reason only, so aliases from the app come from the period picker for now. The API takes `term` + `category`/`person`.

On-device model: `ios/Runner/TickAskModel.swift` uses Foundation Models guided generation, behind an availability check. It compiles against the iOS 27.2 SDK with no entitlement, so a Personal Team should
be fine. Whether Apple Intelligence is on for this phone can only be seen on the phone: when it's off, the step is skipped.

## Phase 4: Splitwise category
Source B is live; Source A's parsing and matching are built, the Gmail connection isn't.
- "Splitwise" is a system category that behaves like Friends and family under the toggle. `transactions.shared_cents` makes a matched card charge count only my share.
- Source B: Activity asks "Likely Splitwise" for money with Tally friends and shared-looking charges that got paid back. Yes makes a low-priority rule, so rent rules still win, and teaches Ask Tick the name.
- Source A: `api/app/splitwise_mail.py` parses emails into `splitwise_events` (parsed fields and the Gmail id, never the body) and matches them. **The email format is assumed**; the fixtures are written from memory.

Why Gmail isn't connected: it needs a change in Google Cloud Console that only you can make, and the fetch route shouldn't be built blind against an unseen email format. Setup, when you want it:
1. console.cloud.google.com, pick the project that holds the Tick web client.
2. APIs & Services > Library > Gmail API > Enable.
3. Google Auth Platform > Data Access > Add or remove scopes > tick `.../auth/gmail.readonly` > Save.
4. Audience: leave Publishing status on Testing, Add users, add your Gmail address.
5. Clients > your web client > Authorized redirect URIs > add `https://tick-api-production.up.railway.app/splitwise/gmail/callback`.
6. Forward one "added an expense" and one "settled up" email's text to me, so the parser is checked against the real thing. Testing-mode refresh tokens expire after 7 days, so a reconnect prompt is needed.
