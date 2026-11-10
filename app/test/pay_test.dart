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

  testWidgets('the import preview says when it does not add up', (t) async {
    final c = await demoContainer(demo: false);
    addTearDown(c.dispose);
    final p = ImportPreview.fromJson({'source': 'paystub', 'label': 'Pay statement', 'employer': 'ACME', 'pay_date': '2026-11-13', 'gross_cents': 100, 'taxes_cents': 10, 'deductions_cents': 10, 'net_cents': 81, 'adds_up': false, 'new': 1});
    await pumpGolden(t, frame(c, SingleChildScrollView(child: PaystubPreview(p: p, busy: false, onImport: () {})), dark: true));
    expect(find.textContaining('don\'t add up'), findsOneWidget);
  });
}
