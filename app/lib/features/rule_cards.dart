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

class LikelySplitwise {
  const LikelySplitwise(this.txnId, this.label, this.cents, {this.confidence = 0.7, this.reason = 'friend'});
  final String txnId;
  final String label;
  final int cents;
  final double confidence;
  final String reason;   // friend | paid_back
}

final likelySplitwiseProvider = FutureProvider<List<LikelySplitwise>>((ref) async {
  ref.watch(ledgerRevisionProvider);
  if (ref.watch(settingsProvider.select((s) => s.demoMode)) || ref.watch(remoteProvider) == null) return const [];
  try {
    final j = await ref.read(apiProvider).get('/splitwise/likely');
    return [for (final s in (j['suggestions'] as List? ?? const [])) LikelySplitwise(s['txn_id'] as String, s['label'] as String, (s['cents'] as num).toInt(),
        confidence: (s['confidence'] as num?)?.toDouble() ?? 0.7, reason: (s['reason'] as String?) ?? 'friend')];
  } catch (_) {
    return const [];
  }
});

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
