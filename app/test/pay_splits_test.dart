import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tick/data/pay_splits.dart';
import 'package:tick/domain/models.dart';
import 'package:tick/domain/pay_splits.dart';
import 'package:tick/features/pay_splits_screen.dart';
import 'package:tick/data/settings.dart';
import 'golden_harness.dart';

PaySplit fx(int cents, {String? id, String? label}) => PaySplit(accountId: id, label: label, kind: SplitKind.fixed, value: cents);
PaySplit pct(int bp, {String? id, String? label}) => PaySplit(accountId: id, label: label, kind: SplitKind.percent, value: bp);
PaySplit rest({String? id, String? label}) => PaySplit(accountId: id, label: label, kind: SplitKind.rest);

class _Api implements PaySplitsApi {
  List<PaySplit>? saved;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  Future<void> save(List<PaySplit> splits) async => saved = splits;
  @override
  Future<({List<PaySplit> splits, int? netCents})> suggested() async => (splits: [rest(label: 'Checking'), fx(50000, label: 'Savings')], netCents: 247707);
}

void main() {
  setUpAll(loadFonts);

  test('the shared vectors (same file SQL and Python run)', () {
    final cases = (jsonDecode(File('../api/tests/data/pay_splits.json').readAsStringSync())['cases'] as List).cast<Map<String, dynamic>>();
    for (final c in cases) {
      final splits = [for (final s in c['splits'] as List) PaySplit.fromJson((s as Map).cast<String, dynamic>())];
      final got = splitAmounts(c['net'] as int, splits);
      expect(got, c['want'], reason: c['name'] as String);
      if (splits.any((s) => s.kind == SplitKind.rest)) expect(got.fold<int>(0, (a, b) => a + b), c['net'], reason: c['name'] as String);
    }
  });

  test('problems are named as you type', () {
    expect(splitProblem(247707, const []), isNull);
    expect(splitProblem(247707, [fx(50000, id: 'a')]), 'One line needs to take the rest.');
    expect(splitProblem(247707, [rest(id: 'a'), rest(id: 'b')]), 'Only one line can take the rest.');
    expect(splitProblem(247707, [fx(0, id: 'a'), rest(id: 'b')]), 'Enter an amount or a percent on every line.');
    expect(splitProblem(247707, [pct(6000, id: 'a'), pct(5000, id: 'c'), rest(id: 'b')]), 'The percents add up to 110%. Keep them at 100% or less.');
    expect(splitProblem(247707, [fx(300000, id: 'a'), rest(id: 'b')]), 'The fixed amounts are more than one paycheck.');
    expect(splitProblem(247707, [fx(5000, id: 'a'), rest(id: 'a')]), 'Each account can have one line.');
    expect(splitProblem(247707, [fx(50000, id: 'a'), pct(1000, label: 'Brokerage'), rest(id: 'b')]), isNull);
  });

  test('only split lines into checking that counts reach Cash', () {
    const chk = Account(id: 'chk', name: 'Chase', type: 'checking'), sav = Account(id: 'sav', name: 'SoFi', type: 'savings'), off = Account(id: 'off', name: 'Old', type: 'checking', includeInSafe: false);
    final accts = [chk, sav, off];
    expect(paycheckIntoCash(247707, const [], accts), 247707);
    expect(paycheckIntoCash(247707, const [], accts, landsIn: 'sav'), 0);
    expect(paycheckIntoCash(247707, [fx(50000, id: 'sav'), pct(1000, label: 'Brokerage'), fx(10000, id: 'off'), rest(id: 'chk')], accts), 247707 - 50000 - 24770 - 10000);
  });

  for (final (w, dark) in [(320.0, true), (430.0, false)]) {
    testWidgets('editor shows every line in dollars and saves the set ($w ${dark ? 'dark' : 'light'})', (t) async {
      final api = _Api();
      final c = await demoContainer(overrides: [
        paySplitsProvider.overrideWith((ref) async => [fx(50000, label: 'Savings'), pct(1000, label: 'Brokerage'), rest(label: 'Checking')]),
        paySplitsApiProvider.overrideWithValue(api),
      ]);
      addTearDown(c.dispose);
      c.read(settingsProvider.notifier).update((s) => s.copyWith(rule: s.rule?.copyWith(amountCents: 247707)));
      await pumpGolden(t, frame(c, Navigator(onGenerateRoute: (_) => PageRouteBuilder<void>(pageBuilder: (_, _, _) => const PaySplitsScreen())), dark: dark), width: w, height: 1100);
      expect(find.text('\$2,477.07 per paycheck'), findsOneWidget);
      expect(find.text('\$500.00'), findsOneWidget);
      expect(find.text('\$247.70'), findsOneWidget);
      expect(find.text('\$1,729.37'), findsOneWidget);
      await expectLater(find.byType(PaySplitsScreen), matchesGoldenFile('goldens/pay-splits.${w.toInt()}.${dark ? 'dark' : 'light'}.png'));
      // typing changes the dollars at once, and a bad set can't be saved
      await t.enterText(find.byType(EditableText).first, '3000');
      await t.pump();
      expect(find.text('The fixed amounts are more than one paycheck.'), findsOneWidget);
      await t.enterText(find.byType(EditableText).first, '600');
      await t.pump();
      expect(find.text('\$600.00'), findsOneWidget);
      expect(find.text('\$1,629.37'), findsOneWidget);
      await t.ensureVisible(find.text('Save'));
      await t.tap(find.text('Save'));
      await t.pump(const Duration(milliseconds: 300));
      expect(api.saved!.map((s) => (s.kind, s.value)).toList(), [(SplitKind.fixed, 60000), (SplitKind.percent, 1000), (SplitKind.rest, 0)]);
      await t.pump(const Duration(seconds: 6));
    });
  }

  testWidgets('empty: one account, with the pay statement offered as a start', (t) async {
    final c = await demoContainer(overrides: [paySplitsProvider.overrideWith((ref) async => const <PaySplit>[]), paySplitsApiProvider.overrideWithValue(_Api())]);
    addTearDown(c.dispose);
    await pumpGolden(t, frame(c, const PaySplitsScreen(), dark: true));
    expect(find.text('It all lands in one account'), findsOneWidget);
    await t.tap(find.text('Use my last pay statement'));
    await t.pump();
    expect(find.text('Checking'), findsOneWidget);
    expect(find.text('Savings'), findsOneWidget);
  });

  testWidgets('largest text at 320', (t) async {
    final c = await demoContainer(overrides: [paySplitsProvider.overrideWith((ref) async => [fx(50000, label: 'Savings'), rest(label: 'Checking')]), paySplitsApiProvider.overrideWithValue(_Api())]);
    addTearDown(c.dispose);
    await pumpGolden(t, MediaQuery(data: const MediaQueryData(textScaler: TextScaler.linear(2.0)), child: frame(c, const PaySplitsScreen(), dark: true)), width: 320);
    expect(t.takeException(), isNull);
  });
}
