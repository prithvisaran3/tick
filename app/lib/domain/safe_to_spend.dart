import 'models.dart';
import 'payday.dart';

class SafeToSpend {
  const SafeToSpend({required this.cashCents, required this.billsCents, required this.goalsCents, required this.nextPayday, required this.daysToPayday});
  final int cashCents;
  final int billsCents;
  final int goalsCents;
  final DateTime nextPayday;
  final int daysToPayday;
  /// available cash - bills due before payday - planned goal contributions
  int get cents => cashCents - billsCents - goalsCents;
  bool get overspent => cents < 0;
}

/// Pure function; unit-tested. [today] is the local calendar day.
SafeToSpend computeSafeToSpend({
  required DateTime today,
  required PaydayRule rule,
  required List<Account> accounts,
  required List<Recurring> recurring,
  required List<Goal> goals,
  List<Expected> expected = const [],
}) {
  final t = dayOnly(today);
  // If today is payday the money is arriving: plan to the *following* payday.
  var payday = nextPayday(rule, t);
  if (payday == t) payday = nextPayday(rule, t.add(const Duration(days: 1)));
  final cash = accounts
      .where((a) => a.includeInSafe && a.type != 'credit' && a.type != 'savings')
      .fold<int>(0, (s, a) => s + (a.availableCents ?? a.balanceCents ?? 0));
  // Credit card balances owed count against cash.
  final owed = accounts.where((a) => a.includeInSafe && a.type == 'credit').fold<int>(0, (s, a) => s + (a.balanceCents ?? 0).abs());
  var bills = 0;
  for (final r in recurring) {
    bills += r.expectedCents * occurrencesBetween(r.cadence, r.nextDate, t, payday).length;
  }
  final goalsPlanned = goals.fold<int>(0, (s, g) => s + (g.savedCents >= g.targetCents ? 0 : g.perPaydayCents));
  return SafeToSpend(
    cashCents: cash - owed,
    billsCents: bills,
    goalsCents: goalsPlanned,
    nextPayday: payday,
    daysToPayday: payday.difference(t).inDays,
  );
}
