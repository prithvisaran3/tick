import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tick/data/activity.dart';
import 'package:tick/data/ledger.dart';
import 'package:tick/domain/models.dart';
import 'package:tick/features/activity_screen.dart';
import 'package:tick/services/haptics.dart';
import 'golden_harness.dart';

List<Txn> bigLedger(int n) => [
      for (var i = 0; i < n; i++)
        Txn(id: 'r${i.toString().padLeft(5, '0')}', amountCents: -(100 + i % 900), merchant: i % 7 == 0 ? 'ZELLE PAYMENT TO FRIEND $i' : 'Merchant ${i % 40}', categoryId: 'cat-groceries',
            accountId: i % 2 == 0 ? 'acc-chk' : 'acc-disc', occurredAt: DateTime(2026, 11, 4, 12).subtract(Duration(hours: i * 7))),
    ];

void main() {
  setUpAll(loadFonts);

  testWidgets('one continuous list: month headers carry that month\'s totals and the list pages in as you scroll (5,000 rows, no exceptions)', (tester) async {
    final big = bigLedger(5000);
    final c = await demoContainer(overrides: [
      activitySourceProvider.overrideWith((ref) => LocalActivitySource(LedgerState(categories: ref.read(ledgerProvider).categories, accounts: ref.read(ledgerProvider).accounts, txns: big))),
    ]);
    addTearDown(c.dispose);
    await pumpGolden(tester, frame(c, const ActivityScreen(), dark: true, tab: 1));
    expect(find.text('November 2026'), findsOneWidget);
    expect(find.textContaining('Out \$'), findsWidgets);                         // the month header shows in / out / net
    final before = c.read(activityProvider).rows.length;
    expect(before, 40);                                                           // the first page is 40 rows
    for (var i = 0; i < 25; i++) {
      await tester.drag(find.byType(CustomScrollView).first, const Offset(0, -900));
      await tester.pump(const Duration(milliseconds: 80));
    }
    expect(c.read(activityProvider).rows.length, greaterThan(before));          // prefetch kept ahead of the scroll
    expect(find.text('November 2026'), findsNothing);                             // November's header scrolled away...
    expect(find.byWidgetPredicate((w) => w is Text && RegExp(r'^[A-Z][a-z]+ 20\d\d$').hasMatch(w.data ?? '')), findsOneWidget);   // ...and an earlier month's header took over
    expect(TickHaptics.instance.log, contains('selection'));                     // and ticked lightly as it did
    expect(tester.takeException(), isNull);
  });

  testWidgets('the filter button shows how many filters are active and a removable pill appears only then', (tester) async {
    final c = await demoContainer();
    addTearDown(c.dispose);
    await pumpGolden(tester, frame(c, const ActivityScreen(), dark: false, tab: 1));
    expect(find.text('Credit cards'), findsNothing);
    await c.read(activityProvider.notifier).setQuery(const ActivityQuery(types: {'credit'}, review: true));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('2'), findsOneWidget);                                       // the badge on the filter button
    expect(find.text('Credit cards'), findsOneWidget);
    expect(find.text('Needs review'), findsOneWidget);
    await tester.tap(find.text('Credit cards'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.read(activityProvider).query.types, isEmpty);
    expect(find.text('Credit cards'), findsNothing);
  });

  testWidgets('a row swipes open to Categorise, Split and Reviewed without ever removing it', (tester) async {
    final c = await demoContainer();
    addTearDown(c.dispose);
    await pumpGolden(tester, frame(c, const ActivityScreen(), dark: true, tab: 1));
    final row = find.text('Uber').first;
    await tester.drag(row, const Offset(-300, 0));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Categorise'), findsOneWidget);
    expect(find.text('Split'), findsOneWidget);
    expect(find.text('Reviewed'), findsOneWidget);                                // Uber is flagged "needs review" in the demo
    expect(find.text('Uber'), findsWidgets);
    expect(TickHaptics.instance.log, contains('sort_left'));
  });
}
