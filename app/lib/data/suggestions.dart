import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/api.dart';
import 'ledger.dart';
import 'remote.dart';
import 'settings.dart';

/// One suggestion: picked by rules on the server from the plan's numbers, worded with every amount kept.
class PlanSuggestion {
  const PlanSuggestion({required this.id, required this.kind, required this.text, required this.route});
  final String id;
  final String kind;
  final String text;
  final String route;
}

class Suggestions extends AsyncNotifier<List<PlanSuggestion>> {
  @override
  Future<List<PlanSuggestion>> build() async {
    ref.watch(ledgerRevisionProvider);
    if (ref.watch(settingsProvider.select((s) => s.demoMode)) || ref.watch(remoteProvider) == null) return const [];
    try {
      final j = await ref.read(apiProvider).get('/plan/suggestions');
      return [for (final s in (j['suggestions'] as List? ?? const [])) PlanSuggestion(id: s['id'] as String, kind: s['kind'] as String, text: s['text'] as String, route: (s['route'] ?? '/savings') as String)];
    } catch (_) {
      return const [];          // a suggestion is never worth an error on Insights
    }
  }

  /// Accept: I'm acting on it. Dismiss: not now. Both teach Ask Tick which kinds are useful; the card goes either way.
  Future<void> answer(PlanSuggestion s, {required bool accept}) async {
    final before = state.value ?? const <PlanSuggestion>[];
    state = AsyncData([for (final x in before) if (x.id != s.id) x]);
    try {
      await ref.read(apiProvider).post('/plan/suggestions/${s.id}', {'action': accept ? 'accept' : 'dismiss'});
    } catch (_) {
      state = AsyncData(before);
    }
  }

  Future<void> dismissAll() async {
    for (final s in [...?state.value]) { await answer(s, accept: false); }
  }
}

final suggestionsProvider = AsyncNotifierProvider<Suggestions, List<PlanSuggestion>>(Suggestions.new);
