# Polish v3

Branch `feat/polish-v3`.

## Phase 1: payday schedule
Done. `pay_period(user, date)` in SQL (`20261114000001_pay_period.sql`) is the one definition: start, end, next payday, on `date` values in New York days.
Biweekly and weekly anchor on one date, twice a month takes two days and pays the business day before on a weekend or US bank holiday. The Payday editor shows the
current period and next three paydays live, in onboarding and Settings > Payday. `tools/set_payday.py` is a dry run unless `--apply`.

Decision: Python has no payday maths left (`api/app/pay.py` only calls SQL). Dart keeps one mirror, `domain/payday.dart`, because demo mode, offline and the live
preview can't wait for the server. Live Safe to spend reads SQL through `payPeriodProvider`; the mirror runs the same vectors as the SQL (`api/tests/data/pay_period.json`).
Monthly paydays don't shift for weekends: the brief asked for that on twice a month only.
