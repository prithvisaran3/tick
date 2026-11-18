import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tick/data/ledger.dart';
import 'package:tick/data/planned.dart';
import 'package:tick/domain/goals.dart';
import 'package:tick/domain/models.dart';
import 'package:tick/domain/planned.dart';
import 'package:tick/domain/safe_to_spend.dart';
import 'package:tick/features/planned_screen.dart';
import 'package:tick/features/review.dart';
import 'golden_harness.dart';

Widget nav(Widget child) => Navigator(onGenerateRoute: (_) => PageRouteBuilder<void>(pageBuilder: (_, _, _) => child));
final today = DateTime(2026, 11, 15);
final rule = PaydayRule(frequency: PayFrequency.biweekly, anchor: DateTime(2026, 11, 27), amountCents: 247707);
const chk = Account(id: 'chk', name: 'Chase', type: 'checking', balanceCents: 180000, availableCents: 180000);
const sav = Account(id: 'sav', name: 'SoFi', type: 'savings', balanceCents: 500000, includeInSafe: false);
final goal = Goal(id: 'g', name: 'House move', targetCents: 900000, savedCents: 0, perPaydayCents: 0, mode: 'save_more', startCents: 500000, startDate: today, dueDate: DateTime(2027, 2, 15), accountIds: const ['sav']);
PlannedExpense gift({String? resolution, int shortfall = 0, String status = 'planned', DateTime? due}) =>
    PlannedExpense(id: 'p', name: 'Birthday gift', amountCents: 50000, due: due ?? DateTime(2026, 11, 22), resolution: resolution, shortfallCents: shortfall, status: status);

SafeToSpend safe(List<PlannedExpense> planned, {int relief = 0}) => computeSafeToSpend(today: today, rule: rule, accounts: const [chk, sav], recurring: const [],
    goals: plannedGoals([goal], const [chk, sav], rule, today, reliefCents: relief), planned: planned);

