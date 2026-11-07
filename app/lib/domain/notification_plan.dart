import 'ideas.dart';
import 'models.dart';
import 'money.dart';
import 'payday.dart';
import 'safe_to_spend.dart';
import 'package:intl/intl.dart';
import 'dates.dart';

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
  List<Account> accounts = const [],
  bool utilisationAlerts = false,
  bool statementDay = false,
  int horizonDays = 7,
}) {
  final out = <PlannedNotification>[];
  final today = dayOnly(now);
  // Morning summary: 8:00 each day for the next [horizonDays] days.
  for (var i = 0; i < horizonDays; i++) {
    final day = addDays(today, i);
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
    final occ = occurrencesBetween(r.cadence, r.nextDate, addDays(today, 1), addDays(today, 15));
    for (final d in occ) {
      final when = _at(addDays(d, -1), '09:00');
      if (when.isAfter(now)) out.add(PlannedNotification(2000 + n++, 'Due tomorrow: ${r.merchant}', '${formatCents(r.expectedCents)} comes out tomorrow.', when, payload: 'incoming'));
    }
  }
  // Card due: one gentle reminder two days before, 9:00 (or the day before if that has passed). Never "pay now" buttons.
  var k = 0;
  for (final a in accounts.where((a) => a.isCard && a.dueDate != null && a.statementDueCents > 0)) {
    final due = dayOnly(a.dueDate!);
    if (due.isBefore(today) || daysBetween(today, due) > 15) continue;
    var when = _at(addDays(due, -2), '09:00');
    if (!when.isAfter(now)) when = _at(addDays(due, -1), '09:00');
    if (when.isAfter(now)) {
      out.add(PlannedNotification(5000 + k++, '${a.shortLabel} is due ${DateFormat('EEEE').format(due)}', '${formatDollars(a.statementDueCents)} statement balance. Pay it from checking to skip interest.', when, payload: 'card:${a.id}'));
    }
  }
  // Labs (statement cycle): a heads-up three days before a high-utilisation statement closes, 9:00.
  if (utilisationAlerts) {
    var u = 0;
    for (final a in accounts.where((a) => a.isCard)) {
      final cy = statementCycle(a, now);
      if (cy == null || cy.payForUnder30Cents <= 0) continue;
      final when = _at(addDays(cy.closes, -3), '09:00');
      if (when.isAfter(now)) {
        out.add(PlannedNotification(6000 + u++, '${a.shortLabel} closes ${DateFormat('EEEE').format(cy.closes)}',
            'Paying ${formatDollars(cy.payForUnder30Cents)} before then keeps the reported balance under 30%.', when, payload: 'card:${a.id}'));
      }
    }
  }
  // Statement day: Apple Card statements close on the 1st, so on the 2nd at 9:00 Tick offers the import ("Open in Tick" does the rest).
  if (statementDay) {
    for (var m = 0; m < 2; m++) {
      final when = _at(DateTime(today.year, today.month + m, 2), '09:00');
      if (when.isAfter(now) && when.difference(now).inDays <= 40) {
        out.add(PlannedNotification(7000 + m, 'Your Apple Card statement is ready', 'Export it from Wallet and share it to Tick. Three taps.', when, payload: 'import'));
        break;                                                                           // one at a time
      }
    }
  }
  // Payday plan on payday, 7:30.
  if (sts != null) {
    final when = _at(sts.nextPayday, '07:30');
    if (when.isAfter(now) && daysBetween(today, sts.nextPayday) <= 14) {
      final save = goals.fold<int>(0, (s, g) => s + g.perPaydayCents);
      out.add(PlannedNotification(3000, 'Payday', save > 0 ? 'Move ${formatDollars(save)} to savings and you still have ${formatDollars(sts.cents + sts.goalsCents - save)} safe.' : 'Payday. Open Tick to plan it.', when, payload: 'payday'));
    }
  }
  // Weekly review: Sunday, repeating.
  var sunday = today;
  while (sunday.weekday != DateTime.sunday) { sunday = addDays(sunday, 1); }
  var w = _at(sunday, weeklyTime);
  if (!w.isAfter(now)) w = addDays(w, 7);
  out.add(PlannedNotification(4000, 'Your week', 'Your weekly review is ready.', w, repeatWeekly: true));
  out.sort((a, b) => a.when.compareTo(b.when));
  return out;
}
