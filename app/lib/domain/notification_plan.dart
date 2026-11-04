import 'models.dart';
import 'money.dart';
import 'payday.dart';
import 'safe_to_spend.dart';
import 'package:intl/intl.dart';

class PlannedNotification {
  const PlannedNotification(this.id, this.title, this.body, this.when, {this.repeatWeekly = false, this.payload});
  final String? payload; // route to open on tap: 'payday' | 'incoming'
  final int id;
  final String title;
  final String body;
  final DateTime when; // local wall-clock
  final bool repeatWeekly;
}

DateTime _at(DateTime day, String hhmm) {
  final p = hhmm.split(':');
  return DateTime(day.year, day.month, day.day, int.parse(p[0]), int.parse(p[1]));
}

/// Everything Tick schedules on-device (no server push in v1). Pure; unit-tested. Max one nudge-style message a day except urgent.
List<PlannedNotification> planNotifications({
  required DateTime now,
  required String morningTime,
  required String weeklyTime,
  required SafeToSpend? sts,
  required List<Recurring> recurring,
  required List<Goal> goals,
  int horizonDays = 7,
}) {
  final out = <PlannedNotification>[];
  final today = dayOnly(now);
  // Morning summary: 8:00 each day for the next [horizonDays] days.
  for (var i = 0; i < horizonDays; i++) {
    final day = today.add(Duration(days: i));
    final when = _at(day, morningTime);
    if (!when.isAfter(now)) continue;
    final body = sts == null
        ? 'Open Tick to see what is safe to spend.'
        : sts.overspent
            ? 'You are ${formatDollars(-sts.cents)} past safe to spend until ${DateFormat('EEEE').format(sts.nextPayday)}.'
            : '${formatDollars(sts.cents)} safe to spend until ${DateFormat('EEEE').format(sts.nextPayday)}.';
    out.add(PlannedNotification(1000 + i, 'Good morning', body, when));
  }
  // Bill reminder: the day before, 9:00.
  var n = 0;
  for (final r in recurring) {
    final occ = occurrencesBetween(r.cadence, r.nextDate, today.add(const Duration(days: 1)), today.add(const Duration(days: 15)));
    for (final d in occ) {
      final when = _at(d.subtract(const Duration(days: 1)), '09:00');
      if (when.isAfter(now)) out.add(PlannedNotification(2000 + n++, 'Due tomorrow: ${r.merchant}', '${formatCents(r.expectedCents)} comes out tomorrow.', when, payload: 'incoming'));
    }
  }
  // Payday plan on payday, 7:30.
  if (sts != null) {
    final when = _at(sts.nextPayday, '07:30');
    if (when.isAfter(now) && sts.nextPayday.difference(today).inDays <= 14) {
      final save = goals.fold<int>(0, (s, g) => s + g.perPaydayCents);
      out.add(PlannedNotification(3000, 'Payday', save > 0 ? 'Move ${formatDollars(save)} to savings and you still have ${formatDollars(sts.cents + sts.goalsCents - save)} safe.' : 'Payday. Open Tick to plan it.', when, payload: 'payday'));
    }
  }
  // Weekly review: Sunday, repeating.
  var sunday = today;
  while (sunday.weekday != DateTime.sunday) { sunday = sunday.add(const Duration(days: 1)); }
  var w = _at(sunday, weeklyTime);
  if (!w.isAfter(now)) w = w.add(const Duration(days: 7));
  out.add(PlannedNotification(4000, 'Your week', 'Your weekly review is ready.', w, repeatWeekly: true));
  out.sort((a, b) => a.when.compareTo(b.when));
  return out;
}
