import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tick/data/ledger.dart';
import 'package:tick/domain/balances.dart';
import 'package:tick/features/today_screen.dart';
import 'golden_harness.dart';
import 'package:tick/domain/models.dart';
import 'package:tick/domain/planned.dart';
import 'package:tick/domain/runway.dart';
import 'package:tick/domain/tally.dart';

final today = DateTime(2026, 11, 15);
final payday = DateTime(2026, 11, 27);
const chk = Account(id: 'chk', name: 'Chase', type: 'checking', balanceCents: 20000, availableCents: 20000, connectionId: 'c1');

Recurring bill(String name, int cents, DateTime next) => Recurring(id: name, merchant: name, cadence: Cadence.monthly, expectedCents: cents, nextDate: next);

void main() {
  setUpAll(loadFonts);

  test('checking runs short on the day the money leaves, not on payday', () {
    // $200 in checking: rent $150 on Nov 18 leaves $50, internet $64 on Nov 20 takes it $14 below zero; the gym on Nov 28 is after payday
    final s = firstShortfall(accounts: const [chk], recurring: [bill('Rent', 15000, DateTime(2026, 11, 18)), bill('Internet', 6400, DateTime(2026, 11, 20)), bill('Gym', 5000, DateTime(2026, 11, 28))], today: today, payday: payday)!;
    expect((s.day, s.label, s.cents, s.shortCents), (DateTime(2026, 11, 20), 'Internet', 6400, 1400));
  });

  test('fine all period, nothing to say; a card due and a planned one-off count too', () {
    expect(firstShortfall(accounts: const [chk], recurring: [bill('Internet', 6400, DateTime(2026, 11, 20))], today: today, payday: payday), isNull);
    final card = Account(id: 'card', name: 'Discover', type: 'credit', balanceCents: -30000, statementBalanceCents: 15000, dueDate: DateTime(2026, 11, 19));
    final s = firstShortfall(accounts: [chk, card], recurring: const [], today: today, payday: payday,
        planned: [PlannedExpense(id: 'p', name: 'Birthday gift', amountCents: 8000, due: DateTime(2026, 11, 22))])!;
    expect((s.label, s.shortCents), ('Birthday gift', 3000));
    expect(firstShortfall(accounts: const [], recurring: [bill('Rent', 1, today)], today: today, payday: payday), isNull);
  });

  test('stale balances say so after a day; manual and never-synced say nothing', () {
    final now = DateTime(2026, 11, 15, 12);
    Connection conn(DateTime? at) => Connection(id: 'c1', institution: 'Chase', status: 'active', lastSyncedAt: at);
    expect(cashAge(accounts: const [chk], connections: [conn(now.subtract(const Duration(hours: 5)))], now: now), isNull);
    final age = cashAge(accounts: const [chk], connections: [conn(now.subtract(const Duration(days: 2, hours: 1)))], now: now)!;
    expect(cashAgeLine(age, now), 'Balances from 2 days ago');
    expect(cashAge(accounts: const [chk], connections: [conn(null)], now: now), isNull);
    expect(cashAge(accounts: const [Account(id: 'm', name: 'Cash', type: 'checking', manual: true)], connections: const [], now: now), isNull);
  });

  test('a Tally balance says how long it has been open, from the last settle-up', () {
    TallyExpense ex(DateTime on) => TallyExpense(id: '$on', groupId: 'g', description: 'x', amountCents: 100, paidBy: 'me', shares: const {'me': 50, 'p': 50}, spentOn: on);
    final exs = [ex(DateTime(2026, 9, 20)), ex(DateTime(2026, 10, 2)), ex(DateTime(2026, 11, 10))];
    final settled = [TallySettlement(id: 's', groupId: 'g', from: 'p', to: 'me', amountCents: 50, on: DateTime(2026, 9, 25))];
    expect(openSince(netCents: 100, expenses: exs, settlements: settled, today: today), DateTime(2026, 10, 2));
    expect(openSince(netCents: 0, expenses: exs, settlements: settled, today: today), isNull);
    expect(openSince(netCents: 100, expenses: [ex(DateTime(2026, 11, 10))], settlements: const [], today: today), isNull);          // under two weeks
    expect(openSince(netCents: 100, expenses: exs, settlements: [...settled, TallySettlement(id: 'p', groupId: 'g', from: 'p', to: 'me', amountCents: 1, on: DateTime(2026, 11, 1), status: 'pending')], today: today), DateTime(2026, 10, 2));
  });

  for (final (w, dark) in [(320.0, true), (430.0, false)]) {
    testWidgets('Cash says when checking runs short and when balances are old ($w ${dark ? 'dark' : 'light'})', (t) async {
      final c = await demoContainer();
      addTearDown(c.dispose);
      final n = c.read(ledgerProvider.notifier);
      final l = c.read(ledgerProvider);
      final now = c.read(clockProvider)();
      final pay = c.read(safeToSpendProvider)!.nextPayday;
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      n.state = l.copyWith(
        recurring: [...l.recurring, Recurring(id: 'big', merchant: 'Rent', cadence: Cadence.monthly, expectedCents: 120000, nextDate: DateTime(now.year, now.month, now.day).add(const Duration(days: 1)))],
        connections: [for (final x in l.connections) Connection(id: x.id, institution: x.institution, status: x.status, lastSyncedAt: now.subtract(const Duration(days: 2, hours: 3)))],
      );
      expect(pay.isAfter(now), isTrue);
      await pumpGolden(t, frame(c, SingleChildScrollView(child: CashCard(b: homeBalances(c.read(ledgerProvider).accounts))), dark: dark), width: w);
      expect(find.textContaining('short in checking on'), findsOneWidget);
      expect(find.text('Balances from 2 days ago'), findsOneWidget);
      await expectLater(find.byType(CashCard), matchesGoldenFile('goldens/cash-warnings.${w.toInt()}.${dark ? 'dark' : 'light'}.png'));
    });
  }
}
