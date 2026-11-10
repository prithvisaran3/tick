// Labs flags: every shipped idea shows by default and disappears when switched off in Settings.
import 'package:flutter_test/flutter_test.dart';
import 'package:tick/data/settings.dart';
import 'package:tick/features/cards.dart';
import 'package:flutter/widgets.dart';
import 'package:tick/features/safe_card.dart';
import 'golden_harness.dart';

void main() {
  setUpAll(loadFonts);

  testWidgets('Insights: card guard, truly free and what-if follow their flags, inside How it\'s calculated', (tester) async {
    final c = await demoContainer();
    addTearDown(c.dispose);
    await pumpGolden(tester, frame(c, const SingleChildScrollView(child: SafeToSpendCard()), dark: true, tab: 2));
    await tester.tap(find.text('How it\'s calculated'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('before payday'), findsWidgets);
    expect(find.textContaining('every card balance'), findsOneWidget);
    expect(find.text('What if I spend…'), findsOneWidget);
    c.read(settingsProvider.notifier).update((s) => s.copyWith(flagsOff: {'card_guard', 'truly_free', 'what_if'}));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('every card balance'), findsNothing);
    expect(find.text('What if I spend…'), findsNothing);
  });

  testWidgets('Card screen: statement cycle follows its flag', (tester) async {
    final c = await demoContainer();
    addTearDown(c.dispose);
    await pumpGolden(tester, frame(c, const CardScreen(id: 'acc-disc'), dark: false));
    expect(find.text('Statement cycle'), findsOneWidget);
    c.read(settingsProvider.notifier).update((s) => s.copyWith(flagsOff: {'statement_cycle'}));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Statement cycle'), findsNothing);
  });

  test('flags survive a settings round trip and default to on', () {
    const s = AppSettings();
    expect(featureFlags.every((f) => s.flag(f.$1)), isTrue);
    final back = AppSettings.fromJson(s.copyWith(flagsOff: {'what_if'}, hideAmounts: true, lockAfterSeconds: 300).toJson());
    expect(back.flag('what_if'), isFalse);
    expect(back.flag('card_guard'), isTrue);
    expect((back.hideAmounts, back.lockAfterSeconds), (true, 300));
  });
}
