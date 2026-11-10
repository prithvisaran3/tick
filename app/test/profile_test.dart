import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tick/data/settings.dart';
import 'package:tick/domain/budget_plan.dart';
import 'package:tick/domain/models.dart';
import 'package:tick/domain/payday.dart';
import 'package:tick/domain/paychecks.dart';
import 'package:tick/data/link_info.dart';
import 'package:tick/features/payday_editor.dart';
import 'package:tick/features/profile_screen.dart';
import 'golden_harness.dart';

void main() {
  setUpAll(loadFonts);

  test('the pay rule round-trips: schedule, take-home, varies, account, employer and a second income', () {
    final r = PaydayRule(frequency: PayFrequency.biweekly, anchor: DateTime(2026, 11, 13), amountCents: 231000, varies: true, accountId: 'chase', employer: 'Institute Payroll',
        second: PaydayRule(frequency: PayFrequency.semimonthly, anchor: DateTime(2026, 11, 15), amountCents: 40000, days: const [15, 30], employer: 'Tutoring'));
    final back = PaydayRule.fromMap(r.toMap())!;
    expect((back.amountCents, back.varies, back.accountId, back.employer), (231000, true, 'chase', 'Institute Payroll'));
    expect((back.second!.frequency, back.second!.amountCents), (PayFrequency.semimonthly, 40000));
    expect(back.second!.days, [15, 30]);
    final s = AppSettings.fromJson(AppSettings(rule: r).toJson());
    expect(s.rule!.second!.employer, 'Tutoring');
  });

  test('settings saved by an older version still read', () {
    final s = AppSettings.fromJson({'rule': {'f': 'biweekly', 'a': '2026-11-13T00:00:00.000', 'c': 1000}});
    expect((s.rule!.frequency, s.rule!.amountCents), (PayFrequency.biweekly, 1000));
  });

  test('changing to biweekly from Nov 13 makes the current period Oct 30 to Nov 12', () {
    final r = PaydayRule(frequency: PayFrequency.biweekly, anchor: DateTime(2026, 11, 13), amountCents: 0);
    final p = payPeriod(r, DateTime(2026, 11, 9));
    expect((p.start, p.end, p.nextPayday), (DateTime(2026, 10, 30), DateTime(2026, 11, 12), DateTime(2026, 11, 13)));
    expect(scheduleLine(r, DateTime(2026, 11, 9)), 'Every two weeks · next Fri, Nov 13');
  });

  test('holidays: July 4th 2026 is a Saturday, observed Friday the 3rd; a Saturday 15th pays the 14th', () {
    expect(isBankHoliday(DateTime(2026, 7, 3)), isTrue);
    expect(isBankHoliday(DateTime(2026, 7, 2)), isFalse);
    final r = PaydayRule(frequency: PayFrequency.semimonthly, anchor: DateTime(2026, 7, 3), amountCents: 0, days: const [3, 18]);
    expect(payDates(r, DateTime(2026, 6, 30)).$2, DateTime(2026, 7, 2));
    final f = PaydayRule(frequency: PayFrequency.semimonthly, anchor: DateTime(2026, 8, 14), amountCents: 0, days: const [15, 31]);
    expect(payDates(f, DateTime(2026, 8, 10)).$2, DateTime(2026, 8, 14));
  });

  test('a take-home change changes the Payday plan; Safe to spend until payday is cash-based and stays put', () {
    final now = DateTime(2026, 11, 12);
    final accts = [const Account(id: 'c', name: 'Chase', type: 'checking', balanceCents: 100000)];
    PaydayPlan plan(int pay) => buildPaydayPlan(today: now, rule: PaydayRule(frequency: PayFrequency.biweekly, anchor: DateTime(2026, 11, 13), amountCents: pay), accounts: accts, recurring: const [], goals: const [], paycheckLanded: false);
    expect(plan(250000).safeAfterCents - plan(231000).safeAfterCents, 19000);
  });

  test('paused goals plan nothing', () {
    final now = DateTime(2026, 11, 12);
    final g = const Goal(id: 'g', name: 'Trip', targetCents: 100000, savedCents: 0, perPaydayCents: 5000);
    PaydayPlan plan(Goal x) => buildPaydayPlan(today: now, rule: PaydayRule(frequency: PayFrequency.biweekly, anchor: DateTime(2026, 11, 13), amountCents: 0), accounts: const [], recurring: const [], goals: [x], paycheckLanded: false);
    expect(plan(g).moves.length, 1);
    expect(plan(g.copyWith(paused: true)).moves, isEmpty);
  });

  test('Tick suggests the take-home from the last three paychecks and who pays', () {
    const cats = {'inc': Category(id: 'inc', name: 'Income', colorKey: 'inc', icon: 'arrow-in', kind: 'income')};
    final accts = [const Account(id: 'chase', name: 'Chase', type: 'checking')];
    Txn pay(int i, int c) => Txn(id: 'p$i', amountCents: c, occurredAt: DateTime(2026, 10, i), merchant: 'INSTITUTE OF NUC PAYROLL', categoryId: 'inc', accountId: 'chase');
    final g = guessPaychecks([pay(2, 231000), pay(16, 229500), pay(30, 231000), Txn(id: 'z', amountCents: 5000, occurredAt: DateTime(2026, 10, 20), merchant: 'Zelle payment from ASHA', categoryId: 'inc', accountId: 'chase')], cats, accts);
    expect((g.employer, g.typicalCents, g.accountId, g.amounts.length), ('Institute Of Nuc Payroll', 231000, 'chase', 3));
  });

  for (final dark in [true, false]) {
    testWidgets('golden: Profile ${dark ? 'dark' : 'light'}', (t) async {
      final c = await demoContainer();
      addTearDown(c.dispose);
      await pumpGolden(t, frame(c, const ProfileScreen(), dark: dark));
      await expectLater(find.byType(ProfileScreen), matchesGoldenFile('goldens/profile.${dark ? 'dark' : 'light'}.png'));
    });
  }

  testWidgets('golden: the Pay editor', (t) async {
    final c = await demoContainer();
    addTearDown(c.dispose);
    await pumpGolden(t, frame(c, SingleChildScrollView(child: Padding(padding: const EdgeInsets.all(20), child: PaydayEditor(today: DateTime(2026, 11, 9), onChanged: (_) {},
        initial: PaydayRule(frequency: PayFrequency.biweekly, anchor: DateTime(2026, 11, 13), amountCents: 0)))), dark: true));
    expect(find.text('Oct 30 – Nov 12'), findsOneWidget);
    await expectLater(find.byType(PaydayEditor), matchesGoldenFile('goldens/pay-editor.png'));
  });

  testWidgets('someone who isn\'t the owner sees no bank-link controls', (t) async {
    final c = await demoContainer(demo: false, overrides: [linkInfoProvider.overrideWith((ref) async => const LinkInfo(used: 3, cap: 10, left: 0, canLink: false, totalLeft: 7))]);
    addTearDown(c.dispose);
    await pumpGolden(t, frame(c, const ProfileScreen(), dark: true));
    await t.scrollUntilVisible(find.text('Apple Card'), 200);
    expect(find.textContaining('linked by this Tick\'s owner'), findsOneWidget);
    expect(find.text('Banks'), findsOneWidget);
    expect(find.text('None linked'), findsNothing);
  });
}
