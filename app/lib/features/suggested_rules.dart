import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../data/profile_data.dart';
import '../data/remote.dart';
import '../data/settings.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../design/widgets/more.dart';
import '../services/api.dart';
import '../services/haptics.dart';
import 'common.dart';
import 'profile_screen.dart' show showToast;

/// A rule Ask Tick proposes from a week of thumbs-down. Nothing changes until it's approved.
class AskProposal {
  const AskProposal({required this.key, required this.label, required this.questions, required this.count});
  final String key;
  final String label;
  final List<String> questions;
  final int count;
  factory AskProposal.fromJson(Map<String, dynamic> j) => AskProposal(key: j['key'] as String, label: (j['label'] as String?) ?? '',
      questions: [for (final q in (j['questions'] as List? ?? const [])) q as String], count: (j['count'] as num?)?.toInt() ?? 1);
}

Duration? _noRetry(int _, Object _) => null;

final askProposalsProvider = FutureProvider<List<AskProposal>>((ref) async {
  if (ref.watch(settingsProvider.select((s) => s.demoMode)) || ref.watch(remoteProvider) == null) return const [];
  final j = await ref.read(apiProvider).get('/ask/proposals');
  return [for (final p in (j['proposals'] as List? ?? const [])) AskProposal.fromJson((p as Map).cast<String, dynamic>())];
}, retry: _noRetry);

/// Profile > Categories and rules > Suggested rules.
class SuggestedRulesScreen extends ConsumerWidget {
  const SuggestedRulesScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ps = ref.watch(askProposalsProvider);
    return TickScreen(child: ListView(children: [
      ScreenTitle('Suggested rules', onBack: () => context.pop()),
      ps.when(
        loading: () => const ListSkeleton(rows: 3),
        error: (_, _) => ErrorState(onRetry: () async => ref.invalidate(askProposalsProvider)),
        data: (list) => list.isEmpty
            ? const EmptyState('Nothing to review', 'When a few answers get a thumbs down with a fix, Tick suggests a rule here.')
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Padding(padding: const EdgeInsets.only(bottom: 12), child: Text('From this week\'s thumbs down. Nothing changes until you approve.', style: context.ts(TickType.body, color: context.c.textSecondary))),
                for (final p in list) Padding(padding: const EdgeInsets.only(bottom: 12), child: _ProposalCard(key: ValueKey(p.key), p: p)),
              ]),
      ),
    ]));
  }
}

class _ProposalCard extends ConsumerStatefulWidget {
  const _ProposalCard({super.key, required this.p});
  final AskProposal p;
  @override
  ConsumerState<_ProposalCard> createState() => _ProposalCardState();
}

class _ProposalCardState extends ConsumerState<_ProposalCard> {
  bool _busy = false;
  String? _error;

  Future<void> _act(bool approve) async {
    setState(() { _busy = true; _error = null; });
    final overlay = Overlay.of(context, rootOverlay: true);
    try {
      await ref.read(apiProvider).post('/ask/proposals/${Uri.encodeComponent(widget.p.key)}/${approve ? 'approve' : 'dismiss'}');
      TickHaptics.instance.confirm();
      ref.invalidate(askProposalsProvider);
      ref.invalidate(askMemoryProvider);
      showToast(overlay, approve ? 'Ask Tick will answer that way now' : 'Dismissed');
    } catch (e) {
      if (mounted) setState(() { _busy = false; _error = describeError(e, action: 'save that'); });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final p = widget.p;
    final first = p.questions.isEmpty ? 'that' : '“${p.questions.first}”';
    return TickCard(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('When you ask $first, answer with ${p.label}', style: context.ts(TickType.title, size: 16)),
      const SizedBox(height: 4),
      Text(p.count == 1 ? 'From one thumbs down.' : 'From ${p.count} thumbs down.', style: context.ts(TickType.bodyS, color: c.textSecondary)),
      if (p.questions.length > 1) ...[
        const SizedBox(height: 8),
        for (final q in p.questions.skip(1).take(3)) Padding(padding: const EdgeInsets.only(bottom: 2), child: Text('“$q”', style: context.ts(TickType.bodyS, color: c.textSecondary))),
      ],
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: PillButton('Approve', height: 44, busy: _busy, onTap: () => _act(true))),
        const SizedBox(width: 8),
        Expanded(child: PillButton('Dismiss', height: 44, style: PillStyle.quiet, onTap: _busy ? null : () => _act(false))),
      ]),
      if (_error != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(_error!, style: context.ts(TickType.bodyS, color: c.alert))),
    ]));
  }
}
