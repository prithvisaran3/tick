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
