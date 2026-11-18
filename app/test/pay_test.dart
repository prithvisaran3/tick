import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tick/data/paystubs.dart';
import 'package:tick/data/statement_import.dart';
import 'package:tick/features/import_screen.dart';
import 'package:tick/features/pay_screens.dart';
import 'golden_harness.dart';

PayStatement stub(String id, DateTime d, {int gross = 373500, int net = 247707}) => PayStatement(id: id, employer: 'ACME ROBOTICS INC', payDate: d, grossCents: gross, taxesCents: 87883, deductionsCents: 37910, netCents: net,
    lines: const [PayLine('earning', 'Regular', 360000, 7200000), PayLine('tax', 'Federal Income Tax', 41250, 825000), PayLine('deduction', '401(K)', 22410, 436860), PayLine('deduction', 'Medical', 9500, 190000)],
    ytd: const {'gross': 7281000, 'net': 4800000, 'taxes': 1700000, 'deductions': 760000});

void main() {
  setUpAll(loadFonts);
  final stubs = [stub('a', DateTime(2026, 11, 13)), stub('b', DateTime(2026, 10, 30)), stub('c', DateTime(2025, 12, 31), gross: 300000, net: 200000)];

  test('this year\'s totals and the Profile line', () {
    final y = payThisYear(stubs, 2026);
    expect((y.gross, y.taxes, y.retirement, y.net, y.count), (747000, 175766, 44820, 495414, 2));
    expect(payStatementSummary(stubs), 'Latest: Nov 13 · \$2,477.07 net');
    expect(payStatementSummary(const []), 'None yet');
  });

  testWidgets('Insights Pay card: collapsed to one line, opens to the year and the keep rate', (t) async {
    final c = await demoContainer(demo: false, now: DateTime(2026, 11, 20), overrides: [payStatementsProvider.overrideWith((ref) async => stubs)]);
    addTearDown(c.dispose);
    await pumpGolden(t, frame(c, const SingleChildScrollView(child: PayInsightsCard()), dark: true));
    expect(find.text('\$4,954.14 net'), findsOneWidget);
    expect(find.textContaining('You keep'), findsNothing);
    await t.tap(find.text('Pay this year'));
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('You keep 66% of gross.'), findsOneWidget);
  });

  testWidgets('no statements, no card', (t) async {
    final c = await demoContainer(demo: false, overrides: [payStatementsProvider.overrideWith((ref) async => const <PayStatement>[])]);
    addTearDown(c.dispose);
    await pumpGolden(t, frame(c, const PayInsightsCard(), dark: true));
    expect(find.text('Pay this year'), findsNothing);
  });

  testWidgets('a statement opens as a waterfall, groups open to their lines, YTD on a toggle', (t) async {
    final c = await demoContainer(demo: false, overrides: [payStatementsProvider.overrideWith((ref) async => stubs)]);
    addTearDown(c.dispose);
    await pumpGolden(t, frame(c, const PayStatementScreen(id: 'a'), dark: true));
    expect(find.text('Medical'), findsNothing);
    await t.tap(find.text('Deductions'));
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('Medical'), findsOneWidget);
    await t.tap(find.text('Year to date'));
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('\$48,000.00 net'), findsOneWidget);
    await expectLater(find.byType(PayStatementScreen), matchesGoldenFile('goldens/pay-statement.png'));
  });

  Map<String, dynamic> previewJson({String? payDate = '2026-11-13', int net = 247707, List<Map<String, dynamic>> problems = const []}) => {
        'source': 'paystub', 'label': 'Pay statement', 'employer': 'ACME ROBOTICS INC', 'pay_date': payDate, 'gross_cents': 373500, 'taxes_cents': 87883, 'deductions_cents': 37910,
        'net_cents': net, 'adds_up': net == 247707, 'new': 1, 'problems': problems,
        'deposits': [{'label': 'Checking', 'mask': '1234', 'cents': 197707}, {'label': 'Savings', 'mask': '5678', 'cents': 50000}],
      };

  testWidgets('the import preview says when it does not add up', (t) async {
    final c = await demoContainer(demo: false);
    addTearDown(c.dispose);
    await pumpGolden(t, frame(c, SingleChildScrollView(child: PaystubPreview(p: ImportPreview.fromJson(previewJson(net: 247607)), busy: false, onImport: (_) {})), dark: true));
    expect(find.textContaining('\$1.00 away from net'), findsOneWidget);
  });

  for (final (w, dark) in [(320.0, true), (430.0, false)]) {
    testWidgets('review: where it went, and nothing to fix sends no fixes ($w ${dark ? 'dark' : 'light'})', (t) async {
      final c = await demoContainer(demo: false);
      addTearDown(c.dispose);
      Map<String, dynamic>? sent;
      await pumpGolden(t, frame(c, SingleChildScrollView(child: PaystubPreview(p: ImportPreview.fromJson(previewJson()), busy: false, onImport: (f) => sent = f)), dark: dark), width: w);
      expect(find.text('Checking ••1234'), findsOneWidget);
      expect(find.text('Something wrong? Fix it'), findsOneWidget);
      await expectLater(find.byType(PaystubPreview), matchesGoldenFile('goldens/paystub-review.${w.toInt()}.${dark ? 'dark' : 'light'}.png'));
      await t.tap(find.text('Save pay statement'));
      expect(sent, isEmpty);
    });

    testWidgets('review: a pay date Tick could not read is asked for by name and sent as a fix ($w ${dark ? 'dark' : 'light'})', (t) async {
      final c = await demoContainer(demo: false);
      addTearDown(c.dispose);
      Map<String, dynamic>? sent;
      final p = ImportPreview.fromJson(previewJson(payDate: null, problems: [{'field': 'pay_date', 'message': 'Tick couldn\'t read the pay date. Enter it to import this.'}]));
      await pumpGolden(t, frame(c, SingleChildScrollView(child: PaystubPreview(p: p, busy: false, onImport: (f) => sent = f)), dark: dark), width: w);
      expect(find.text('Pay date needed'), findsOneWidget);
      expect(find.textContaining('couldn\'t read the pay date'), findsOneWidget);
      await expectLater(find.byType(PaystubPreview), matchesGoldenFile('goldens/paystub-fix.${w.toInt()}.${dark ? 'dark' : 'light'}.png'));
      await t.ensureVisible(find.text('Save pay statement'));
      await t.tap(find.text('Save pay statement'));
      await t.pump();
      expect(sent, isNull);
      expect(find.text('Enter the pay date as MM/DD/YYYY.'), findsOneWidget);
      await t.enterText(find.byType(EditableText).first, '11/13/2026');
      await t.pump();
      await t.ensureVisible(find.text('Save pay statement'));
      await t.tap(find.text('Save pay statement'));
      expect(sent, {'pay_date': '2026-11-13'});
    });
  }

  testWidgets('review at the largest text size, 320 wide', (t) async {
    final c = await demoContainer(demo: false);
    addTearDown(c.dispose);
    final p = ImportPreview.fromJson(previewJson(payDate: null, problems: [{'field': 'pay_date', 'message': 'Tick couldn\'t read the pay date. Enter it to import this.'}]));
    await pumpGolden(t, MediaQuery(data: const MediaQueryData(textScaler: TextScaler.linear(2.0)), child: frame(c, SingleChildScrollView(child: PaystubPreview(p: p, busy: false, onImport: (_) {})), dark: true)), width: 320);
    expect(t.takeException(), isNull);
  });
}
