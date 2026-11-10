import 'models.dart';
import 'dates.dart';

DateTime dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

DateTime _addMonths(DateTime d, int n) {
  final total = d.year * 12 + (d.month - 1) + n;
  final y = total ~/ 12, m = total % 12 + 1;
  final last = DateTime(y, m + 1, 0).day;
  return DateTime(y, m, d.day > last ? last : d.day);
}

/// The pay period comes from SQL (`pay_period`). This mirror exists for what can't wait for the server: demo mode, offline, and the live preview
/// while a schedule is being edited. test/domain/payday_test.dart runs it on the same vectors as supabase/tests/pay_period.sql.
class PayPeriod {
  const PayPeriod({required this.start, required this.end, required this.nextPayday});
  final DateTime start;
  final DateTime end;
  final DateTime nextPayday;
}

DateTime _nth(int year, int month, int weekday, int n) {
  var d = DateTime(year, month, 1);
  while (d.weekday != weekday) { d = addDays(d, 1); }
  return addDays(d, 7 * (n - 1));
}

/// US bank holidays, as `is_bank_holiday` in SQL.
bool isBankHoliday(DateTime day) {
  final d = dayOnly(day);
  const fixed = {(1, 1), (6, 19), (7, 4), (11, 11), (12, 25)};
  final prev = addDays(d, -1);
  if (fixed.contains((d.month, d.day))) return true;
  if (d.weekday == DateTime.monday && fixed.contains((prev.month, prev.day))) return true;              // Sunday holiday, observed Monday
  final next = addDays(d, 1);
  if (d.weekday == DateTime.friday && fixed.contains((next.month, next.day))) return true;              // Saturday holiday, observed Friday
  final y = d.year;
  final memorial = () { var x = DateTime(y, 5, 31); while (x.weekday != DateTime.monday) { x = addDays(x, -1); } return x; }();
  return d == _nth(y, 1, DateTime.monday, 3) || d == _nth(y, 2, DateTime.monday, 3) || d == memorial || d == _nth(y, 9, DateTime.monday, 1) ||
      d == _nth(y, 10, DateTime.monday, 2) || d == _nth(y, 11, DateTime.thursday, 4);
}

DateTime businessDayBefore(DateTime day) {
  var d = dayOnly(day);
  while (d.weekday == DateTime.saturday || d.weekday == DateTime.sunday || isBankHoliday(d)) { d = addDays(d, -1); }
  return d;
}

/// The last payday on or before [on] and the first one after it.
(DateTime, DateTime) payDates(PaydayRule r, DateTime on) {
  final f = dayOnly(on), a = dayOnly(r.anchor);
  if (r.frequency == PayFrequency.weekly || r.frequency == PayFrequency.biweekly) {
    final step = r.frequency == PayFrequency.weekly ? 7 : 14;
    if (f.isBefore(addDays(a, -step))) return (addDays(a, -step), a);      // "my next payday is the 13th" stays true however far off it is
    final prev = addDays(a, (daysBetween(a, f) / step).floor() * step);
    return (prev, addDays(prev, step));
  }
  final days = r.frequency == PayFrequency.monthly ? [a.day] : (r.days ?? [a.day, a.day + 15 > 31 ? 31 : a.day + 15]);
  final c = <DateTime>[];
  for (var m = -2; m <= 2; m++) {
    final first = DateTime(f.year, f.month + m, 1);
    final last = DateTime(first.year, first.month + 1, 0).day;
    for (final x in days) {
      final d = DateTime(first.year, first.month, x > last ? last : x);
      c.add(r.frequency == PayFrequency.monthly ? d : businessDayBefore(d));
    }
  }
  c.sort();
  return (c.lastWhere((d) => !d.isAfter(f)), c.firstWhere((d) => d.isAfter(f)));
}

PayPeriod payPeriod(PaydayRule r, DateTime on) {
  final (prev, next) = payDates(r, on);
  return PayPeriod(start: prev, end: addDays(next, -1), nextPayday: next);
}

/// First payday on or after [from].
DateTime nextPayday(PaydayRule r, DateTime from) {
  final (prev, next) = payDates(r, from);
  return prev == dayOnly(from) ? prev : next;
}

/// What the editor shows before saving: the current period and the next three paydays.
({PayPeriod period, List<DateTime> next}) payPreview(PaydayRule r, DateTime today) {
  final t = dayOnly(today);
  final first = nextPayday(r, t);
  final out = [first];
  while (out.length < 3) { out.add(payDates(r, out.last).$2); }
  final (prev, _) = payDates(r, addDays(first, -1));
  return (period: PayPeriod(start: prev, end: addDays(first, -1), nextPayday: first), next: out);
}

/// Dates a cadence lands on within [start, end) given its next date.
List<DateTime> occurrencesBetween(Cadence c, DateTime next, DateTime start, DateTime end) {
  final out = <DateTime>[];
  var d = dayOnly(next);
  var k = 0;
  while (d.isBefore(end) && k < 400) {
    if (!d.isBefore(start)) out.add(d);
    k++;
    switch (c) {
      case Cadence.weekly: d = addDays(d, 7);
      case Cadence.biweekly: d = addDays(d, 14);
      case Cadence.monthly: d = _addMonths(dayOnly(next), k);
      case Cadence.yearly: d = _addMonths(dayOnly(next), 12 * k);
    }
  }
  return out;
}
