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
import '../design/motion.g.dart';
import '../design/widgets/more.dart';
import '../design/widgets/motion.dart';
import '../design/widgets/swipe.dart';
import '../design/widgets/scaffold.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import '../domain/tally.dart';
import '../services/api.dart';
import '../services/haptics.dart';
import 'common.dart';
import 'tally_expense_sheet.dart';
import 'tally_manage.dart';
import 'tally_more.dart';
import 'tally_people.dart';
import 'tally_square.dart';

class TallyGroupScreen extends ConsumerWidget {
  const TallyGroupScreen({super.key, required this.id});
  final String id;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(tallyProvider);
    final g = t.groups.where((x) => x.id == id).firstOrNull;
    if (g == null && t.loading) return TickPage(title: 'Tally', onBack: () => context.pop(), children: const [Skeleton(height: 120, radius: 24), SizedBox(height: 12), ListSkeleton(rows: 4)]);
    if (g == null) return TickPage(title: 'Tally', onBack: () => context.pop(), children: const [EmptyState('Not found', 'This tally is gone.')]);
    final c = context.c;
    final net = t.balancesOf(id);
    final moves = simplify(net);
    final pending = [for (final s in t.settlementsOf(id)) if (s.status == 'pending') s];
    final expenses = t.expensesOf(id);
    final txns = ref.watch(ledgerProvider).txns;
    return TickPage(
      title: g.name, onBack: () => context.pop(), bottomPad: 40, onRefresh: () => ref.read(tallyProvider.notifier).refresh(),
      trailing: Pressable(onTap: () => context.push('/tally/$id/settings'), semanticLabel: 'Group settings', minSize: 44, child: SizedBox(width: 40, height: 44, child: Center(child: TickIcon('sliders', size: 22, color: c.text)))),
      children: [
        Center(child: Padding(padding: const EdgeInsets.only(bottom: 12), child: TickHero(tag: 'group-${g.id}', child: GroupBadge(g: g, size: 56)))),
        BalancesCard(id: id, net: net, hasExpenses: expenses.isNotEmpty),
        const SizedBox(height: 12),
        PillButton('Add expense', icon: 'plus', onTap: () => showExpenseSheet(context, group: g)),
        const SizedBox(height: 8),
        PillButton('Split a receipt', icon: 'receipt', style: PillStyle.quiet, onTap: () => context.push('/tally/$id/receipt')),
        if (pending.isNotEmpty) ...[
          const SizedBox(height: 20), const SectionLabel('To confirm'),
          for (final s in pending) _Pending(s: s, g: g),
        ],
        if (moves.isNotEmpty) ...[
          const SizedBox(height: 20), const SectionLabel('Settle up'),
          for (final m in moves) _Move(m: m, g: g, txns: txns),
        ],
        if (t.settlementsOf(id).any((s) => s.status == 'confirmed')) ...[
          const SizedBox(height: 20), const SectionLabel('Payments'),
          for (final s in t.settlementsOf(id)) if (s.status == 'confirmed') SettlementRow(s: s, g: g),
        ],
        const SizedBox(height: 20),
        const SectionLabel('Expenses'),
        if (expenses.isEmpty) const EmptyState('Nothing split yet', 'Add an expense and it shows up here.', icon: 'tally'),
        for (final (i, e) in expenses.indexed) StaggerIn(scope: 'expenses-$id', index: i, child: _ExpenseRow(e: e, g: g)),
        if (t.billsOf(id).isNotEmpty) ...[const SizedBox(height: 20), const SectionLabel('Repeats'), for (final b in t.billsOf(id)) BillRow(b: b, g: g)],
        if (expenses.length >= 2) GroupInsightsCard(expenses: expenses, t: t),
        const SizedBox(height: 12),
        PillButton('Group activity', icon: 'tally', style: PillStyle.quiet, onTap: () => context.push('/tally/$id/activity')),
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
    final row = Pressable(
      onTap: () => context.push('/tally/${g.id}/expense/${e.id}'), semanticLabel: '${e.description}, ${formatCents(e.amountCents)}',
      child: Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Row(children: [
        TickHero(tag: 'expense-${e.id}', child: Avatar(e.description, 'shop', size: 36)),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(e.description, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.ts(TickType.bodyL)),
          Text('${t.nameOf(e.paidBy)} paid ${formatCents(e.amountCents)} · ${DateFormat('MMM d').format(e.spentOn)}', maxLines: 2, overflow: TextOverflow.ellipsis, style: context.ts(TickType.bodyS, color: c.textSecondary)),
        ])),
        const SizedBox(width: 8),
        Text(e.paidBy == me ? '+${formatCents(e.amountCents - mine)}' : '−${formatCents(mine)}', style: context.ts(TickType.mono, color: e.paidBy == me ? c.moneyIn : c.moneyOut)),
      ])),
    );
    if (!t.canEdit(g, e.createdBy)) return row;
    return SwipeActions(
      onThreshold: TickHaptics.instance.selection,
      actions: [
        SwipeAction('Edit', 'edit', () => showExpenseSheet(context, group: g, edit: e)),
        SwipeAction('Delete', 'trash', () => deleteExpenseWithUndo(context, ref, e)),
      ],
      child: row,
    );
  }
}

