import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tick/data/ledger.dart';
import 'package:tick/data/paybacks.dart';
import 'package:tick/data/review_snooze.dart';
import 'package:tick/data/settings.dart';
import 'package:tick/features/review.dart';
import 'package:tick/features/rule_cards.dart';
import 'golden_harness.dart';

final day = DateTime(2026, 11, 9, 12);
final balances = [BalanceMatch(paybackId: 'p1', amountCents: 4000, groupId: 'g', groupName: 'Flat', memberId: 'm', name: 'Asha Rao', leftCents: 0, date: DateTime(2026, 11, 7))];
final paybacks = [PaybackSuggestion(paybackId: 'p2', amountCents: 3000, from: 'Jo Lee', date: DateTime(2026, 11, 8),
    candidates: [PaybackCandidate(purchaseId: 'x', merchant: 'Dishoom', amountCents: 9000, leftCents: 9000, date: DateTime(2026, 11, 6))])];
final rules = [const RuleSuggestion('kaarthik', 'Kaarthik R', 120000, 1)];

List<Override> sources() => [
      balanceMatchesProvider.overrideWith((ref) async => balances),
      paybackSuggestionsProvider.overrideWith((ref) async => paybacks),
      landedSettlementsProvider.overrideWith((ref) async => const <LandedSettlement>[]),
      ruleSuggestionsProvider.overrideWith((ref) async => rules),
      likelySplitwiseProvider.overrideWith((ref) async => const [LikelySplitwise('s1', 'Zelle with Asha', 2500, confidence: 0.8)]),
    ];

/// The harness has no Navigator; sheets and toasts need one.
Widget nav(Widget child) => Navigator(onGenerateRoute: (_) => PageRouteBuilder<void>(pageBuilder: (_, _, _) => child));

void main() {
  setUpAll(loadFonts);

  test('Not sure: gone for 7 days, back once as Still unsure, then gone for good', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    var now = day;
    final c = ProviderContainer(overrides: [sharedPrefsProvider.overrideWithValue(prefs), clockProvider.overrideWithValue(() => now)]);
    addTearDown(c.dispose);
    final n = c.read(reviewSnoozesProvider.notifier);
    expect(snoozeState(c.read(reviewSnoozesProvider)['k'], now), SnoozeState.fresh);
    n.notSure('k');
    expect(snoozeState(c.read(reviewSnoozesProvider)['k'], now.add(const Duration(days: 6))), SnoozeState.hidden);
    now = now.add(const Duration(days: 7, minutes: 1));
    expect(snoozeState(c.read(reviewSnoozesProvider)['k'], now), SnoozeState.stillUnsure);
    n.notSure('k');
    expect(snoozeState(c.read(reviewSnoozesProvider)['k'], now.add(const Duration(days: 400))), SnoozeState.hidden);
    // kept on the phone only, across restarts
    final c2 = ProviderContainer(overrides: [sharedPrefsProvider.overrideWithValue(prefs), clockProvider.overrideWithValue(() => now)]);
    addTearDown(c2.dispose);
    expect(c2.read(reviewSnoozesProvider)['k']!.times, 2);
  });

  testWidgets('Activity shows one question and how many more; most sure first', (t) async {
    final c = await demoContainer(demo: false, now: day, overrides: sources());
    addTearDown(c.dispose);
    await pumpGolden(t, frame(c, const SingleChildScrollView(child: ReviewDeck()), dark: true), width: 320);
    expect(find.text('Mark Asha as settled?'), findsOneWidget);
    expect(find.text('Payback for Dishoom?'), findsNothing);
    expect(find.text('3 more to review  ›'), findsOneWidget);
    expect(find.text('Not sure'), findsOneWidget);
  });

  for (final dark in [true, false]) {
    testWidgets('tapping the card opens why, the rows, each answer\'s effect and how sure (${dark ? 'dark' : 'light'})', (t) async {
      final c = await demoContainer(demo: false, now: day, overrides: sources());
      addTearDown(c.dispose);
      await pumpGolden(t, frame(c, nav(const SingleChildScrollView(child: ReviewDeck())), dark: dark), width: 320);
      await t.tap(find.text('Mark Asha as settled?'));
      await t.pumpAndSettle();
      expect(find.text('Very likely'), findsOneWidget);
      expect(find.textContaining('owed you \$40.00 in Flat'), findsOneWidget);
      expect(find.text('If you say Mark settled'), findsOneWidget);
      expect(find.text('If you say Not this'), findsOneWidget);
      expect(find.text('If you\'re not sure'), findsOneWidget);
      expect(find.textContaining('Nothing is learned'), findsOneWidget);
      await expectLater(find.byType(Navigator).first, matchesGoldenFile('goldens/review-sheet.${dark ? 'dark' : 'light'}.png'));
      await t.pump(const Duration(seconds: 6));
    });
  }

  testWidgets('Not sure hides it locally and the next question takes its place', (t) async {
    final c = await demoContainer(demo: false, now: day, overrides: sources());
    addTearDown(c.dispose);
    await pumpGolden(t, frame(c, nav(const SingleChildScrollView(child: ReviewDeck())), dark: true));
    await t.tap(find.text('Not sure'));
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('Mark Asha as settled?'), findsNothing);
    expect(find.text('Is Zelle with Asha Splitwise?'), findsOneWidget);
    expect(find.text('Tick will ask again in 7 days'), findsOneWidget);
    await t.pump(const Duration(seconds: 6));
  });

  testWidgets('the rent question offers Other bill in its sheet', (t) async {
    final c = await demoContainer(demo: false, now: day, overrides: sources());
    addTearDown(c.dispose);
    await c.read(ruleSuggestionsProvider.future);
    final rent = c.read(reviewQuestionsProvider).firstWhere((q) => q.kind == 'Rent');
    expect(rent.question, 'Rent to Kaarthik, \$1,200 monthly?');
    expect(rent.extra.single.label, 'Other bill');
    expect(rent.line, 'Around the 1st each month.');
  });

  testWidgets('the queue pages through every question', (t) async {
    final c = await demoContainer(demo: false, now: day, overrides: sources());
    addTearDown(c.dispose);
    await pumpGolden(t, frame(c, const ReviewQueueScreen(), dark: true));
    expect(find.text('1 of 4'), findsOneWidget);
    await t.drag(find.byType(PageView), const Offset(-300, 0));
    await t.pumpAndSettle();
    expect(find.text('2 of 4'), findsOneWidget);
  });

  testWidgets('nothing to ask, nothing shown; the queue says all reviewed', (t) async {
    final c = await demoContainer(demo: false, now: day);
    addTearDown(c.dispose);
    await pumpGolden(t, frame(c, const Column(children: [ReviewDeck(), Expanded(child: ReviewQueueScreen())]), dark: true));
    expect(find.text('All reviewed'), findsOneWidget);
  });

  testWidgets('largest text at 320 fits', (t) async {
    final c = await demoContainer(demo: false, now: day, overrides: sources());
    addTearDown(c.dispose);
    await pumpGolden(t, MediaQuery(data: const MediaQueryData(textScaler: TextScaler.linear(2.0)), child: frame(c, const SingleChildScrollView(child: ReviewDeck()), dark: true)), width: 320);
    expect(t.takeException(), isNull);
  });
}
