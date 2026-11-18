import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tick/data/suggestions.dart';
import 'package:tick/features/suggestion_card.dart';
import 'golden_harness.dart';

class _S extends Suggestions {
  _S(this.list);
  final List<PlanSuggestion> list;
  final answered = <(String, bool)>[];
  @override
  Future<List<PlanSuggestion>> build() async => list;
  @override
  Future<void> answer(PlanSuggestion s, {required bool accept}) async { answered.add((s.kind, accept)); state = AsyncData([for (final x in state.value!) if (x.id != s.id) x]); }
}

const two = [
  PlanSuggestion(id: 'a', kind: 'goal_behind', text: 'Emergency fund is \$333.34 behind. \$750 a paycheck catches it up by Jan 1.', route: '/savings'),
  PlanSuggestion(id: 'b', kind: 'planned_soon', text: 'Concert tickets, \$120, is planned for Nov 10. It\'s already set aside.', route: '/planned'),
];

void main() {
  setUpAll(loadFonts);

  for (final (w, dark) in [(320.0, true), (430.0, false)]) {
    testWidgets('one card, at most two, Not now dismisses both ($w ${dark ? 'dark' : 'light'})', (t) async {
      final s = _S([...two, const PlanSuggestion(id: 'c', kind: 'room_to_spare', text: 'Third', route: '/savings')]);
      final c = await demoContainer(demo: false, overrides: [suggestionsProvider.overrideWith(() => s)]);
      addTearDown(c.dispose);
      await pumpGolden(t, frame(c, const SingleChildScrollView(child: SuggestionCard()), dark: dark), width: w);
      expect(find.textContaining('behind'), findsOneWidget);
      expect(find.text('Third'), findsNothing);
      await expectLater(find.byType(SuggestionCard), matchesGoldenFile('goldens/suggestions.${w.toInt()}.${dark ? 'dark' : 'light'}.png'));
      await t.tap(find.text('Not now'));
      await t.pump();
      expect(s.answered.take(2).map((a) => a.$2), [false, false]);
    });
  }

  testWidgets('nothing to suggest, no card', (t) async {
    final c = await demoContainer(demo: false, overrides: [suggestionsProvider.overrideWith(() => _S(const []))]);
    addTearDown(c.dispose);
    await pumpGolden(t, frame(c, const SuggestionCard(), dark: true));
    expect(find.text('Suggested'), findsNothing);
  });
}
