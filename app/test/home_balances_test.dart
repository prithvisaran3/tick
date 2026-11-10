import 'package:flutter_test/flutter_test.dart';
import 'package:tick/domain/balances.dart';
import 'package:tick/domain/models.dart';
import 'package:tick/domain/payday.dart';
import 'package:tick/domain/safe_to_spend.dart';

/// Shaped like the real accounts: four checking, one savings, cards and a loan.
final accts = [
  const Account(id: 'bofa', name: 'BofA', type: 'checking', subtype: 'checking', institution: 'Bank of America', mask: '1111', balanceCents: 96095, availableCents: 96095),
  const Account(id: 'cap', name: 'Cap', type: 'checking', subtype: 'checking', institution: 'Capital One', mask: '2222', balanceCents: 1345),
  const Account(id: 'chase', name: 'Chase', type: 'checking', subtype: 'checking', institution: 'Chase', mask: '3333', balanceCents: 60000, availableCents: 55797),
  const Account(id: 'sofi', name: 'SoFi', type: 'checking', subtype: 'checking', institution: 'SoFi', mask: '4444', balanceCents: 1408, availableCents: 1408),
  const Account(id: 'sav', name: 'SoFi Savings', type: 'savings', subtype: 'savings', institution: 'SoFi', mask: '5555', balanceCents: 29061, availableCents: 29061, includeInSafe: false),
  Account(id: 'card', name: 'BofA card', type: 'credit', institution: 'Bank of America', mask: '6666', balanceCents: -34367, statementBalanceCents: 20000, dueDate: DateTime(2026, 11, 20)),
  const Account(id: 'loan', name: 'SoFi loan', type: 'loan', institution: 'SoFi', balanceCents: -3761151, includeInSafe: false),
];

void main() {
  test('Cash is checking only: savings, cards and loans never in it; available wins over current', () {
    final b = homeBalances(accts);
    expect(b.cash.map((x) => x.$1.id), ['bofa', 'cap', 'chase', 'sofi']);
    expect(b.cashCents, 96095 + 1345 + 55797 + 1408);
    expect(b.savingsCents, 29061);
    expect(b.cashCents + b.savingsCents - (60000 - 55797), 183706 - 4203);
    expect((b.cardsOwedCents, b.nextCard?.id), (34367, 'card'));
  });

  test('a checking account switched off leaves Cash and says so', () {
    final b = homeBalances([...accts.where((a) => a.id != 'cap'), const Account(id: 'cap', name: 'Cap', type: 'checking', balanceCents: 1345, includeInSafe: false)]);
    expect((b.cashCents, b.excludedCount), (96095 + 55797 + 1408, 1));
  });

  test('the breakdown adds up to Safe to spend exactly, scoped to the pay period', () {
    final rule = PaydayRule(frequency: PayFrequency.biweekly, anchor: DateTime(2026, 11, 13), amountCents: 0);
    final s = computeSafeToSpend(today: DateTime(2026, 11, 6), rule: rule, accounts: accts,
        recurring: [Recurring(id: 'r', merchant: 'Internet', cadence: Cadence.monthly, expectedCents: 6400, nextDate: DateTime(2026, 11, 10)), Recurring(id: 's', merchant: 'Later', cadence: Cadence.monthly, expectedCents: 999, nextDate: DateTime(2026, 11, 20))],
        goals: const [Goal(id: 'g', name: 'Trip', targetCents: 100000, savedCents: 0, perPaydayCents: 5000)]);
    expect(s.lines.fold<int>(0, (a, l) => a + l.cents), s.cents);
    expect(s.cashCents, homeBalances(accts).cashCents);
    expect(s.lines.where((l) => l.group == 'bill').map((l) => l.label), ['Internet']);
    expect((s.periodStart, s.nextPayday), (DateTime(2026, 10, 30), DateTime(2026, 11, 13)));
  });

  test('pay period edges: the day before payday and payday itself', () {
    final rule = PaydayRule(frequency: PayFrequency.biweekly, anchor: DateTime(2026, 11, 13), amountCents: 0);
    expect(payPeriod(rule, DateTime(2026, 11, 12)).end, DateTime(2026, 11, 12));
    expect(payPeriod(rule, DateTime(2026, 11, 13)).start, DateTime(2026, 11, 13));
    final period = PayPeriod(start: DateTime(2026, 10, 30), end: DateTime(2026, 11, 12), nextPayday: DateTime(2026, 11, 13));
    final s = computeSafeToSpend(today: DateTime(2026, 11, 6), rule: rule, accounts: accts, recurring: const [], goals: const [], period: period);
    expect((s.periodStart, s.daysToPayday), (DateTime(2026, 10, 30), 7));
  });
}
