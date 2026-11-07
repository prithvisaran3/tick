import 'models.dart';
import 'money.dart';
import 'payday.dart';
import 'safe_to_spend.dart';
import 'dates.dart';

/// Shipped ideas from docs/IDEAS.md. Pure functions; unit-tested in test/domain/ideas_test.dart.
/// Tick only ever SUGGESTS: none of these move money.

// ---------- 1. Card-due guard ----------
class CardGuard {
  const CardGuard({required this.checkingCents, required this.dueCents, required this.firstDue, required this.cardsDue});
  final int checkingCents; // cash in checking (what pays the cards)
  final int dueCents; // card statements + loan payments + bills due before payday
  final Account? firstDue; // the earliest card due
  final int cardsDue;
  int get shortCents => dueCents - checkingCents;
  bool get short => shortCents > 0;
}

/// Can checking cover what's due before payday (card statements, loan payment, bills)? Null when no card is due before payday.
CardGuard? cardGuard(SafeToSpend? sts, List<Account> accounts, DateTime today) {
  if (sts == null || sts.cardsDueCents <= 0) return null;
  final due = accounts.where((a) => a.isCard && a.dueDate != null && a.statementDueCents > 0 && !dayOnly(a.dueDate!).isAfter(sts.nextPayday)).toList()
    ..sort((a, b) => a.dueDate!.compareTo(b.dueDate!));
  return CardGuard(checkingCents: sts.cashCents, dueCents: sts.cardsDueCents + sts.loansDueCents + sts.billsCents, firstDue: due.firstOrNull, cardsDue: sts.cardsDueCents);
}

String cardGuardLine(CardGuard g, DateTime now) => g.short
    ? 'Checking is ${formatDollars(g.shortCents)} short of the cards and bills due before payday.'
    : 'Checking covers the ${formatDollars(g.dueCents)} of cards and bills due before payday.';

// ---------- 2. Truly free ----------
/// Safe to spend if EVERY card balance were paid today (not just what's due before payday), after bills, loan and goals.
int trulyFree(SafeToSpend sts) => sts.cents - sts.cardsLaterCents;

// ---------- 3. Statement cycle ----------
class Cycle {
  const Cycle({required this.closes, required this.daysToClose, required this.payForUnder30Cents, this.dueDays, required this.statementDueCents});
  final DateTime closes; // estimated next statement closing date
  final int daysToClose;
  /// Pay this much before the statement closes so the reported balance is under 30% of the limit (0 = already under).
  final int payForUnder30Cents;
  final int? dueDays; // days until the current statement is due (null if unknown)
  final int statementDueCents;
  /// Best day to pay for utilisation: two days before the close (payments take a day or two to post).
  DateTime get bestPayDay => addDays(closes, -2);
}

DateTime _addMonth(DateTime d) {
  final last = DateTime(d.year, d.month + 2, 0).day;
  return DateTime(d.year, d.month + 1, d.day > last ? last : d.day);
}

/// Next closing date = last statement date + whole months until it is today or later. Null without a statement date.
Cycle? statementCycle(Account a, DateTime now) {
  if (!a.isCard || a.lastStatementDate == null) return null;
  final today = dayOnly(now);
  var close = dayOnly(a.lastStatementDate!);
  var guard = 0;
  while (close.isBefore(today) && guard++ < 24) { close = _addMonth(close); }
  final limit = a.creditLimitCents;
  final target = limit == null ? null : (limit * 0.29).floor();   // a hair under 30% so rounding never reports 30%
  final pay = target == null ? 0 : (a.owedCents - target).clamp(0, a.owedCents);
  return Cycle(closes: close, daysToClose: daysBetween(today, close), payForUnder30Cents: pay,
      dueDays: a.dueDate == null ? null : daysBetween(today, dayOnly(a.dueDate!)), statementDueCents: a.statementDueCents);
}

/// The heads-up a few days before a statement closes with high utilisation. Null when nothing to say.
String? utilisationHeadsUp(Account a, DateTime now) {
  final c = statementCycle(a, now);
  if (c == null || c.payForUnder30Cents <= 0 || c.daysToClose > 4) return null;
  return '${a.shortLabel} closes in ${c.daysToClose == 0 ? 'under a day' : '${c.daysToClose} ${c.daysToClose == 1 ? 'day' : 'days'}'}. '
      'Paying ${formatDollars(c.payForUnder30Cents)} before then keeps it under 30%.';
}

// ---------- 4. What if ----------
class WhatIf {
  const WhatIf(this.afterCents, this.payday);
  final int afterCents;
  final DateTime payday;
  bool get over => afterCents < 0;
}

WhatIf whatIf(SafeToSpend sts, int spendCents) => WhatIf(sts.cents - spendCents.abs(), sts.nextPayday);

String trulyFreeLine(SafeToSpend sts) {
  final v = trulyFree(sts);
  return v >= 0 ? '${formatDollars(v)} truly free after every card balance' : '${formatDollars(-v)} short if every card balance were paid today';
}