void main() {
  setUpAll(loadFonts);

  test('"Birthday gift", \$500, this month: it comes out of Safe to spend for its pay period', () {
    final before = safe(const []);
    expect((before.cashCents, before.goalsCents, before.cents), (180000, 150000, 30000));
    final after = safe([gift()]);
    expect((after.plannedCents, after.cents), (50000, -20000));
    expect(after.lines.where((l) => l.group == 'planned').single.label, 'Birthday gift');
    expect(after.lines.fold<int>(0, (s, l) => s + l.cents), after.cents);                     // the breakdown still adds up
    expect(safe([gift(due: DateTime(2026, 12, 5))]).plannedCents, 0);                        // next pay period: not yet
    expect(safe([gift(status: 'matched')]).plannedCents, 0);                                 // bought: no longer set aside
  });

  test('it puts the goal behind: one line, two choices', () {
    final plans = [planGoal(goal, const [chk, sav], rule, today)];
    final t = tradeOff(freeCents: safe([gift()]).cents, plans: plans, planned: [gift()], rule: rule, today: today, payday: DateTime(2026, 11, 27))!;
    expect((t.shortfallCents, t.laterPaychecks, t.addPerLaterCents), (20000, 5, 4000));      // $200 short, spread over the 5 paychecks after this one
    expect(t.newDeadline, DateTime(2027, 2, 19));                                           // one more paycheck at $1,500 covers it
    expect(tradeOffLine(t), 'Birthday gift leaves \$200.00 less for House move this paycheck.');
    expect(tradeOff(freeCents: 100, plans: plans, planned: [gift()], rule: rule, today: today, payday: DateTime(2026, 11, 27)), isNull);
    // once I've chosen, this paycheck's move shrinks by the shortfall and the plan fits again
    final chosen = gift(resolution: 'catch_up', shortfall: 20000);
    expect(goalRelief([chosen], DateTime(2026, 11, 13), DateTime(2026, 11, 27)), 20000);
    final fixed = safe([chosen], relief: 20000);
    expect((fixed.goalsCents, fixed.cents), (130000, 0));
    expect(tradeOff(freeCents: fixed.cents, plans: plans, planned: [chosen], rule: rule, today: today, payday: DateTime(2026, 11, 27)), isNull);
    // still relieved after the purchase is matched, so the money isn't asked for twice
    expect(goalRelief([gift(resolution: 'catch_up', shortfall: 20000, status: 'matched')], DateTime(2026, 11, 13), DateTime(2026, 11, 27)), 20000);
  });

  test('the real purchase is found by amount and date, once', () {
    Txn tx(String id, int cents, int day, {String? flow}) => Txn(id: id, amountCents: cents, occurredAt: DateTime(2026, 11, day, 12), merchant: 'Shop $id', flow: flow);
    final got = plannedMatches([gift()], [tx('far', -48000, 2), tx('transfer', -50000, 22, flow: 'transfer'), tx('big', -90000, 22), tx('close', -46500, 23), tx('exact', -50000, 21), tx('in', 50000, 22)]);
    expect(got.single.$2.id, 'exact');
    expect(plannedMatches([gift().copyWith(rejected: ['exact'])], [tx('close', -46500, 23), tx('exact', -50000, 21)]).single.$2.id, 'close');
    expect(plannedMatches([gift(status: 'matched')], [tx('exact', -50000, 21)]), isEmpty);
  });

  for (final (w, dark) in [(320.0, true), (430.0, false)]) {
    testWidgets('Planned: the list, and the trade-off with its two choices ($w ${dark ? 'dark' : 'light'})', (t) async {
      final c = await demoContainer(now: today);
      addTearDown(c.dispose);
      await c.read(plannedProvider.future);
      await c.read(plannedProvider.notifier).add('Birthday gift', 50000, DateTime(2026, 11, 18));
      final tr = TradeOff(expense: c.read(plannedProvider).value!.single, goal: goal, shortfallCents: 20000, addPerLaterCents: 4000, laterPaychecks: 5, newDeadline: DateTime(2027, 2, 19));
      final scoped = await demoContainer(now: today, overrides: [tradeOffProvider.overrideWith((ref) => tr)]);
      addTearDown(scoped.dispose);
      await scoped.read(plannedProvider.future);
      await scoped.read(plannedProvider.notifier).add('Birthday gift', 50000, DateTime(2026, 11, 18));
      await pumpGolden(t, frame(scoped, nav(const PlannedScreen()), dark: dark), width: w);
      expect(find.text('Birthday gift leaves \$200.00 less for House move this paycheck.'), findsOneWidget);
      expect(find.text('Add \$40 to later paychecks'), findsOneWidget);
      expect(find.text('Move deadline to Feb 19'), findsOneWidget);
      expect(find.text('\$500.00 set aside this pay period'), findsOneWidget);
      await expectLater(find.byType(PlannedScreen), matchesGoldenFile('goldens/planned.${w.toInt()}.${dark ? 'dark' : 'light'}.png'));
    });
  }

  testWidgets('adding one from the sheet lowers Safe to spend by exactly that', (t) async {
    final c = await demoContainer(now: today);
    addTearDown(c.dispose);
    await c.read(plannedProvider.future);
    final before = c.read(safeToSpendProvider)!.cents;
    await pumpGolden(t, frame(c, nav(const PlannedScreen()), dark: true));
    expect(find.text('Nothing planned'), findsOneWidget);
    await t.tap(find.text('Plan a one-off'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(EditableText).at(0), 'Birthday gift');
    await t.enterText(find.byType(EditableText).at(1), '500');
    await t.tap(find.text('Add to the plan'));
    await t.pumpAndSettle();
    expect(find.text('Birthday gift'), findsOneWidget);
    expect(c.read(safeToSpendProvider)!.cents, before - 50000);
  });

  testWidgets('the Yes/No card matches it to the real purchase and it drops off', (t) async {
    final c = await demoContainer(now: today);
    addTearDown(c.dispose);
    await c.read(plannedProvider.future);
    final tx = c.read(ledgerProvider).txns.firstWhere((x) => x.amountCents < -1500 && !x.isTransfer);
    await c.read(plannedProvider.notifier).add('Night out', -tx.amountCents, dayOnlyOf(tx.occurredAt));
    final q = c.read(reviewQuestionsProvider).firstWhere((q) => q.kind == 'Planned');
    expect(q.question, startsWith('Was '));
    expect(q.txnIds, [tx.id]);
    await pumpGolden(t, frame(c, nav(SingleChildScrollView(child: ReviewCard(q: q))), dark: true), width: 320);
    await t.tap(find.text('Yes'));
    await t.pump(const Duration(milliseconds: 300));
    expect(c.read(plannedProvider).value!.single.status, 'matched');
    expect(c.read(reviewQuestionsProvider).where((q) => q.kind == 'Planned'), isEmpty);
  });

  testWidgets('a one-off already bought is not set aside twice while it waits for Yes', (t) async {
    final c = await demoContainer(now: today);
    addTearDown(c.dispose);
    await c.read(plannedProvider.future);
    final before = c.read(safeToSpendProvider)!.cents;
    final tx = c.read(ledgerProvider).txns.firstWhere((x) => x.amountCents < -1500 && !x.isTransfer);
    await c.read(plannedProvider.notifier).add('Night out', -tx.amountCents, dayOnlyOf(tx.occurredAt));
    expect(c.read(safeToSpendProvider)!.cents, before);                  // it posted already: the purchase is in Cash, not set aside again
    await c.read(plannedProvider.notifier).add('Later thing', 4200, DateTime(2026, 11, 18));
    expect(c.read(safeToSpendProvider)!.cents, before - 4200);
  });

  testWidgets('largest text at 320', (t) async {
    final c = await demoContainer(now: today);
    addTearDown(c.dispose);
    await c.read(plannedProvider.future);
    await c.read(plannedProvider.notifier).add('Birthday gift for a very dear friend', 50000, DateTime(2026, 11, 18));
    await pumpGolden(t, MediaQuery(data: const MediaQueryData(textScaler: TextScaler.linear(2.0)), child: frame(c, nav(const PlannedScreen()), dark: true)), width: 320);
    expect(t.takeException(), isNull);
  });
}

DateTime dayOnlyOf(DateTime d) => DateTime(d.year, d.month, d.day);
