import 'package:flutter_test/flutter_test.dart';
import 'package:tick/domain/models.dart';
import 'package:tick/domain/money.dart';
import 'package:tick/domain/natural_input.dart';
import 'package:tick/domain/payday.dart';
import 'package:tick/domain/safe_to_spend.dart';

void main() {
  group('money', () {
    test('format', () {
      expect(formatCents(-1840), '−\$18.40');
      expect(formatCents(231000, sign: true), '+\$2,310.00');
      expect(formatDollars(21499), '\$214');
      expect(formatCents(0), '\$0.00');
      expect(formatCents(123456789), '\$1,234,567.89');
    });
    test('parse', () {
      expect(parseCents('18'), 1800);
      expect(parseCents('\$1,850.5'), 185050);
      expect(parseCents('4.05'), 405);
      expect(parseCents('abc'), isNull);
    });
  });

  group('payday', () {
    final biweekly = PaydayRule(frequency: PayFrequency.biweekly, anchor: DateTime(2026, 10, 23), amountCents: 231000);
    test('biweekly next', () {
      expect(nextPayday(biweekly, DateTime(2026, 11, 4)), DateTime(2026, 11, 6));
      expect(nextPayday(biweekly, DateTime(2026, 11, 6)), DateTime(2026, 11, 6));
      expect(nextPayday(biweekly, DateTime(2026, 11, 7)), DateTime(2026, 11, 20));
    });
    test('anchor in the future still works', () {
      final r = PaydayRule(frequency: PayFrequency.weekly, anchor: DateTime(2026, 11, 13), amountCents: 1);
      expect(nextPayday(r, DateTime(2026, 11, 4)), DateTime(2026, 11, 13));
    });
    test('monthly clamps to month end', () {
      final r = PaydayRule(frequency: PayFrequency.monthly, anchor: DateTime(2026, 1, 31), amountCents: 1);
      expect(nextPayday(r, DateTime(2026, 2, 1)), DateTime(2026, 2, 28));
    });
    test('semimonthly', () {
      final r = PaydayRule(frequency: PayFrequency.semimonthly, anchor: DateTime(2026, 10, 1), amountCents: 1);
      expect(nextPayday(r, DateTime(2026, 11, 2)), DateTime(2026, 11, 16));
    });
    test('occurrences', () {
      final o = occurrencesBetween(Cadence.weekly, DateTime(2026, 11, 5), DateTime(2026, 11, 4), DateTime(2026, 11, 20));
      expect(o.length, 3);
      expect(occurrencesBetween(Cadence.monthly, DateTime(2026, 11, 9), DateTime(2026, 11, 4), DateTime(2026, 11, 6)), isEmpty);
    });
  });

  group('safe to spend', () {
    final rule = PaydayRule(frequency: PayFrequency.biweekly, anchor: DateTime(2026, 10, 23), amountCents: 231000);
    final checking = const Account(id: 'a', name: 'Checking', type: 'checking', availableCents: 300000);
    test('cash - bills before payday - goals', () {
      final r = computeSafeToSpend(
        today: DateTime(2026, 11, 4), rule: rule, accounts: [checking],
        recurring: [
          Recurring(id: '1', merchant: 'Internet', cadence: Cadence.monthly, expectedCents: 6400, nextDate: DateTime(2026, 11, 5)),
          Recurring(id: '2', merchant: 'Rent', cadence: Cadence.monthly, expectedCents: 185000, nextDate: DateTime(2026, 11, 9)), // after payday
        ],
        goals: [const Goal(id: 'g', name: 'Savings', targetCents: 1000000, savedCents: 0, perPaydayCents: 40000)],
      );
      expect(r.billsCents, 6400);
      expect(r.cents, 300000 - 6400 - 40000);
      expect(r.nextPayday, DateTime(2026, 11, 6));
      expect(r.daysToPayday, 2);
    });
    test('payday today plans to the next one', () {
      final r = computeSafeToSpend(today: DateTime(2026, 11, 6), rule: rule, accounts: [checking], recurring: const [], goals: const []);
      expect(r.nextPayday, DateTime(2026, 11, 20));
    });
    test('credit owed reduces cash; savings excluded; full goals skipped; negative allowed', () {
      final r = computeSafeToSpend(
        today: DateTime(2026, 11, 4), rule: rule,
        accounts: [checking, const Account(id: 'c', name: 'Card', type: 'credit', balanceCents: -50000), const Account(id: 's', name: 'Save', type: 'savings', availableCents: 900000)],
        recurring: const [], goals: [const Goal(id: 'g', name: 'Done', targetCents: 100, savedCents: 100, perPaydayCents: 5000)]);
      expect(r.cents, 250000);
      final neg = computeSafeToSpend(today: DateTime(2026, 11, 4), rule: rule, accounts: [const Account(id: 'a', name: 'C', availableCents: 1000)], recurring: [Recurring(id: '1', merchant: 'X', cadence: Cadence.weekly, expectedCents: 5000, nextDate: DateTime(2026, 11, 5))], goals: const []);
      expect(neg.overspent, isTrue);
    });
  });

  group('safe to spend with cards and loans', () {
    final rule = PaydayRule(frequency: PayFrequency.biweekly, anchor: DateTime(2026, 11, 6), amountCents: 231000);  // next payday Nov 20
    const checking = Account(id: 'a', name: 'Checking', type: 'checking', availableCents: 300000);
    final today = DateTime(2026, 11, 10);
    SafeToSpend run(List<Account> accts, {List<Recurring> rec = const []}) =>
        computeSafeToSpend(today: today, rule: rule, accounts: [checking, ...accts], recurring: rec, goals: const []);

    test('a card due before payday subtracts its statement balance; the rest of the balance is not due yet', () {
      final r = run([Account(id: 'd', name: 'Discover it', type: 'credit', balanceCents: -81240, statementBalanceCents: 64012, dueDate: DateTime(2026, 11, 14))]);
      expect((r.cardsDueCents, r.cardsLaterCents), (64012, 81240 - 64012));
      expect(r.cents, 300000 - 64012);
    });
    test('a card due after payday is not subtracted', () {
      final r = run([Account(id: 'b', name: 'BofA', type: 'credit', balanceCents: -23410, statementBalanceCents: 18800, dueDate: DateTime(2026, 11, 29))]);
      expect((r.cardsDueCents, r.cents), (0, 300000));
    });
    test('a payment made after the statement lowers what is still due', () {
      final r = run([Account(id: 'c', name: 'Savor', type: 'credit', balanceCents: -50000, statementBalanceCents: 40000, dueDate: DateTime(2026, 11, 15),
          lastStatementDate: DateTime(2026, 10, 20), lastPaymentCents: 30000, lastPaymentDate: DateTime(2026, 11, 2))]);
      expect(r.cardsDueCents, 10000);
    });
    test('unknown due date: the whole balance counts (conservative); a past-due card counts too', () {
      expect(run([const Account(id: 'x', name: 'Apple Card', type: 'credit', balanceCents: -31840)]).cardsDueCents, 31840);
      expect(run([Account(id: 'y', name: 'Late', type: 'credit', balanceCents: -5000, statementBalanceCents: 5000, dueDate: DateTime(2026, 11, 8))]).cardsDueCents, 5000);
    });
    test('loan payment before payday counts once, never twice when a recurring bill covers it', () {
      final loan = Account(id: 'l', name: 'Student loan', institution: 'SoFi', type: 'loan', balanceCents: -1825000, nextPaymentCents: 40000, dueDate: DateTime(2026, 11, 18));
      expect(run([loan]).loansDueCents, 40000);
      final rec = [Recurring(id: 'r', merchant: 'SoFi loan', cadence: Cadence.monthly, expectedCents: 40000, nextDate: DateTime(2026, 11, 18))];
      final r = run([loan], rec: rec);
      expect((r.loansDueCents, r.billsCents), (0, 40000));
      expect(run([Account(id: 'l2', name: 'Loan', type: 'loan', nextPaymentCents: 40000, dueDate: DateTime(2026, 12, 1))]).loansDueCents, 0);
    });
  });

  group('natural input', () {
    final now = DateTime(2026, 11, 4);
    test('uber 18', () {
      final p = parseNatural('uber 18', now)!;
      expect(p.amountCents, -1800);
      expect(p.merchant, 'Uber');
      expect(p.categoryHint, 'Rideshare');
    });
    test('got 40 from Alex', () {
      final p = parseNatural('got 40 from Alex', now)!;
      expect(p.amountCents, 4000);
      expect(p.person, 'Alex');
      expect(p.isIncome, isTrue);
    });
    test('rent 1850 on the 1st', () {
      final p = parseNatural('rent 1850 on the 1st', now)!;
      expect(p.amountCents, -185000);
      expect(p.merchant, 'Rent');
      expect(p.recurringDayOfMonth, 1);
    });
    test('amount first and decimals, yesterday', () {
      final p = parseNatural('\$4.50 coffee yesterday', now)!;
      expect(p.amountCents, -450);
      expect(p.merchant, 'Coffee');
      expect(p.date, DateTime(2026, 11, 3));
    });
    test('invalid', () {
      expect(parseNatural('hello', now), isNull);
      expect(parseNatural('', now), isNull);
      expect(parseNatural('uber 0', now), isNull);
    });
    test('business suggestion', () {
      expect(looksBusiness('Cursor'), isTrue);
      expect(looksBusiness('Namecheap domain'), isTrue);
      expect(looksBusiness('Chipotle'), isFalse);
    });
    test('next day of month', () {
      expect(nextDayOfMonth(1, DateTime(2026, 11, 4)), DateTime(2026, 12, 1));
      expect(nextDayOfMonth(9, DateTime(2026, 11, 4)), DateTime(2026, 11, 9));
    });
  });
}
