import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tick/data/settings.dart';
import 'package:tick/design/widgets/core.dart';
import 'package:tick/features/tips.dart';
import 'golden_harness.dart';

Widget nav(Widget child) => Navigator(onGenerateRoute: (_) => PageRouteBuilder<void>(pageBuilder: (_, _, _) => child));

/// A page with the Cash target near the top and the Ask target far below the fold.
Widget page({double gap = 1400}) => TipHost(child: ListView(padding: const EdgeInsets.only(top: 80), children: [
      TipTarget(id: 'home-cash', child: Container(height: 90, margin: const EdgeInsets.symmetric(horizontal: 20), color: const Color(0xFF333333), child: const Text('\$1,840.00'))),
      SizedBox(height: gap),
      const TipTarget(id: 'ask-tick', child: SizedBox(height: 44, width: 44, child: Text('Ask'))),
    ]));

Future<void> settle(WidgetTester t) async { await t.pump(const Duration(milliseconds: 450)); await t.pump(const Duration(milliseconds: 500)); }

void main() {
  setUpAll(loadFonts);

  for (final dark in [true, false]) {
    testWidgets('the first tip points at a visible target (${dark ? 'dark' : 'light'})', (t) async {
      final c = await demoContainer();
      addTearDown(c.dispose);
      await pumpGolden(t, frame(c, nav(page()), dark: dark));
      await settle(t);
      expect(find.text('Tap to see every account'), findsOneWidget);
      expect(find.text('Skip tips'), findsOneWidget);
      await expectLater(find.byType(TipHost), matchesGoldenFile('goldens/tip-home.${dark ? 'dark' : 'light'}.png'));
    });
  }

  testWidgets('taps pass through to the target and count as seeing the tip', (t) async {
    final c = await demoContainer();
    addTearDown(c.dispose);
    var tapped = 0;
    await pumpGolden(t, frame(c, nav(TipHost(child: Center(child: TipTarget(id: 'home-cash', child: Pressable(onTap: () => tapped++, child: const SizedBox(width: 200, height: 80, child: Text('Cash'))))))), dark: true));
    await settle(t);
    expect(find.text('Tap to see every account'), findsOneWidget);
    await t.tap(find.text('Cash'));
    await settle(t);
    expect(tapped, 1);
    expect(c.read(settingsProvider).tipsDone, ['home-cash']);
    expect(find.text('Tap to see every account'), findsNothing);
  });

  testWidgets('Got it moves on; the next tip waits until its target is on screen', (t) async {
    final c = await demoContainer();
    addTearDown(c.dispose);
    await pumpGolden(t, frame(c, nav(page()), dark: true));
    await settle(t);
    await t.tap(find.text('Got it'));
    await settle(t);
    expect(find.text('Ask Tick anything about your money'), findsNothing);      // below the fold
    await t.drag(find.byType(ListView), const Offset(0, -1500));
    await settle(t);
    expect(find.text('Ask Tick anything about your money'), findsOneWidget);
  });

  testWidgets('Skip tips ends all four', (t) async {
    final c = await demoContainer();
    addTearDown(c.dispose);
    await pumpGolden(t, frame(c, nav(page(gap: 10)), dark: true));
    await settle(t);
    await t.tap(find.text('Skip tips'));
    await settle(t);
    expect(c.read(settingsProvider).tipsDone.toSet(), tipOrder.toSet());
    expect(find.text('Skip tips'), findsNothing);
  });

  testWidgets('a target under a sheet gets no tip; Show tips again brings them back', (t) async {
    final c = await demoContainer();
    addTearDown(c.dispose);
    await pumpGolden(t, frame(c, nav(page()), dark: true));
    final ctx = t.element(find.text('\$1,840.00'));
    Navigator.of(ctx).push(PageRouteBuilder<void>(opaque: false, pageBuilder: (_, _, _) => const Align(alignment: Alignment.bottomCenter, child: SizedBox(height: 200, child: Text('Sheet')))));
    await settle(t);
    expect(find.text('Tap to see every account'), findsNothing);
    Navigator.of(ctx).pop();
    await settle(t);
    expect(find.text('Tap to see every account'), findsOneWidget);
    c.read(settingsProvider.notifier).update((s) => s.copyWith(tipsDone: tipOrder));
    await settle(t);
    expect(find.text('Tap to see every account'), findsNothing);
    c.read(settingsProvider.notifier).resetTips();
    await settle(t);
    expect(find.text('Tap to see every account'), findsOneWidget);
  });

  testWidgets('mostly off screen is not visible enough', (t) async {
    final c = await demoContainer();
    addTearDown(c.dispose);
    await pumpGolden(t, frame(c, nav(TipHost(child: Stack(children: [Positioned(left: 0, right: 0, top: -60, child: TipTarget(id: 'home-cash', child: Container(height: 100, color: const Color(0xFF333333))))]))), dark: true));
    await settle(t);
    expect(find.text('Tap to see every account'), findsNothing);
  });

  testWidgets('largest text and Reduce Motion at 320', (t) async {
    final c = await demoContainer();
    addTearDown(c.dispose);
    await pumpGolden(t, MediaQuery(data: const MediaQueryData(textScaler: TextScaler.linear(2.0), disableAnimations: true), child: frame(c, nav(page()), dark: true)), width: 320);
    await settle(t);
    expect(find.text('Tap to see every account'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