/// What everyone owes, rolling to new values. Someone who just reached zero gets a moment on their row before it goes.
class BalancesCard extends ConsumerStatefulWidget {
  const BalancesCard({super.key, required this.id, required this.net, required this.hasExpenses});
  final String id;
  final Map<String, int> net;
  final bool hasExpenses;
  @override
  ConsumerState<BalancesCard> createState() => _BalancesCardState();
}

class _BalancesCardState extends ConsumerState<BalancesCard> {
  final _settled = <String>{};

  @override
  void didUpdateWidget(BalancesCard old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id || widget.net.isEmpty) { _settled.clear(); return; }    // the whole group: that is the square-up moment, not this
    final gone = old.net.keys.where((k) => !widget.net.containsKey(k)).toSet();
    if (gone.isNotEmpty) { _settled.addAll(gone); TickHaptics.instance.success(); }
    _settled.removeAll(widget.net.keys);
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(tallyProvider);
    final c = context.c;
    final id = widget.id;
    return TickCard(child: AnimatedSize(
      duration: Duration(milliseconds: context.reduceMotion ? 0 : TickMotion.reduceMotionFadeMs), alignment: Alignment.topCenter,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (widget.net.isEmpty) Text(widget.hasExpenses ? 'All square ✓' : 'Nothing split yet.', style: context.ts(TickType.title))
        else for (final e in widget.net.entries) Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Row(children: [
          Expanded(child: Pressable(onTap: e.key == me ? null : () => context.push('/tally/$id/person/${e.key}'), scale: 0.99, child: Text(e.key == me ? (e.value > 0 ? 'You\'re owed' : 'You owe') : (e.value > 0 ? '${t.nameOf(e.key)} is owed' : '${t.nameOf(e.key)} owes'), style: context.ts(TickType.body)))),
          RollingNumber(value: e.value.abs(), semanticLabel: formatCents(e.value.abs()), builder: (_, v) => Text(formatCents(v), style: context.ts(TickType.mono, color: e.key == me && e.value < 0 ? c.alert : null))),
        ])),
        for (final k in _settled) SettledLine(key: ValueKey(k), name: k == me ? 'You' : t.nameOf(k), onDone: () { if (mounted) setState(() => _settled.remove(k)); }),
      ]),
    ));
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
      if (match == null && !third) Row(children: [
        Expanded(child: PillButton('Settle up', height: 44, onTap: () => showSettleSheet(context, g: g, m: m))),
        if (m.from != me) ...[const SizedBox(width: 8), Expanded(child: PillButton('Remind', height: 44, style: PillStyle.quiet, onTap: canRemind(t.lastReminder(g.id, m.from), DateTime.now()) ? () => showRemindSheet(context, g: g, member: m.from, cents: m.cents) : null))],
      ]) else PillButton(match != null ? 'Yes, that settles it' : '${t.nameOf(m.from)} paid ${t.nameOf(m.to)}', height: 44, style: match != null ? PillStyle.primary : PillStyle.quiet, onTap: () async {
        final before = ref.read(tallyProvider).balancesOf(g.id).isEmpty;
        await ref.read(tallyProvider.notifier).settle(g.id, m.from, m.to, m.cents, transactionId: match?.id.startsWith('local-') == false ? match?.id : null);
        if (context.mounted) await _maybeSquare(context, ref, g.id, before);
      }),
      if (m.from != me && remindedAgo(t.lastReminder(g.id, m.from), DateTime.now()) != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(remindedAgo(t.lastReminder(g.id, m.from), DateTime.now())!, style: context.ts(TickType.bodyS, size: 12.5, color: c.textSecondary))),
    ])));
  }
}

Future<void> _maybeSquare(BuildContext context, WidgetRef ref, String gid, bool wasSquare) async {
  final nowSquare = ref.read(tallyProvider).balancesOf(gid).isEmpty;
  if (nowSquare && !wasSquare) await showSquareUp(context);
}
