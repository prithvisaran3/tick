import 'models.dart';
import 'payday.dart';
import 'dates.dart';

class SafeToSpend {
  const SafeToSpend({required this.cashCents, required this.billsCents, required this.goalsCents, required this.nextPayday, required this.daysToPayday,
      this.cardsDueCents = 0, this.loansDueCents = 0, this.cardsLaterCents = 0});
  final int cashCents;
  final int billsCents;
  final int goalsCents;
  /// Card balances that must be paid before the next payday (statement balance still due, or what you owe if the due date is unknown).
  final int cardsDueCents;
  /// Loan payments due before the next payday.
  final int loansDueCents;
  /// Card balances that are NOT due before payday (not subtracted; shown so nothing feels hidden).
  final int cardsLaterCents;
  final DateTime nextPayday;
  final int daysToPayday;
  /// available cash - bills - cards due - loan payments due before payday - planned goal contributions
  int get cents => cashCents - billsCents - cardsDueCents - loansDueCents - goalsCents;
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
  if (payday == t) payday = nextPayday(rule, addDays(t, 1));
  final cash = accounts
      .where((a) => a.includeInSafe && a.isCash && a.type != 'savings')
      .fold<int>(0, (s, a) => s + (a.availableCents ?? a.balanceCents ?? 0));
  final (:cardsDue, :cardsLater, :loansDue) = debtsDueBy(accounts: accounts, recurring: recurring, today: t, payday: payday);
  var bills = 0;
  for (final r in recurring) {
    bills += r.expectedCents * occurrencesBetween(r.cadence, r.nextDate, t, payday).length;
  }
  final goalsPlanned = goals.fold<int>(0, (s, g) => s + (g.savedCents >= g.targetCents ? 0 : g.perPaydayCents));
  return SafeToSpend(
    cashCents: cash,
    billsCents: bills,
    goalsCents: goalsPlanned,
    cardsDueCents: cardsDue,
    loansDueCents: loansDue,
    cardsLaterCents: cardsLater,
    nextPayday: payday,
    daysToPayday: daysBetween(t, payday),
  );
}

/// Card and loan money that must leave before [payday]. Shared by Safe to spend and the Payday plan.
({int cardsDue, int cardsLater, int loansDue}) debtsDueBy({required List<Account> accounts, required List<Recurring> recurring, required DateTime today, required DateTime payday}) {
  final t = dayOnly(today);
  // Cards: what is due before payday comes out of safe to spend. Without a known due date, be conservative: all of it.
  var cardsDue = 0, cardsLater = 0;
  for (final a in accounts.where((a) => a.isCard && a.includeInSafe)) {
    if (a.dueDate == null) {
      cardsDue += a.owedCents;
    } else if (!dayOnly(a.dueDate!).isAfter(payday)) {                 // due before payday (or already past due)
      cardsDue += a.statementDueCents;
      cardsLater += a.owedCents - a.statementDueCents;
    } else {
      cardsLater += a.owedCents;
    }
  }
  // Loans: the next payment if it falls before payday, unless a recurring bill already covers it (no double count).
  var loansDue = 0;
  for (final a in accounts.where((a) => a.isLoan)) {
    final due = a.dueDate == null ? null : dayOnly(a.dueDate!);
    final amount = a.nextPaymentCents ?? a.minimumPaymentCents ?? 0;
    if (due == null || amount <= 0 || due.isBefore(t) || due.isAfter(payday)) continue;
    final brand = (a.institution ?? a.name).toLowerCase();
    final covered = recurring.any((r) => r.merchant.toLowerCase().contains(brand.split(' ').first) && (r.expectedCents - amount).abs() <= 500);
    if (!covered) loansDue += amount;
  }
  return (cardsDue: cardsDue, cardsLater: cardsLater, loansDue: loansDue);
}
