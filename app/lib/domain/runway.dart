import 'bank_status.dart';
import 'dates.dart';
import 'models.dart';
import 'payday.dart';
import 'planned.dart';
import 'safe_to_spend.dart';
import 'tally.dart';

/// The first day checking would go below zero before payday, walking the money out in date order. Safe to spend says whether the period
/// adds up; this says whether the order of the days does, which is what an overdraft cares about.
class Shortfall {
  const Shortfall(this.day, this.label, this.cents, this.shortCents);
  final DateTime day;
  final String label;      // what comes out that day
  final int cents;         // how much it is
  final int shortCents;    // how far below zero checking would be
}

Shortfall? firstShortfall({required List<Account> accounts, required List<Recurring> recurring, required DateTime today, required DateTime payday, List<PlannedExpense> planned = const []}) {
  final t = dayOnly(today), pay = dayOnly(payday);
  var cash = accounts.where(countsAsCash).fold<int>(0, (s, a) => s + cashOf(a));
  if (accounts.where(countsAsCash).isEmpty) return null;
  final out = <(DateTime, String, int)>[];
  for (final r in recurring) {
    for (final d in occurrencesBetween(r.cadence, r.nextDate, t, pay)) {
      if (dayOnly(d).isBefore(pay)) out.add((dayOnly(d), r.merchant, r.expectedCents));
    }
  }
  for (final a in accounts.where((a) => a.isCard && a.includeInSafe && a.dueDate != null)) {
    final d = dayOnly(a.dueDate!);
    if (!d.isBefore(t) && d.isBefore(pay) && a.statementDueCents > 0) out.add((d, a.shortLabel, a.statementDueCents));
  }
  for (final p in planned.where((p) => p.open)) {
    final d = dayOnly(p.due);
    if (!d.isBefore(t) && d.isBefore(pay)) out.add((d, p.name, p.amountCents));
  }
  out.sort((a, b) => a.$1.compareTo(b.$1));
  for (final (d, label, cents) in out) {
    cash -= cents;
    if (cash < 0) return Shortfall(d, label, cents, -cash);
  }
  return null;
}

/// How old the Cash number is: the oldest last sync among the linked checking accounts that count. Null when it's fresh (under a day),
/// when every account is typed in by hand, or when a bank never synced (Banks says that already).
Duration? cashAge({required List<Account> accounts, required List<Connection> connections, required DateTime now}) {
  DateTime? oldest;
  for (final a in accounts.where((a) => countsAsCash(a) && !a.manual && a.connectionId != null)) {
    final at = connections.where((c) => c.id == a.connectionId).firstOrNull?.lastSyncedAt;
    if (at != null && (oldest == null || at.isBefore(oldest))) oldest = at;
  }
  if (oldest == null) return null;
  final age = now.difference(oldest);
  return age >= const Duration(hours: 24) ? age : null;
}

String cashAgeLine(Duration age, DateTime now) => 'Balances from ${ago(now.subtract(age), now)}';

/// Since when a Tally group's balance has been open: the first expense after the last confirmed settle-up. Null when square, or under two weeks.
DateTime? openSince({required int netCents, required List<TallyExpense> expenses, required List<TallySettlement> settlements, required DateTime today}) {
  if (netCents == 0 || expenses.isEmpty) return null;
  final settled = settlements.where((s) => s.status == 'confirmed').map((s) => dayOnly(s.on)).fold<DateTime?>(null, (m, d) => m == null || d.isAfter(m) ? d : m);
  final open = expenses.map((e) => dayOnly(e.spentOn)).where((d) => settled == null || d.isAfter(settled)).fold<DateTime?>(null, (m, d) => m == null || d.isBefore(m) ? d : m);
  if (open == null || daysBetween(open, dayOnly(today)) < 14) return null;
  return open;
}
