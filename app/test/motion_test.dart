import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tick/design/motion.g.dart';
import 'package:tick/design/widgets/core.dart';
import 'package:tick/design/widgets/motion.dart';
import 'package:tick/design/widgets/more.dart';
import 'package:tick/design/widgets/swipe.dart';
import 'package:tick/features/common.dart';
import 'package:tick/services/haptics.dart';
import 'package:tick/features/tally_more.dart';
import 'golden_harness.dart';

Widget host(Widget w, {bool reduce = false}) => MediaQuery(data: MediaQueryData(disableAnimations: reduce), child: Directionality(textDirection: TextDirection.ltr, child: w));

void main() {
  Widget roll(int v, {bool reduce = false}) => host(RollingNumber(value: v, builder: (_, n) => Text('$n')), reduce: reduce);

  testWidgets('a number rolls through values and lands exactly, never past the target', (tester) async {
    await tester.pumpWidget(roll(1000));
    expect(find.text('1000'), findsOneWidget);
    await tester.pumpWidget(roll(5000));
    final seen = <int>[];
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      seen.add(int.parse(tester.widget<Text>(find.byType(Text)).data!));
    }
    expect(seen.any((v) => v > 1000 && v < 5000), isTrue);
    expect(seen.every((v) => v >= 1000 && v <= 5000), isTrue);
    expect(seen.last, 5000);
  });

  testWidgets('Reduce Motion never shows a value in between', (tester) async {
    await tester.pumpWidget(roll(1000, reduce: true));
    await tester.pumpWidget(roll(5000, reduce: true));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      for (final t in tester.widgetList<Text>(find.byType(Text))) { expect(['1000', '5000'], contains(t.data)); }
    }
    expect(find.text('5000'), findsOneWidget);
  });

  testWidgets('a list staggers the first time only', (tester) async {
    Widget list() => host(Column(children: [for (var i = 0; i < 3; i++) StaggerIn(scope: 'once', index: i, child: Text('r$i'))]));
    List<double> ops() => [for (final o in tester.widgetList<Opacity>(find.byType(Opacity))) o.opacity];
    await tester.pumpWidget(list());
    await tester.pump();
    expect(ops().first, lessThan(1));
    await tester.pumpAndSettle();
    expect(ops(), [1, 1, 1]);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(list());
    expect(ops(), [1, 1, 1]);
  });

  testWidgets('Reduce Motion: the entrance only fades', (tester) async {
    await tester.pumpWidget(host(StaggerIn(scope: 'still', index: 0, child: const Text('r')), reduce: true));
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, lessThan(1));
    expect(tester.widget<Transform>(find.byType(Transform)).transform.getTranslation().y, 0);
    await tester.pumpAndSettle();
  });

  testWidgets('Hero flights are off under Reduce Motion', (tester) async {
    await tester.pumpWidget(host(const TickHero(tag: 'x', child: SizedBox()), reduce: true));
    expect(find.byType(Hero), findsNothing);
    await tester.pumpWidget(host(const TickHero(tag: 'x', child: SizedBox())));
    expect(find.byType(Hero), findsOneWidget);
  });

  test('the spring curve starts at 0 and lands at 1', () {
    const c = SpringCurve(TickSprings.sheet);
    expect(c.transform(0), 0);
    expect(c.transform(1), 1);
    expect(c.transform(0.5), greaterThan(0.5));
  });

  testWidgets('swiping fires the threshold once per drag', (tester) async {
    await loadFonts();
    final c = await demoContainer(demo: false);
    addTearDown(c.dispose);
    var hits = 0;
    await tester.pumpWidget(frame(c, SizedBox(width: 300, height: 60, child: SwipeActions(onThreshold: () => hits++, actions: [SwipeAction('Edit', 'edit', () {}), SwipeAction('Delete', 'trash', () {})], child: const SizedBox(width: 300, height: 60, child: Text('row')))), dark: true));
    final g = await tester.startGesture(tester.getCenter(find.text('row')));
    for (var i = 0; i < 12; i++) { await g.moveBy(const Offset(-12, 0)); await tester.pump(); }
    await g.up();
    await tester.pumpAndSettle();
    expect(hits, 1);
  });

  testWidgets('settled up shows, then hands back', (tester) async {
    await loadFonts();
    final c = await demoContainer(demo: false);
    addTearDown(c.dispose);
    var done = false;
    await tester.pumpWidget(frame(c, SettledLine(name: 'Jo', onDone: () => done = true), dark: true));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Settled up'), findsOneWidget);
    expect(done, isFalse);
    await tester.pump(const Duration(milliseconds: TickMotion.settledHoldMs));
    expect(done, isTrue);
    await tester.pumpAndSettle();
    expect(find.byType(TickIcon), findsOneWidget);
  });

  testWidgets('toggles, segmented controls and keypad keys click', (tester) async {
    await loadFonts();
    final c = await demoContainer(demo: false);
    addTearDown(c.dispose);
    TickHaptics.instance.log.clear();
    await tester.pumpWidget(frame(c, Column(children: [TickToggle(on: false, onChanged: (_) {}), Segmented(options: const ['A', 'B'], index: 0, onChanged: (_) {}), NumberPad(onKey: (_) {})]), dark: true));
    await tester.tap(find.byType(TickToggle)); await tester.tap(find.text('B')); await tester.tap(find.text('7'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(TickHaptics.instance.log.where((k) => k == 'selection').length, 3);
  });

  testWidgets('keypad digits roll in and read as the whole amount', (tester) async {
    await loadFonts();
    final c = await demoContainer(demo: false);
    addTearDown(c.dispose);
    Widget w(String v) => frame(c, RollingDigits(v, style: const TextStyle(fontSize: 20)), dark: true);
    await tester.pumpWidget(w(r'$4'));
    await tester.pumpWidget(w(r'$42'));
    await tester.pump(const Duration(milliseconds: TickMotion.digitMs + 20));
    expect(find.text('2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an error state buzzes once', (tester) async {
    await loadFonts();
    final c = await demoContainer(demo: false);
    addTearDown(c.dispose);
    TickHaptics.instance.log.clear();
    await tester.pumpWidget(frame(c, ErrorState(onRetry: () async {}), dark: true));
    await tester.pump();
    expect(TickHaptics.instance.log.where((k) => k == 'warning').length, 1);
  });

  testWidgets('a held card tilts, and flat under Reduce Motion', (tester) async {
    await loadFonts();
    final c = await demoContainer(demo: false);
    addTearDown(c.dispose);
    await tester.pumpWidget(frame(c, Center(child: SizedBox(width: 200, height: 100, child: TickCard(onTap: () {}, child: const Text('card')))), dark: true));
    final g = await tester.startGesture(tester.getTopLeft(find.text('card')));
    await tester.pump(const Duration(milliseconds: 600));
    final m = tester.widgetList<Transform>(find.byType(Transform)).first.transform;
    expect(m.isIdentity(), isFalse);
    await g.up();
    await tester.pumpAndSettle();
  });
}
