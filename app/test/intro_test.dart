import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tick/design/motion.g.dart';
import 'package:tick/design/tokens.g.dart';
import 'package:tick/design/widgets/splash.dart';
import 'package:tick/features/intro_cinematic.dart';
import 'package:tick/services/haptics.dart';
import 'golden_harness.dart';

void main() {
  setUpAll(loadFonts);

  Future<void> host(WidgetTester t, Widget w, {double width = 393, double height = 852, double scale = 1, bool reduce = false}) async {
    final c = await demoContainer(demo: false);
    addTearDown(c.dispose);
    t.view.physicalSize = Size(width, height);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    t.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    if (reduce) { t.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true); addTearDown(t.platformDispatcher.clearAccessibilityFeaturesTestValue); }
    await t.pumpWidget(frame(c, w, dark: true));
    await t.pump();
  }

  testWidgets('five scenes play on their own, then Make it yours, and it stops there', (t) async {
    await host(t, IntroCinematic(onDone: (_, _) {}));
    expect(find.text(introScenes.first.$1), findsOneWidget);
    for (var i = 1; i < introScenes.length; i++) {
      await t.pump(const Duration(milliseconds: TickMotion.sceneMs + 50));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text(introScenes[i].$1), findsOneWidget);
    }
    await t.pump(const Duration(milliseconds: TickMotion.sceneMs + 50));
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('Make it yours.'), findsOneWidget);
    expect(find.text('Next paydays'), findsOneWidget);
  });

  testWidgets('tap advances, Skip goes to setup, and a choice comes back', (t) async {
    String? after;
    await host(t, IntroCinematic(onDone: (_, a) => after = a));
    await t.tapAt(const Offset(200, 300));
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text(introScenes[1].$1), findsOneWidget);
    await t.tap(find.text('Skip'));
    await t.pump(const Duration(milliseconds: 400));
    await t.tap(find.text('Import a statement'));
    expect(after, 'import');
  });

  testWidgets('each scene has its own haptic', (t) async {
    TickHaptics.instance.log.clear();
    await host(t, IntroCinematic(onDone: (_, _) {}));
    await t.pump(const Duration(milliseconds: 10));
    expect(TickHaptics.instance.log, contains('intro_stream'));
    await t.tapAt(const Offset(200, 300));
    await t.pump(const Duration(milliseconds: 10));
    expect(TickHaptics.instance.log, contains('intro_count'));
    await t.pump(const Duration(seconds: 1));
  });

  for (final (w, s) in [(320.0, 1.0), (320.0, 2.35), (430.0, 1.6)]) {
    testWidgets('no scene overflows at ${w}pt, text x$s', (t) async {
      await host(t, IntroCinematic(onDone: (_, _) {}), width: w, height: w < 350 ? 568 : 932, scale: s);
      for (var i = 0; i < introScenes.length; i++) {
        for (var k = 0; k < 6; k++) { await t.pump(const Duration(milliseconds: TickMotion.sceneMs ~/ 7)); expect(t.takeException(), isNull); }
        await t.tapAt(const Offset(150, 300));
        await t.pump(const Duration(milliseconds: 400));
      }
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('Reduce Motion: the same words on a finished frame', (t) async {
    await host(t, IntroCinematic(onDone: (_, _) {}), reduce: true);
    expect(find.text('\$214'), findsOneWidget);
    expect(find.text(introScenes.first.$1), findsOneWidget);
    await t.pump(const Duration(seconds: 6));
    await t.pump(const Duration(milliseconds: 400));
  });

  testWidgets('splash ends within budget, plays one haptic, and a tap skips it', (t) async {
    TickHaptics.instance.log.clear();
    await host(t, const TickSplash(child: Text('app')));
    expect(find.text('tıck'), findsOneWidget);
    await t.pump(const Duration(milliseconds: TickMotion.splashTotalMs + 20));
    await t.pump();
    expect(find.text('tıck'), findsNothing);
    expect(TickHaptics.instance.log.where((k) => k == 'splash').length, 1);
    await host(t, const TickSplash(key: ValueKey('b'), child: Text('app')));
    await t.tapAt(const Offset(100, 100));
    await t.pump();
    expect(find.text('tıck'), findsNothing);
  });

  testWidgets('the native launch image is this widget, on Ink', (t) async {
    t.view.physicalSize = const Size(LaunchMark.width * 3, LaunchMark.height * 3);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(const Directionality(textDirection: TextDirection.ltr, child: RepaintBoundary(child: ColoredBox(color: TickPalette.ink, child: FittedBox(child: SizedBox(width: LaunchMark.width, height: LaunchMark.height, child: LaunchMark()))))));
    await expectLater(find.byType(RepaintBoundary).first, matchesGoldenFile('../ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage@3x.png'));
  });
}
