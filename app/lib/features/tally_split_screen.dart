import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../data/ledger.dart';
import '../data/tally_store.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../design/widgets/scaffold.dart';
import '../domain/money.dart';
import 'common.dart';
import 'tally_expense_sheet.dart';
import 'tally_screen.dart';

/// "Split with friends" from a transaction: pick the tally, then the split sheet opens prefilled. The purchase itself stays an ordinary
/// expense in Activity; the split only records who owes me.
class TallySplitScreen extends ConsumerWidget {
  const TallySplitScreen({super.key, required this.txnId});
  final String txnId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(tallyProvider);
    final x = ref.watch(ledgerProvider).txns.where((e) => e.id == txnId).firstOrNull;
    if (x == null) return TickPage(title: 'Split', onBack: () => context.pop(), children: const [EmptyState('Not found', 'That purchase is gone.')]);
    final cents = x.amountCents.abs();
    final tid = x.id.startsWith('local-') || !RegExp(r'^[0-9a-f]{8}-').hasMatch(x.id) ? null : x.id;
    void open(g) => showExpenseSheet(context, group: g, description: x.merchant, cents: cents, transactionId: tid, on: x.occurredAt);
    return TickPage(
      title: 'Split ${formatCents(cents)}', subtitle: x.merchant, onBack: () => context.pop(),
      children: [
        for (final g in t.groups) Padding(padding: const EdgeInsets.only(bottom: 8), child: TickCard(onTap: () => open(g), child: Row(children: [
          Expanded(child: Text('${g.emoji ?? ''} ${g.name}'.trim(), maxLines: 2, overflow: TextOverflow.ellipsis, style: context.ts(TickType.bodyL))),
          TickIcon('chevron-right', size: 20, color: context.c.textSecondary),
        ]))),
        const SizedBox(height: 8),
        PillButton('New tally', icon: 'plus', style: PillStyle.quiet, onTap: () => showNewGroupSheet(context, onCreated: (g) { if (context.mounted) open(g); })),
      ],
    );
  }
}
