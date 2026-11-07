import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/ledger.dart';
import '../data/remote.dart';
import '../data/settings.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../design/widgets/more.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import '../services/api.dart';
import '../services/haptics.dart';

class RuleSuggestion {
  const RuleSuggestion(this.person, this.name, this.amountCents, this.day);
  final String person;
  final String name;
  final int amountCents;
  final int day;
}

final ruleSuggestionsProvider = FutureProvider<List<RuleSuggestion>>((ref) async {
  ref.watch(ledgerRevisionProvider);
  if (ref.watch(settingsProvider.select((s) => s.demoMode)) || ref.watch(remoteProvider) == null) return const [];
  try {
    final j = await ref.read(apiProvider).get('/rules/suggestions');
    return [for (final s in (j['suggestions'] as List? ?? const [])) RuleSuggestion(s['person'] as String, s['name'] as String, (s['amount_cents'] as num).toInt(), (s['day'] as num).toInt())];
  } catch (_) {
    return const [];
  }
});

/// "Looks like rent to Kaarthik, $1,200 monthly."
class RuleSuggestionCard extends ConsumerStatefulWidget {
  const RuleSuggestionCard({super.key, required this.s});
  final RuleSuggestion s;
  @override
  ConsumerState<RuleSuggestionCard> createState() => _RuleSuggestionCardState();
}

class _RuleSuggestionCardState extends ConsumerState<RuleSuggestionCard> {
  bool _busy = false;
  String? _error;
  Future<void> _answer(String kind) async {
    final s = widget.s;
    setState(() { _busy = true; _error = null; });
    try {
      await ref.read(apiProvider).post('/rules/accept', {'person': s.person, 'amount_cents': s.amountCents, 'day': s.day, 'kind': kind});
      TickHaptics.instance.confirm();
      await ref.read(ledgerProvider.notifier).refresh();
      ref.invalidate(ruleSuggestionsProvider);
    } catch (e) {
      if (mounted) setState(() { _busy = false; _error = describeError(e, action: 'save that'); });
    }
  }
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final s = widget.s;
    return Padding(padding: const EdgeInsets.only(bottom: 8), child: TickCard(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Looks like rent or a bill to ${s.name}, ${formatDollars(s.amountCents)} monthly', style: context.ts(TickType.title, size: 15.5)),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 4, children: [
        TickChip('Rent', onTap: _busy ? null : () => _answer('rent')),
        TickChip('Other bill', onTap: _busy ? null : () => _answer('bill')),
        TickChip('Not recurring', onTap: _busy ? null : () => _answer('no')),
      ]),
      if (_error != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(_error!, style: context.ts(TickType.bodyS, size: 12.5, color: c.alert))),
    ])));
  }
}

class LikelySplitwise {
  const LikelySplitwise(this.txnId, this.label, this.cents);
  final String txnId;
  final String label;
  final int cents;
}

final likelySplitwiseProvider = FutureProvider<List<LikelySplitwise>>((ref) async {
  ref.watch(ledgerRevisionProvider);
  if (ref.watch(settingsProvider.select((s) => s.demoMode)) || ref.watch(remoteProvider) == null) return const [];
  try {
    final j = await ref.read(apiProvider).get('/splitwise/likely');
    return [for (final s in (j['suggestions'] as List? ?? const [])) LikelySplitwise(s['txn_id'] as String, s['label'] as String, (s['cents'] as num).toInt())];
  } catch (_) {
    return const [];
  }
});

/// "Likely Splitwise". Yes teaches the category; No never asks about this row again.
class LikelySplitwiseCard extends ConsumerWidget {
  const LikelySplitwiseCard({super.key, required this.s});
  final LikelySplitwise s;
  Future<void> _answer(WidgetRef ref, bool yes) async {
    TickHaptics.instance.confirm();
    try {
      await ref.read(apiProvider).post('/splitwise/answer', {'txn_id': s.txnId, 'yes': yes});
      await ref.read(ledgerProvider.notifier).refresh();
      ref.invalidate(likelySplitwiseProvider);
    } catch (_) {/* it asks again next time */}
  }
  @override
  Widget build(BuildContext context, WidgetRef ref) => Padding(padding: const EdgeInsets.only(bottom: 8), child: TickCard(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Likely Splitwise: ${s.label}, ${formatCents(s.cents)}', style: context.ts(TickType.title, size: 15.5)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: PillButton('Yes', height: 44, onTap: () => _answer(ref, true))),
          const SizedBox(width: 8),
          Expanded(child: PillButton('No', height: 44, style: PillStyle.quiet, onTap: () => _answer(ref, false))),
        ]),
      ])));
}

/// After moving a person-to-person row to Rent by hand: make it a rule, or leave it a one-off.
Future<void> showRuleOffer(BuildContext context, WidgetRef ref, Txn t, Category cat, String who) => showTickSheet<void>(context, builder: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Text('Always for ${who.split(' ').first} around ${formatDollars(-t.amountCents)}?', style: ctx.ts(TickType.title)),
      const SizedBox(height: 4),
      Text('Payments close to that amount and day become ${cat.name}. Anything else stays as it is.', style: ctx.ts(TickType.body, color: ctx.c.textSecondary)),
      const SizedBox(height: 12),
      PillButton('Yes, always', onTap: () async {
        Navigator.of(ctx).pop();
        try {
          await ref.read(apiProvider).post('/rules/from-txn', {'txn_id': t.id, 'category_id': cat.id});
          TickHaptics.instance.confirm();
          await ref.read(ledgerProvider.notifier).refresh();
        } catch (_) {/* the one row is already changed */}
      }),
      const SizedBox(height: 6),
      PillButton('Just this one', style: PillStyle.quiet, onTap: () => Navigator.of(ctx).pop()),
    ]));
