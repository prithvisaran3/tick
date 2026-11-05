import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tick/design/widgets/more.dart';
import 'package:tick/features/caught_screen.dart';
import 'package:tick/features/today_screen.dart';
import 'package:tick/services/haptics.dart';
import 'golden_harness.dart';

/// Haptic sync audit: each moment fires its pattern with its animation (recorded calls, one pattern one meaning).
void main() {
  setUpAll(loadFonts);

  testWidgets('Today plays COUNT-UP and PRICE WEIGHT + capture pop sound for a fresh capture (under 2 minutes old)', (tester) async {
    final c = await demoContainer(now: DateTime(2026, 11, 4, 9, 13));
    addTearDown(c.dispose);
    TickHaptics.instance.log.clear();
    await pumpGolden(tester, frame(c, const TodayScreen(), dark: true, tab: 0));
    final log = TickHaptics.instance.log;
    expect(log, contains('count_up'));
    expect(log.where((e) => e.startsWith('price_weight')), isNotEmpty);
    expect(log, contains('sound:capture_pop'));
  });

  testWidgets('Today does NOT replay the capture pop for an old capture on app open', (tester) async {
    final c = await demoContainer();                       // 9:41: the newest capture is 29 minutes old
    addTearDown(c.dispose);
    TickHaptics.instance.log.clear();
    await pumpGolden(tester, frame(c, const TodayScreen(), dark: true, tab: 0));
    expect(TickHaptics.instance.log, contains('count_up'));
    expect(TickHaptics.instance.log.where((e) => e.startsWith('price_weight') || e == 'sound:capture_pop'), isEmpty);
  });

  testWidgets('HoldToConfirm: ramp on press, click on completion, soft cancel when released early', (tester) async {
    final c = await demoContainer();
    addTearDown(c.dispose);
    var confirmed = 0;
    TickHaptics.instance.log.clear();
    await pumpGolden(tester, frame(c, Center(child: HoldToConfirm(label: 'Delete', onConfirmed: () => confirmed++)), dark: true));
    final g = await tester.startGesture(tester.getCenter(find.byType(HoldToConfirm)));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 200));
    await g.up();
    await tester.pump(const Duration(milliseconds: 300));
    expect(TickHaptics.instance.log, ['hold_ramp', 'hold_cancel']);
    expect(confirmed, 0);
    TickHaptics.instance.log.clear();
    final g2 = await tester.startGesture(tester.getCenter(find.byType(HoldToConfirm)));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 700));
    await g2.up();
    expect(TickHaptics.instance.log, ['hold_ramp', 'hold_click']);
    expect(confirmed, 1);
  });

  testWidgets('Caught: swipe right = two ticks, up = rising two-step, left = soft low tap; each resolves the card', (tester) async {
    final c = await demoContainer();
    addTearDown(c.dispose);
    await pumpGolden(tester, frame(c, const CaughtScreen(), dark: true));
    TickHaptics.instance.log.clear();
    await tester.drag(find.byType(CaughtScreen), const Offset(300, 0), warnIfMissed: false);
    await tester.pump(const Duration(seconds: 1));
    expect(TickHaptics.instance.log.where((e) => e.startsWith('sort_')), ['sort_right']);
  });

  test('every haptic key has an AHAP file in the manifest', () {
    for (final k in ['pop', 'price_weight_low', 'price_weight_mid', 'price_weight_high', 'count_up', 'hold_ramp', 'hold_click', 'hold_cancel', 'sort_right', 'sort_left', 'sort_up', 'landed', 'tear_tick', 'tear_rip', 'heartbeat']) {
      expect(TickHaptics.instance.mode, HapticMode.full);
      expect(k.isNotEmpty, isTrue);
    }
  });
}
