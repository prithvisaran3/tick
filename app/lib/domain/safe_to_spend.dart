import 'models.dart';
import 'payday.dart';
import 'dates.dart';

class SafeToSpend {
  const SafeToSpend({required this.cashCents, required this.billsCents, required this.goalsCents, required this.nextPayday, required this.daysToPayday,
      this.cardsDueCents = 0, this.loansDueCents = 0, this.cardsLaterCents = 0, this.periodStart, this.lines = const []});
  /// The pay period this covers: [periodStart] to the day before [nextPayday].
  final DateTime? periodStart;
  /// "How it's calculated", one line each, signed: they add up to [cents] exactly.
  final List<SafeLine> lines;
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

/// One line of the breakdown. [group]: cash, bill, card, loan or goal. [cents] is signed: cash adds, the rest subtract.
class SafeLine {
  const SafeLine(this.group, this.label, this.cents, {this.date});
  final String group;
  final String label;
  final int cents;
  final DateTime? date;
}

/// Pure function; unit-tested. [today] is the local calendar day.
SafeToSpend computeSafeToSpend({
  required DateTime today,
  required PaydayRule rule,
  required List<Account> accounts,
  required List<Recurring> recurring,
  required List<Goal> goals,
  List<Expected> expected = const [],
  PayPeriod? period,     // from SQL when there is one; the rule is the fallback
}) {
  final t = dayOnly(today);
  // If today is payday the money is arriving: plan to the *following* payday.
  final sql = period != null && !period.nextPayday.isBefore(t) && period.nextPayday != t;
  final payday = sql ? dayOnly(period.nextPayday) : payDates(rule, t).$2;
  final start = sql ? dayOnly(period.start) : payDates(rule, t).$1;
  final lines = <SafeLine>[];
  for (final a in accounts.where(countsAsCash)) {
    lines.add(SafeLine('cash', a.shortLabel, cashOf(a)));
  }
  for (final r in recurring) {
    for (final d in occurrencesBetween(r.cadence, r.nextDate, t, payday)) { lines.add(SafeLine('bill', r.merchant, -r.expectedCents, date: d)); }
  }
  final debts = debtLines(accounts: accounts, recurring: recurring, today: t, payday: payday);
  lines.addAll(debts.lines);
  for (final g in goals) {
    if (!g.paused && g.savedCents < g.targetCents && g.perPaydayCents > 0) lines.add(SafeLine('goal', g.name, -g.perPaydayCents));
  }
  int sum(String g) => lines.where((l) => l.group == g).fold<int>(0, (s, l) => s + l.cents);
  final cash = sum('cash'), bills = -sum('bill'), cardsDue = -sum('card'), loansDue = -sum('loan'), goalsPlanned = -sum('goal');
  final cardsLater = debts.cardsLater;
  return SafeToSpend(
    periodStart: start,
    lines: lines,
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

/// Counts in Cash: a checking (or hand-entered cash) account that's switched on. Savings never does.
bool countsAsCash(Account a) => a.includeInSafe && (a.type == 'checking' || a.type == 'cash');

/// What a cash account holds right now: available, or the current balance when the bank gives no available.
int cashOf(Account a) => a.availableCents ?? a.balanceCents ?? 0;

/// [debtsDueBy], one line per card and loan.
({List<SafeLine> lines, int cardsLater}) debtLines({required List<Account> accounts, required List<Recurring> recurring, required DateTime today, required DateTime payday}) {
  final lines = <SafeLine>[];
  var later = 0;
  for (final a in accounts.where((a) => a.isCard && a.includeInSafe)) {
    final one = debtsDueBy(accounts: [a], recurring: recurring, today: today, payday: payday);
    if (one.cardsDue > 0) lines.add(SafeLine('card', a.shortLabel, -one.cardsDue, date: a.dueDate));
    later += one.cardsLater;
  }
  for (final a in accounts.where((a) => a.isLoan)) {
    final one = debtsDueBy(accounts: [a], recurring: recurring, today: today, payday: payday);
    if (one.loansDue > 0) lines.add(SafeLine('loan', a.shortLabel, -one.loansDue, date: a.dueDate));
  }
  return (lines: lines, cardsLater: later);
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
