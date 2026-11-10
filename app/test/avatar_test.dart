import 'dart:math';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tick/design/avatar.g.dart';
import 'package:tick/design/widgets/avatar.dart';
import 'package:tick/domain/tally.dart';
import 'package:tick/features/avatar_builder.dart';
import 'package:tick/services/haptics.dart';
import 'golden_harness.dart';

void main() {
  setUpAll(loadFonts);

  test('the same id always draws the same face, and ids differ', () {
    expect(AvatarSpec.fromSeed('abc').v, AvatarSpec.fromSeed('abc').v);
    final all = {for (var i = 0; i < 40; i++) AvatarSpec.fromSeed('user-$i').v.toString()};
    expect(all.length, greaterThan(35));
  });

  test('saved choices win, bad values fall back, and every value is in range', () {
    final s = AvatarSpec.parse({'hair': 3, 'nonsense': 9, 'eyes': 'x'}, 'seed');
    expect(s.of('hair'), 3);
    expect(s.v.containsKey('nonsense'), isFalse);
    for (var i = 0; i < 50; i++) {
      final r = AvatarSpec.random(Random(i));
      for (final e in TickAvatarPalette.options.entries) { expect(r.of(e.key), lessThan(e.value)); }
    }
    expect({for (final (_, ls) in avatarCategories) for (final (k, _) in ls) k}, TickAvatarPalette.options.keys.toSet());   // the studio reaches every layer
  });

  test('a face saved before v2 keeps every choice and gets the plain option for each new layer', () {
    final old = AvatarSpec.parse({'face': 1, 'skin': 4, 'hair': 5, 'hairColor': 2, 'eyes': 2, 'brows': 1, 'mouth': 3, 'glasses': 2, 'hat': 3, 'beard': 1, 'background': 5}, 'someone');
    expect([old.of('face'), old.of('skin'), old.of('hair'), old.of('hat'), old.of('background')], [1, 4, 5, 3, 5]);
    expect([old.of('cloth'), old.of('earrings'), old.of('mark')], [0, 0, 0]);
    expect(old.toJson()['v'], 2);
    final again = AvatarSpec.parse(old.withValue('earrings', 2).toJson(), 'someone');
    expect(again.of('earrings'), 2);                                 // a v2 face keeps its new choices
    expect(AvatarSpec.fromSeed('x').of('hat'), lessThan(4));        // nobody gets a headscarf by default
    expect(AvatarSpec.fromSeed('x').of('mark'), 0);
  });

  testWidgets('static layers are recorded once and reused', (t) async {
    AvatarLayerCache.clear();
    final c = await demoContainer(demo: false);
    addTearDown(c.dispose);
    final s = AvatarSpec.fromSeed('cache');
    await t.pumpWidget(frame(c, Wrap(children: [for (var i = 0; i < 12; i++) TickAvatar(s, size: 24)]), dark: true));
    expect(AvatarLayerCache.recorded, 2);    // back and head, for all twelve
  });

  testWidgets('moods, tilt parallax and Reduce Motion', (t) async {
    final c = await demoContainer(demo: false);
    addTearDown(c.dispose);
    Future<List<int>> shot(Widget w) async {
      await t.pumpWidget(frame(c, RepaintBoundary(key: const ValueKey('a'), child: w), dark: true));
      await t.pump(const Duration(milliseconds: 50));
      final img = await t.runAsync(() async => (await (t.renderObject(find.byKey(const ValueKey('a'))) as RenderRepaintBoundary).toImage()).toByteData());
      return img!.buffer.asUint8List().toList();
    }
    final s = AvatarSpec.fromSeed('mood');
    final calm = await shot(Center(child: TickAvatar(s, size: 96, mood: AvatarMood.neutral)));
    final happy = await shot(Center(child: TickAvatar(s, size: 96, mood: AvatarMood.surprised)));
    expect(calm, isNot(happy));
    // live + Reduce Motion: no idle animation, so nothing is left ticking
    await t.pumpWidget(frame(c, MediaQuery(data: const MediaQueryData(disableAnimations: true), child: Center(child: TickAvatar(s, size: 120, live: true))), dark: true));
    expect(t.binding.hasScheduledFrame, isFalse);
  });

  test('old emoji groups land on an icon', () {
    expect(iconForEmoji('🏠'), 'home');
    expect(iconForEmoji('🦄'), 'misc');
    expect(iconForEmoji(null), isNull);
    expect(tallyIcons.length, 24);
  });

  testWidgets('tapping an avatar is a light haptic', (t) async {
    final c = await demoContainer(demo: false);
    addTearDown(c.dispose);
    TickHaptics.instance.log.clear();
    await t.pumpWidget(frame(c, Center(child: TickAvatar(AvatarSpec.fromSeed('x'), size: 96)), dark: true));
    await t.tap(find.byType(TickAvatar));
    await t.pump(const Duration(seconds: 1));
    expect(TickHaptics.instance.log, contains('selection'));
  });

  testWidgets('golden: avatars', (t) async {
    final c = await demoContainer(demo: false);
    addTearDown(c.dispose);
    await pumpGolden(t, frame(c, RepaintBoundary(child: Center(child: Wrap(spacing: 8, runSpacing: 8, children: [for (var i = 0; i < 24; i++) TickAvatar(AvatarSpec.fromSeed('person-$i'), size: 72)]))), dark: true), height: 700);
    await expectLater(find.byType(RepaintBoundary).first, matchesGoldenFile('goldens/avatars.png'));
  });

  testWidgets('golden: builder', (t) async {
    final c = await demoContainer();
    addTearDown(c.dispose);
    await pumpGolden(t, frame(c, const AvatarBuilderScreen(member: 'p-k'), dark: true));
    await expectLater(find.byType(AvatarBuilderScreen), matchesGoldenFile('goldens/avatar-builder.png'));
  });

  // The matrix: every skin tone against every hair style, with accessories across the columns (none, round glasses, hijab, turban + beard,
  // hoops + bindi, sunglasses + cap, headwrap + freckles), at 24, 48 and 120 pt, dark and light.
  for (final size in [24.0, 48.0, 120.0]) {
    for (final dark in [true, false]) {
      testWidgets('golden matrix ${size.toInt()} ${dark ? 'dark' : 'light'}', (t) async {
        final c = await demoContainer(demo: false);
        addTearDown(c.dispose);
        const extras = <Map<String, int>>[
          {}, {'glasses': 1}, {'hat': 4, 'cloth': 6}, {'hat': 5, 'beard': 1, 'cloth': 7}, {'earrings': 2, 'mark': 2}, {'glasses': 3, 'hat': 1}, {'hat': 6, 'mark': 1, 'cloth': 5},
        ];
        final skins = TickAvatarPalette.options['skin']!, hairs = TickAvatarPalette.options['hair']!;
        final gap = size < 40 ? 4.0 : 8.0;
        final w = hairs * (size + gap) + 2 * gap, h = (skins + 1) * (size + gap) + gap + 120;
        final grid = RepaintBoundary(child: Container(
          color: dark ? const Color(0xFF0E0E12) : const Color(0xFFF5F3EC), padding: EdgeInsets.all(gap),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (var r = 0; r < skins; r++)
              Padding(padding: EdgeInsets.only(bottom: gap), child: Row(mainAxisSize: MainAxisSize.min, children: [
                for (var col = 0; col < hairs; col++)
                  Padding(padding: EdgeInsets.only(right: gap), child: TickAvatar(AvatarSpec({
                    'face': col % 3, 'skin': r, 'hair': col, 'hairColor': (r + col) % 8, 'eyes': col % 4, 'brows': r % 3, 'mouth': (r + col) % 5,
                    'glasses': 0, 'hat': 0, 'beard': 0, 'background': (r + col) % 6, 'cloth': r % 8, 'earrings': 0, 'mark': 0, ...extras[(r + col) % extras.length],
                  }), size: size, tappable: false)),
              ])),
            Row(mainAxisSize: MainAxisSize.min, children: [
              for (final m in AvatarMood.values) Padding(padding: EdgeInsets.only(right: gap), child: AskMascot(size: size, mood: m, live: false, tappable: false)),
            ]),
          ]),
        ));
        await pumpGolden(t, frame(c, Align(alignment: Alignment.topLeft, child: grid), dark: dark), width: w, height: h);
        await expectLater(find.byType(RepaintBoundary).first, matchesGoldenFile('goldens/avatars/matrix-${size.toInt()}.${dark ? 'dark' : 'light'}.png'));
      });
    }
  }

  testWidgets('golden: icons', (t) async {
    final c = await demoContainer(demo: false);
    addTearDown(c.dispose);
    await pumpGolden(t, frame(c, RepaintBoundary(child: Center(child: Wrap(spacing: 8, runSpacing: 8, children: [for (final (i, k) in tallyIcons.indexed) IconChoice(k, on: i % 5 == 0, onTap: () {})]))), dark: true), height: 400);
    await expectLater(find.byType(RepaintBoundary).first, matchesGoldenFile('goldens/tally-icons.png'));
  });
}
