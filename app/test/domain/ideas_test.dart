import 'package:flutter_test/flutter_test.dart';
import 'package:tick/domain/ideas.dart';
import 'package:tick/domain/models.dart';
import 'package:tick/domain/safe_to_spend.dart';

void main() {
  final rule = PaydayRule(frequency: PayFrequency.biweekly, anchor: DateTime(2026, 11, 6), amountCents: 231000); // next payday Nov 20
  final today = DateTime(2026, 11, 10);
  final disc = Account(id: 'd', name: 'Discover it', institution: 'Discover', mask: '1234', type: 'credit', balanceCents: -81240,
      statementBalanceCents: 64012, dueDate: DateTime(2026, 11, 14), lastStatementDate: DateTime(2026, 10, 24), creditLimitCents: 500000);
  final savor = Account(id: 's', name: 'Savor', institution: 'Capital One', mask: '8810', type: 'credit', balanceCents: -192300,
      statementBalanceCents: 142000, dueDate: DateTime(2026, 12, 2), lastStatementDate: DateTime(2026, 10, 13), creditLimitCents: 250000);
  SafeToSpend sts(int checking, List<Account> cards) =>
      computeSafeToSpend(today: today, rule: rule, accounts: [Account(id: 'c', name: 'Checking', availableCents: checking), ...cards], recurring: const [], goals: const []);

  test('card-due guard: short when checking cannot cover what is due before payday', () {
    final g = cardGuard(sts(50000, [disc, savor]), [disc, savor], today)!;
    expect(g.short, isTrue);
    expect(g.shortCents, 64012 - 50000);
    expect(g.firstDue!.id, 'd');
    expect(cardGuardLine(g, today), r'Checking is $140 short of the cards and bills due before payday.');
    final ok = cardGuard(sts(300000, [disc]), [disc], today)!;
    expect(ok.short, isFalse);
    expect(cardGuardLine(ok, today), contains('covers'));
    expect(cardGuard(sts(300000, [savor]), [savor], today), isNull);           // nothing due before payday: stay quiet
  });

  test('truly free subtracts every card balance, not only what is due', () {
    final s = sts(300000, [disc, savor]);
    expect(s.cents, 300000 - 64012);
    expect(trulyFree(s), 300000 - 81240 - 192300);
    expect(trulyFreeLine(s), r'$264 truly free after every card balance');
    expect(trulyFreeLine(sts(100000, [disc, savor])), r'$1,735 short if every card balance were paid today');
  });

  test('statement cycle: next close, pay-in-full countdown, how much to pay to report under 30%', () {
    final c = statementCycle(savor, today)!;
    expect(c.closes, DateTime(2026, 11, 13));
    expect(c.daysToClose, 3);
    expect(c.payForUnder30Cents, 192300 - 72500);                               // 29% of $2,500 = $725
    expect(c.bestPayDay, DateTime(2026, 11, 11));
    expect(c.dueDays, 22);
    expect(utilisationHeadsUp(savor, today), r'Capital One ••8810 closes in 3 days. Paying $1,198 before then keeps it under 30%.');
    expect(statementCycle(disc, today)!.payForUnder30Cents, 0);                 // 16% is already fine
    expect(utilisationHeadsUp(disc, today), isNull);
    expect(statementCycle(const Account(id: 'x', name: 'Apple Card', type: 'credit'), today), isNull);
    // Month-end statement dates roll over to shorter months.
    final jan = Account(id: 'j', name: 'J', type: 'credit', lastStatementDate: DateTime(2026, 1, 31), creditLimitCents: 100);
    expect(statementCycle(jan, DateTime(2026, 2, 10))!.closes, DateTime(2026, 2, 28));
  });

  test('what if: an amount before you buy it', () {
    final s = sts(300000, [disc]);
    expect(whatIf(s, 5000).afterCents, s.cents - 5000);
    expect(whatIf(s, -5000).afterCents, s.cents - 5000);                         // sign-insensitive
    expect(whatIf(s, 999999).over, isTrue);
    expect(whatIf(s, 1).payday, DateTime(2026, 11, 20));
  });
}
