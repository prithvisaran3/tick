import 'models.dart';
import 'dates.dart';

DateTime dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

DateTime _addMonths(DateTime d, int n) {
  final total = d.year * 12 + (d.month - 1) + n;
  final y = total ~/ 12, m = total % 12 + 1;
  final last = DateTime(y, m + 1, 0).day;
  return DateTime(y, m, d.day > last ? last : d.day);
}

/// First payday on or after [from], given a rule anchored on any known payday.
DateTime nextPayday(PaydayRule r, DateTime from) {
  final f = dayOnly(from);
  final a = dayOnly(r.anchor);
  switch (r.frequency) {
    case PayFrequency.weekly:
    case PayFrequency.biweekly:
      final step = r.frequency == PayFrequency.weekly ? 7 : 14;
      var d = a;
      if (d.isBefore(f)) {
        final diff = daysBetween(d, f);
        d = addDays(d, ((diff + step - 1) ~/ step) * step);
      }
      return d;
    case PayFrequency.monthly:
      var d = a;
      var k = 0;
      while (d.isBefore(f)) {
        k++;
        d = _addMonths(a, k);
      }
      return d;
    case PayFrequency.semimonthly:
      // Two paydays a month: the anchor's day-of-month and the day 15 away (or the 15th/last).
      final d1 = a.day <= 15 ? a.day : a.day - 15 > 0 ? a.day - 15 : 1;
      final d2 = d1 + 15 > 28 ? 28 : d1 + 15;
      for (var m = 0; m < 3; m++) {
        final base = DateTime(f.year, f.month + m, 1);
        for (final day in [d1, d2]) {
          final last = DateTime(base.year, base.month + 1, 0).day;
          final c = DateTime(base.year, base.month, day > last ? last : day);
          if (!c.isBefore(f)) return c;
        }
      }
      return f;
  }
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
