import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../data/suggestions.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../services/haptics.dart';

/// At most two suggestions in one card. Tapping one acts on it; "Not now" dismisses the card. Nothing when there's nothing to say.
class SuggestionCard extends ConsumerWidget {
  const SuggestionCard({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(suggestionsProvider).value ?? const <PlanSuggestion>[];
    if (list.isEmpty) return const SizedBox.shrink();
    final c = context.c;
    final n = ref.read(suggestionsProvider.notifier);
    return TickCard(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Suggested', style: context.ts(TickType.bodyS, color: c.textSecondary)),
      for (final (i, s) in list.take(2).indexed) ...[
        if (i > 0) const Hairline(),
        Pressable(
          onTap: () { TickHaptics.instance.selection(); n.answer(s, accept: true); context.push(s.route); }, scale: 0.99, semanticLabel: '${s.text} Open',
          child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 52), child: Padding(padding: const EdgeInsets.symmetric(vertical: TickSpace.x2), child: Row(children: [
            Expanded(child: Text(s.text, style: context.ts(TickType.body))),
            const SizedBox(width: 8),
            TickIcon('chevron-right', size: 18, color: c.textSecondary),
          ]))),
        ),
      ],
      Align(alignment: Alignment.centerLeft, child: Pressable(
        onTap: () { TickHaptics.instance.selection(); n.dismissAll(); }, semanticLabel: 'Not now, dismiss suggestions',
        child: Padding(padding: const EdgeInsets.only(top: 4, bottom: 2, right: 16), child: Text('Not now', style: context.ts(TickType.bodyS, color: c.textSecondary))),
      )),
    ]));
  }
}
