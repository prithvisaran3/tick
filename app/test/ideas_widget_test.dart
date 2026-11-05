// Labs flags: every shipped idea shows by default and disappears when switched off in Settings.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tick/data/settings.dart';
import 'package:tick/features/cards.dart';
import 'package:tick/features/today_screen.dart';
import 'golden_harness.dart';

void main() {
  setUpAll(loadFonts);

  testWidgets('Today: card guard, truly free and what-if follow their flags', (tester) async {
    final c = await demoContainer();
    addTearDown(c.dispose);
    await pumpGolden(tester, frame(c, const TodayScreen(), dark: true, tab: 0));
    expect(find.text('Cards before payday'), findsOneWidget);
    expect(find.textContaining('every card balance'), findsOneWidget);
    expect(find.text('What if…'), findsOneWidget);
    c.read(settingsProvider.notifier).update((s) => s.copyWith(flagsOff: {'card_guard', 'truly_free', 'what_if'}));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Cards before payday'), findsNothing);
    expect(find.textContaining('every card balance'), findsNothing);
    expect(find.text('What if…'), findsNothing);
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
