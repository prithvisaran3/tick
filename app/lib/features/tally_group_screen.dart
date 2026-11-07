import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import '../data/ledger.dart';
import '../data/tally_store.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../design/widgets/more.dart';
import '../design/widgets/scaffold.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import '../domain/tally.dart';
import '../services/api.dart';
import 'common.dart';
import 'tally_expense_sheet.dart';
import 'tally_square.dart';

class TallyGroupScreen extends ConsumerWidget {
  const TallyGroupScreen({super.key, required this.id});
  final String id;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(tallyProvider);
    final g = t.groups.where((x) => x.id == id).firstOrNull;
    if (g == null) return TickPage(title: 'Tally', onBack: () => context.pop(), children: const [EmptyState('Not found', 'This tally is gone.')]);
    final c = context.c;
    final net = t.balancesOf(id);
    final moves = simplify(net);
    final pending = [for (final s in t.settlementsOf(id)) if (s.status == 'pending') s];
    final expenses = t.expensesOf(id);
    final txns = ref.watch(ledgerProvider).txns;
    return TickPage(
      title: g.name, onBack: () => context.pop(), bottomPad: 40,
      children: [
        TickCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (net.isEmpty) Text(expenses.isEmpty ? 'Nothing split yet.' : 'All square ✓', style: context.ts(TickType.title))
          else for (final e in net.entries) Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Row(children: [
            Expanded(child: Text(e.key == me ? (e.value > 0 ? 'You\'re owed' : 'You owe') : (e.value > 0 ? '${t.nameOf(e.key)} is owed' : '${t.nameOf(e.key)} owes'), style: context.ts(TickType.body))),
            Text(formatCents(e.value.abs()), style: context.ts(TickType.mono, color: e.key == me && e.value < 0 ? c.alert : null)),
          ])),
        ])),
        const SizedBox(height: 12),
        PillButton('Add expense', icon: 'plus', onTap: () => showExpenseSheet(context, group: g)),
        if (pending.isNotEmpty) ...[
          const SizedBox(height: 20), const SectionLabel('To confirm'),
          for (final s in pending) _Pending(s: s, g: g),
        ],
        if (moves.isNotEmpty) ...[
          const SizedBox(height: 20), const SectionLabel('Settle up'),
          for (final m in moves) _Move(m: m, g: g, txns: txns),
        ],
        const SizedBox(height: 20),
        if (expenses.isNotEmpty) const SectionLabel('Expenses'),
        for (final e in expenses) _ExpenseRow(e: e, g: g),
        const SizedBox(height: 20),
        PillButton('Share a read-only link', icon: 'share', style: PillStyle.quiet, onTap: () => _share(context, ref)),
        const SizedBox(height: 8),
        Text('Anyone with the link can see this tally and tap "I paid". Nothing moves until you confirm it. Links expire in 30 days and you can turn them off.', style: context.ts(TickType.bodyS, color: c.textSecondary)),
      ],
    );
  }

  Future<void> _share(BuildContext context, WidgetRef ref) async {
    try {
      final j = await ref.read(apiProvider).post('/tally/groups/$id/links', {'days': 30});
      await SharePlus.instance.share(ShareParams(text: 'Here\'s where we stand: ${j['url']}'));
    } catch (e) {
      if (context.mounted) showTickSheet<void>(context, builder: (_) => Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('Couldn\'t make a link. ${describeError(e, action: 'make a link')}', style: context.ts(TickType.body))));
    }
  }
}

