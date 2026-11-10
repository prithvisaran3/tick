import 'package:flutter_test/flutter_test.dart';
import 'package:tick/features/suggested_rules.dart';
import 'golden_harness.dart';

const props = [
  AskProposal(key: 'p:0000000000000001', label: 'Spending by category', questions: ['food last month?', 'Food last month', 'what about food in october'], count: 3),
  AskProposal(key: 'p:0000000000000002', label: 'Total spending for this year', questions: ['rent ytd'], count: 1),
];

void main() {
  setUpAll(loadFonts);

  for (final dark in [true, false]) {
    testWidgets('each proposal says what it would change, with Approve and Dismiss (${dark ? 'dark' : 'light'})', (t) async {
      final c = await demoContainer(demo: false, overrides: [askProposalsProvider.overrideWith((ref) async => props)]);
      addTearDown(c.dispose);
      await pumpGolden(t, frame(c, const SuggestedRulesScreen(), dark: dark), width: 320);
      expect(find.text('When you ask “food last month?”, answer with Spending by category'), findsOneWidget);
      expect(find.text('From 3 thumbs down.'), findsOneWidget);
      expect(find.text('Approve'), findsNWidgets(2));
      expect(find.text('Dismiss'), findsNWidgets(2));
      await expectLater(find.byType(SuggestedRulesScreen), matchesGoldenFile('goldens/suggested-rules.${dark ? 'dark' : 'light'}.png'));
    });
  }

  testWidgets('empty and error states', (t) async {
    final c = await demoContainer(demo: false, overrides: [askProposalsProvider.overrideWith((ref) async => const <AskProposal>[])]);
    addTearDown(c.dispose);
    await pumpGolden(t, frame(c, const SuggestedRulesScreen(), dark: true));
    expect(find.text('Nothing to review'), findsOneWidget);
    final e = await demoContainer(demo: false, overrides: [askProposalsProvider.overrideWith((ref) async => throw Exception('offline'))]);
    addTearDown(e.dispose);
    await pumpGolden(t, frame(e, const SuggestedRulesScreen(), dark: true));
    expect(find.text('Try again'), findsOneWidget);
  });
}
