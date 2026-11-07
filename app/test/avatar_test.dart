import 'dart:math';
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
    expect(avatarLayers.map((l) => l.$1).toSet(), TickAvatarPalette.options.keys.toSet());
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

  testWidgets('golden: icons', (t) async {
    final c = await demoContainer(demo: false);
    addTearDown(c.dispose);
    await pumpGolden(t, frame(c, RepaintBoundary(child: Center(child: Wrap(spacing: 8, runSpacing: 8, children: [for (final (i, k) in tallyIcons.indexed) IconChoice(k, on: i % 5 == 0, onTap: () {})]))), dark: true), height: 400);
    await expectLater(find.byType(RepaintBoundary).first, matchesGoldenFile('goldens/tally-icons.png'));
  });
}