class _ExpenseRow extends ConsumerWidget {
  const _ExpenseRow({required this.e, required this.g});
  final TallyExpense e;
  final TallyGroup g;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(tallyProvider);
    final c = context.c;
    final mine = e.shares[me] ?? 0;
    return Pressable(
      onTap: () => showExpenseSheet(context, group: g, edit: e), semanticLabel: '${e.description}, ${formatCents(e.amountCents)}',
      child: Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(e.description, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.ts(TickType.bodyL)),
          Text('${t.nameOf(e.paidBy)} paid ${formatCents(e.amountCents)} · ${DateFormat('MMM d').format(e.spentOn)}', maxLines: 2, overflow: TextOverflow.ellipsis, style: context.ts(TickType.bodyS, color: c.textSecondary)),
        ])),
        const SizedBox(width: 8),
        Text(e.paidBy == me ? '+${formatCents(e.amountCents - mine)}' : '−${formatCents(mine)}', style: context.ts(TickType.mono, color: e.paidBy == me ? c.moneyIn : c.moneyOut)),
      ])),
    );
  }
}

class _Pending extends ConsumerWidget {
  const _Pending({required this.s, required this.g});
  final TallySettlement s;
  final TallyGroup g;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(tallyProvider);
    return Padding(padding: const EdgeInsets.only(bottom: 8), child: TickCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('${t.nameOf(s.from)} says they paid ${formatCents(s.amountCents)}.', style: context.ts(TickType.body)),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(child: PillButton('Got it', height: 44, onTap: () async {
          final before = ref.read(tallyProvider).balancesOf(g.id).isEmpty;
          await ref.read(tallyProvider.notifier).resolvePending(s.id, confirm: true);
          if (context.mounted) await _maybeSquare(context, ref, g.id, before);
        })),
        const SizedBox(width: 8),
        Expanded(child: PillButton('Not yet', height: 44, style: PillStyle.quiet, onTap: () => ref.read(tallyProvider.notifier).resolvePending(s.id, confirm: false))),
      ]),
    ])));
  }
}

class _Move extends ConsumerWidget {
  const _Move({required this.m, required this.g, required this.txns});
  final Transfer m;
  final TallyGroup g;
  final List<Txn> txns;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(tallyProvider);
    final c = context.c;
    final other = m.from == me ? m.to : m.from;
    final first = t.nameOf(other);
    // A Zelle row in Activity that looks like this payment: offered, never applied on its own.
    Txn? match;
    for (final x in txns) {
      if (looksLikeSettlement(t: m, personFirstName: first, txnCents: x.amountCents, merchant: x.merchant, txnAt: x.occurredAt, since: DateTime.now().subtract(const Duration(days: 45)))) { match = x; break; }
    }
    final third = m.from != me && m.to != me; // two friends settling between themselves
    final text = third ? '${t.nameOf(m.from)} pays ${t.nameOf(m.to)} ${formatCents(m.cents)}' : m.from == me ? 'You pay $first ${formatCents(m.cents)}' : '$first pays you ${formatCents(m.cents)}';
    return Padding(padding: const EdgeInsets.only(bottom: 8), child: TickCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(text, style: context.ts(TickType.bodyL)),
      if (match != null) Padding(padding: const EdgeInsets.only(top: 2), child: Text('Looks like ${match.merchant} on ${DateFormat('MMM d').format(match.occurredAt)}.', style: context.ts(TickType.bodyS, color: c.textSecondary))),
      const SizedBox(height: 10),
      PillButton(match != null ? 'Yes, that settles it' : (third ? '${t.nameOf(m.from)} paid ${t.nameOf(m.to)}' : m.from == me ? 'I paid $first' : 'They paid me'), height: 44, style: match != null ? PillStyle.primary : PillStyle.quiet, onTap: () async {
        final before = ref.read(tallyProvider).balancesOf(g.id).isEmpty;
        await ref.read(tallyProvider.notifier).settle(g.id, m.from, m.to, m.cents, transactionId: match?.id.startsWith('local-') == false ? match?.id : null);
        if (context.mounted) await _maybeSquare(context, ref, g.id, before);
      }),
    ])));
  }
}

Future<void> _maybeSquare(BuildContext context, WidgetRef ref, String gid, bool wasSquare) async {
  final nowSquare = ref.read(tallyProvider).balancesOf(gid).isEmpty;
  if (nowSquare && !wasSquare) await showSquareUp(context);
}
