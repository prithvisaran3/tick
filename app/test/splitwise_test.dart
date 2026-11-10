import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tick/data/splitwise.dart';
import 'package:tick/domain/models.dart';
import 'package:tick/features/splitwise_detail.dart';
import 'golden_harness.dart';

final zelle = Txn(id: 'z1', amountCents: -5000, occurredAt: DateTime(2026, 10, 10, 12), merchant: 'Zelle payment to ASHA RAO', categoryId: 'cat-splitwise');
final card = Txn(id: 'c1', amountCents: -9000, occurredAt: DateTime(2026, 10, 10, 12), merchant: 'Dishoom', categoryId: 'cat-splitwise');

SplitwiseExplain explained({bool gmail = false}) => SplitwiseExplain.fromJson({
      'gmail_connected': gmail, 'tag': 'Flat', 'more': 1,
      'best': {'source': 'balance', 'ref': 'bal:g1:asha rao', 'label': 'You owed Asha', 'where': 'Flat', 'cents': 5000, 'date': null, 'confidence': 0.85},
      'could_settle': {'person': 'Asha Rao', 'exact': true, 'total_cents': 5000, 'items': [
        {'id': 'b', 'label': 'Dinner', 'group_name': 'Flat', 'cents': 3000, 'date': '2026-10-05'},
        {'id': 'a', 'label': 'Wi-Fi', 'group_name': 'Flat', 'cents': 2000, 'date': '2026-10-01'},
      ]},
    });

void main() {
  setUpAll(loadFonts);

  test('confidence reads as words', () {
    SplitwiseGuess g(double c) => SplitwiseGuess(source: 'tally', ref: 'x', label: 'x', where: '', cents: 1, confidence: c);
    expect([g(0.92).confidenceLabel, g(0.7).confidenceLabel, g(0.5).confidenceLabel], ['Very likely', 'Likely', 'Maybe']);
  });

  test('it shows on Splitwise rows and on payments to friends, not on transfers', () {
    const sw = Category(id: 'cat-splitwise', name: 'Splitwise', colorKey: 'shop', icon: 'tally');
    const ff = Category(id: 'cat-friends', name: 'Friends and family', colorKey: 'shop', icon: 'arrow-out');
    const food = Category(id: 'cat-food', name: 'Restaurants', colorKey: 'shop', icon: 'card');
    expect(SplitwiseDetail.appliesTo(card, sw), isTrue);
    expect(SplitwiseDetail.appliesTo(zelle, ff), isTrue);
    expect(SplitwiseDetail.appliesTo(card, ff), isFalse);
    expect(SplitwiseDetail.appliesTo(card, food), isFalse);
  });

  for (final dark in [true, false]) {
    testWidgets('a Zelle to a friend: most likely, how sure, and what it settles (${dark ? 'dark' : 'light'})', (t) async {
      final c = await demoContainer(demo: false, overrides: [splitwiseExplainProvider(zelle.id).overrideWith((ref) async => explained())]);
      addTearDown(c.dispose);
      await pumpGolden(t, frame(c, SingleChildScrollView(child: SplitwiseDetail(t: zelle)), dark: dark), width: 320);
      expect(find.text('You owed Asha · \$50.00'), findsOneWidget);
      expect(find.text('Very likely'), findsOneWidget);
      expect(find.text('Not this one'), findsOneWidget);
      expect(find.text('1 more'), findsOneWidget);
      expect(find.text('Settles these with Asha'), findsOneWidget);
      expect(find.text('Dinner'), findsOneWidget);
      expect(find.textContaining('Connect Gmail'), findsOneWidget);
      await expectLater(find.byType(SplitwiseDetail), matchesGoldenFile('goldens/splitwise-detail.${dark ? 'dark' : 'light'}.png'));
    });
  }

  testWidgets('with Gmail connected the line is gone; no match says so', (t) async {
    final c = await demoContainer(demo: false, overrides: [splitwiseExplainProvider(card.id).overrideWith((ref) async => const SplitwiseExplain(gmailConnected: true))]);
    addTearDown(c.dispose);
    await pumpGolden(t, frame(c, SplitwiseDetail(t: card), dark: true));
    expect(find.text('No match yet'), findsOneWidget);
    expect(find.textContaining('Connect Gmail'), findsNothing);
  });

  testWidgets('an error gives a reason and Try again', (t) async {
    final c = await demoContainer(demo: false, overrides: [splitwiseExplainProvider(card.id).overrideWith((ref) async => throw Exception('offline'))]);
    addTearDown(c.dispose);
    await pumpGolden(t, frame(c, SplitwiseDetail(t: card), dark: true));
    expect(find.text('The match didn\'t load'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('largest text fits at 320', (t) async {
    final c = await demoContainer(demo: false, overrides: [splitwiseExplainProvider(zelle.id).overrideWith((ref) async => explained())]);
    addTearDown(c.dispose);
    await pumpGolden(t, MediaQuery(data: const MediaQueryData(textScaler: TextScaler.linear(2.0)), child: frame(c, SingleChildScrollView(child: SplitwiseDetail(t: zelle)), dark: true)), width: 320);
    expect(t.takeException(), isNull);
  });
}
