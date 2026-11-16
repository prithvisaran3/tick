import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tick/data/ledger.dart';
import 'package:tick/data/savings.dart';
import 'package:tick/domain/goals.dart';
import 'package:tick/domain/models.dart';
import 'package:tick/features/savings_screen.dart';
import 'golden_harness.dart';

Widget nav(Widget child) => Navigator(onGenerateRoute: (_) => PageRouteBuilder<void>(pageBuilder: (_, _, _) => child));
final day = DateTime(2026, 11, 13, 9);

void main() {
  setUpAll(loadFonts);

  test('change this month is measured from the last balance before the month', () {
    final pts = <BalancePoint>[(day: DateTime(2026, 10, 30), cents: 800000), (day: DateTime(2026, 11, 2), cents: 810000), (day: DateTime(2026, 11, 12), cents: 835000)];
    expect(changeThisMonth(pts, 840000, DateTime(2026, 11, 13)), 40000);
    expect(changeThisMonth(pts.sublist(1), 840000, DateTime(2026, 11, 13)), 30000);       // no earlier balance: from the month's first
    expect(changeThisMonth(const [], 840000, DateTime(2026, 11, 13)), isNull);
  });

  test('the line under a goal says where it stands', () {
    GoalStatus st(GoalState s, {int per = 150000, int behind = 0, int left = 4, int remaining = 600000}) =>
        GoalStatus(state: s, savedCents: 300000, remainingCents: remaining, paychecksLeft: left, perPaycheckCents: per, behindByCents: behind, amountCents: 900000);
    final g = Goal(id: 'g', name: 'Move', targetCents: 900000, savedCents: 0, perPaydayCents: 0, mode: 'save_more', dueDate: DateTime(2027, 2, 15), accountIds: const ['sav']);
    expect(goalLine(GoalPlan(g, st(GoalState.onTrack))), 'On track · \$1,500.00 a paycheck until Feb 15');
    expect(goalLine(GoalPlan(g, st(GoalState.behind, per: 187500, behind: 150000))), 'Behind by \$1,500.00 · \$1,875.00 a paycheck catches up by Feb 15');
    expect(goalLine(GoalPlan(g, st(GoalState.done, remaining: 0))), 'Done');
    expect(goalLine(GoalPlan(g.copyWith(paused: true), st(GoalState.onTrack))), 'Paused');
    expect(goalLine(GoalPlan(const Goal(id: 'o', name: 'Old', targetCents: 1, savedCents: 0, perPaydayCents: 0), st(GoalState.onTrack))), 'Link an account to track this from its balance');
  });

  for (final (w, dark) in [(320.0, true), (430.0, false)]) {
    testWidgets('Savings: balance, change this month, trend, goals ($w ${dark ? 'dark' : 'light'})', (t) async {
      final c = await demoContainer(now: day);
      addTearDown(c.dispose);
      await pumpGolden(t, frame(c, nav(const SavingsScreen()), dark: dark), width: w);
      expect(find.text('\$8,400.00'), findsWidgets);
      expect(find.textContaining('this month'), findsWidgets);
      expect(find.text('Emergency fund'), findsOneWidget);
      expect(find.textContaining('a paycheck'), findsOneWidget);
      expect(find.text('New goal'), findsOneWidget);
      await expectLater(find.byType(SavingsScreen), matchesGoldenFile('goldens/savings.${w.toInt()}.${dark ? 'dark' : 'light'}.png'));
    });
  }

  testWidgets('new goal: \$9,000 by a date shows the paychecks left and the amount each, live, and saves from today\'s balance', (t) async {
    final c = await demoContainer(now: day);
    addTearDown(c.dispose);
    await pumpGolden(t, frame(c, nav(const SavingsScreen()), dark: true), height: 1400);
    await t.tap(find.text('New goal'));
    await t.pumpAndSettle();
    final fields = find.byType(EditableText);
    await t.enterText(fields.at(0), 'House move');
    await t.enterText(fields.at(1), '9000');
    await t.enterText(fields.at(2), '02/15/2027');
    await t.pump();
    expect(find.textContaining('paychecks left'), findsOneWidget);
    await expectLater(find.byType(Navigator).first, matchesGoldenFile('goldens/goal-editor.png'));
    await t.ensureVisible(find.text('Save'));
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    final g = c.read(ledgerProvider).goals.firstWhere((g) => g.name == 'House move');
    expect((g.mode, g.targetCents, g.startCents, g.dueDate), ('save_more', 900000, 840000, DateTime(2027, 2, 15)));
    expect(g.accountIds, ['acc-sav']);
    final p = c.read(goalPlansProvider).firstWhere((p) => p.goal.name == 'House move');
    expect(p.status.perPaycheckCents * p.status.paychecksLeft, greaterThanOrEqualTo(900000));
    expect(p.status.savedCents, 0);
  });

  testWidgets('the editor says what is wrong in words', (t) async {
    final c = await demoContainer(now: day);
    addTearDown(c.dispose);
    await pumpGolden(t, frame(c, nav(const SavingsScreen()), dark: true), height: 1400);
    await t.tap(find.text('New goal'));
    await t.pumpAndSettle();
    await t.ensureVisible(find.text('Save'));
    await t.tap(find.text('Save'));
    await t.pump();
    expect(find.text('A name and an amount, please.'), findsOneWidget);
    await t.enterText(find.byType(EditableText).at(0), 'X');
    await t.enterText(find.byType(EditableText).at(1), '100');
    await t.enterText(find.byType(EditableText).at(2), '01/01/2020');
    await t.ensureVisible(find.text('Save'));
    await t.tap(find.text('Save'));
    await t.pump();
    expect(find.text('Pick a deadline after today.'), findsOneWidget);
  });

  for (final dark in [true, false]) {
    testWidgets('payday card: one number, Done, then waiting on the balance (${dark ? 'dark' : 'light'})', (t) async {
      final payday = DateTime(2026, 11, 13);
      final c = await demoContainer(now: day, overrides: [
        paydayMoveProvider.overrideWith((ref) => (payday: payday, cents: 150000, state: ref.watch(goalMovesProvider).value?['2026-11-13'] ?? MoveState.none)),
      ]);
      addTearDown(c.dispose);
      await pumpGolden(t, frame(c, nav(const SingleChildScrollView(child: MoveToSavingsCard())), dark: dark), width: 320);
      expect(find.text('Move \$1,500.00 to savings'), findsOneWidget);
      await expectLater(find.byType(MoveToSavingsCard), matchesGoldenFile('goldens/move-to-savings.${dark ? 'dark' : 'light'}.png'));
      await t.tap(find.text('Done'));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('Marked moved'), findsOneWidget);
      expect(c.read(goalMovesProvider.notifier).of(payday), MoveState.done);
      await t.tap(find.text('Not moved yet? Undo'));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('Done'), findsOneWidget);
    });
  }

  testWidgets('nothing to move, no card', (t) async {
    final c = await demoContainer(now: day, overrides: [paydayMoveProvider.overrideWith((ref) => null)]);
    addTearDown(c.dispose);
    await pumpGolden(t, frame(c, nav(const MoveToSavingsCard()), dark: true));
    expect(find.textContaining('savings'), findsNothing);
  });

  testWidgets('largest text at 320', (t) async {
    final c = await demoContainer(now: day);
    addTearDown(c.dispose);
    await pumpGolden(t, MediaQuery(data: const MediaQueryData(textScaler: TextScaler.linear(2.0)), child: frame(c, nav(const SavingsScreen()), dark: true)), width: 320);
    expect(t.takeException(), isNull);
  });
}
