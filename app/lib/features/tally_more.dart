import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import '../data/tally_store.dart';
import '../design/motion.g.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../design/widgets/motion.dart';
import '../design/widgets/more.dart';
import '../design/widgets/scaffold.dart';
import '../domain/money.dart';
import '../domain/tally.dart';
import '../services/haptics.dart';
import 'common.dart';
import 'tally_expense_sheet.dart';

class BillRow extends ConsumerWidget {
  const BillRow({super.key, required this.b, required this.g});
  final TallyBill b;
  final TallyGroup g;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(tallyProvider);
    return Padding(padding: const EdgeInsets.only(bottom: 8), child: TickCard(child: Row(children: [
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${b.description}, ${formatCents(b.amountCents)}', maxLines: 2, overflow: TextOverflow.ellipsis, style: context.ts(TickType.body)),
        Text('${b.cadence[0].toUpperCase()}${b.cadence.substring(1)} · next ${DateFormat('MMM d').format(b.nextOn)}', style: context.ts(TickType.bodyS, size: 12.5, color: context.c.textSecondary)),
      ])),
      if (t.canEdit(g, b.createdBy)) PillButton('Stop', expand: false, height: 40, style: PillStyle.quiet, onTap: () => ref.read(tallyProvider.notifier).stopBill(b.id).catchError((_) {})),
    ])));
  }
}

/// A member just reached zero: "Settled up" with a short Volt tick, then the row goes. Reduce Motion: it fades.
class SettledLine extends StatefulWidget {
  const SettledLine({super.key, required this.name, required this.onDone});
  final String name;
  final VoidCallback onDone;
  @override
  State<SettledLine> createState() => _SettledLineState();
}

class _SettledLineState extends State<SettledLine> with SingleTickerProviderStateMixin {
  late final AnimationController _hold;
  @override
  void initState() {
    super.initState();
    _hold = AnimationController(vsync: this, duration: const Duration(milliseconds: TickMotion.settledHoldMs))
      ..addStatusListener((s) { if (s == AnimationStatus.completed) widget.onDone(); })
      ..forward();
  }
  @override
  void dispose() { _hold.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Semantics(liveRegion: true, label: '${widget.name} settled up', excludeSemantics: true, child: StaggerIn(scope: 'settled-${identityHashCode(this)}', index: 0, child: Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Row(children: [
      Expanded(child: Text(widget.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.ts(TickType.body))),
      Container(width: 22, height: 22, alignment: Alignment.center, decoration: BoxDecoration(color: c.accent, shape: BoxShape.circle), child: TickIcon('check', size: 14, color: c.onAccent)),
      const SizedBox(width: 6),
      Text('Settled up', style: context.ts(TickType.bodyS, color: c.textSecondary)),
    ]))));
  }
}

/// Who usually pays, what the group spends a month, and my real share against what I fronted.
class GroupInsightsCard extends StatelessWidget {
  const GroupInsightsCard({super.key, required this.expenses, required this.t});
  final List<TallyExpense> expenses;
  final TallyState t;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final i = groupInsights(expenses, DateTime.now());
    final top = i.paidBy.first;
    final share = i.totalCents == 0 ? 0 : (top.$2 * 100 / i.totalCents).round();
    final peak = i.monthly.map((m) => m.$2).fold<int>(1, (a, b) => a > b ? a : b);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 20),
      const SectionLabel('Group insights'),
      TickCard(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('${top.$1 == me ? 'You usually pay' : '${t.nameOf(top.$1)} usually pays'}: $share% of ${formatDollars(i.totalCents)}', style: context.ts(TickType.body)),
        const SizedBox(height: 12),
        Semantics(label: 'Spend per month: ${i.monthly.map((m) => '${DateFormat('MMMM').format(m.$1)} ${formatDollars(m.$2)}').join(', ')}', excludeSemantics: true, child: SizedBox(height: 84, child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          for (final m in i.monthly) Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 3), child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
            Container(height: 56 * (m.$2 / peak) + 2, decoration: BoxDecoration(color: c.text, borderRadius: BorderRadius.circular(6))),
            const SizedBox(height: 4),
            Text(DateFormat('MMM').format(m.$1), maxLines: 1, style: context.ts(TickType.bodyS, size: 11.5, color: c.textSecondary)),
          ]))),
        ]))),
        const SizedBox(height: 6),
        Text('${formatDollars(i.monthly.last.$2)} this month', style: context.ts(TickType.bodyS, color: c.textSecondary)),
        if (i.frontedCents > 0 || i.myShareCents > 0) ...[
          const SizedBox(height: 10),
          const Hairline(),
          const SizedBox(height: 10),
          Text('${formatDollars(i.myShareCents)} was your real share', style: context.ts(TickType.body)),
          Text('You fronted ${formatDollars(i.frontedCents)}.', style: context.ts(TickType.bodyS, color: c.textSecondary)),
        ],
      ])),
    ]);
  }
}

/// One payment per person, across every group.
class TallyPlanScreen extends ConsumerWidget {
  const TallyPlanScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(tallyProvider);
    final plan = t.plan;
    final c = context.c;
    return TickPage(title: 'Settle everything', onBack: () => context.pop(), children: [
      if (plan.isEmpty) const EmptyState('All square ✓', 'Nobody owes anybody.', icon: 'check')
      else ...[
        Text('${plan.where((p) => p.netCents != 0).length} ${plan.where((p) => p.netCents != 0).length == 1 ? 'payment clears' : 'payments clear'} all ${t.groups.length} tallies.', style: context.ts(TickType.body, color: c.textSecondary)),
        const SizedBox(height: 12),
        for (final p in plan) Padding(padding: const EdgeInsets.only(bottom: 8), child: TickCard(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(p.netCents == 0 ? 'You and ${p.name} are even' : p.netCents < 0 ? 'You pay ${p.name} ${formatCents(-p.netCents)}' : '${p.name} pays you ${formatCents(p.netCents)}', style: context.ts(TickType.bodyL)),
          Text(p.legs.map((l) => t.groups.where((g) => g.id == l.$1).firstOrNull?.name ?? 'Tally').join(', '), maxLines: 2, overflow: TextOverflow.ellipsis, style: context.ts(TickType.bodyS, size: 12.5, color: c.textSecondary)),
          const SizedBox(height: 10),
          PillButton(p.netCents == 0 ? 'Clear it' : 'Mark as paid', height: 44, style: PillStyle.quiet, onTap: () async {
            await ref.read(tallyProvider.notifier).settlePlanItem(p);
            TickHaptics.instance.confirm();
          }),
        ]))),
        const SizedBox(height: 4),
        Text('Marking as paid settles each tally listed. Tick never moves money.', style: context.ts(TickType.bodyS, size: 12.5, color: c.textSecondary)),
      ],
    ]);
  }
}

/// Snap a receipt, tap items onto people. If the items can't be read, the ordinary split opens instead.
class TallyReceiptScreen extends ConsumerStatefulWidget {
  const TallyReceiptScreen({super.key, required this.id});
  final String id;
  @override
  ConsumerState<TallyReceiptScreen> createState() => _ReceiptState();
}

class _ReceiptState extends ConsumerState<TallyReceiptScreen> {
  List<ReceiptItem> _items = const [];
  int _extra = 0;
  String? _merchant;
  bool _busy = false;
  String? _note;

  TallyGroup? get _g => ref.read(tallyProvider).groups.where((x) => x.id == widget.id).firstOrNull;

  Future<void> _snap() async {
    setState(() { _busy = true; _note = null; });
    try {
      final x = await ImagePicker().pickImage(source: ImageSource.camera, maxWidth: 1800, imageQuality: 80);
      if (x == null) { if (mounted) setState(() => _busy = false); return; }
      final r = await ref.read(tallyProvider.notifier).readReceipt(await x.readAsBytes());
      if (!mounted) return;
      setState(() { _items = r.items; _extra = r.extraCents; _merchant = r.merchant; _busy = false; });
      if (r.items.isEmpty) _manual();
    } catch (_) {
      if (mounted) { setState(() => _busy = false); _manual(); }
    }
  }

  void _manual() {
    final g = _g;
    if (g == null) return;
    setState(() => _note = 'Couldn\'t read that receipt. Split it by hand.');
    showExpenseSheet(context, group: g);
  }

  Future<void> _save(Map<String, int> shares, int total) async {
    final g = _g;
    if (g == null) return;
    setState(() => _busy = true);
    final ok = await ref.read(tallyProvider.notifier).saveExpense(TallyExpense(id: '', groupId: g.id, description: _merchant ?? 'Receipt', amountCents: total, paidBy: me, shares: shares, spentOn: DateTime.now(), splitType: SplitType.exact));
    if (!mounted) return;
    if (ok) { TickHaptics.instance.confirm(); context.pop(); } else { setState(() { _busy = false; _note = 'That didn\'t save. Try again.'; }); }
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(tallyProvider);
    final c = context.c;
    final g = t.groups.where((x) => x.id == widget.id).firstOrNull;
    if (g == null) return TickPage(title: 'Receipt', onBack: () => context.pop(), children: const [EmptyState('Not found', 'This tally is gone.')]);
    final everyone = [me, ...g.memberIds];
    final shares = itemisedSplit(_items, _extra);
    final total = _items.fold<int>(0, (a, i) => a + i.cents) + _extra;
    return TickPage(title: _merchant ?? 'Split a receipt', onBack: () => context.pop(), bottomPad: 40, children: [
      if (_note != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(_note!, style: context.ts(TickType.bodyS, color: c.textSecondary))),
      if (_items.isEmpty) ...[
        Text('Take a photo, then tap who had what. Tax and tip are shared in proportion.', style: context.ts(TickType.body, color: c.textSecondary)),
        const SizedBox(height: 12),
        PillButton('Take a photo', icon: 'receipt', busy: _busy, onTap: _snap),
        const SizedBox(height: 8),
        PillButton('Split by hand', style: PillStyle.quiet, onTap: () => showExpenseSheet(context, group: g)),
      ] else ...[
        for (final (n, i) in _items.indexed) Padding(padding: const EdgeInsets.only(bottom: 8), child: TickCard(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text(i.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.ts(TickType.body))),
            Text(formatCents(i.cents), style: context.ts(TickType.mono)),
          ]),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 4, children: [for (final p in everyone) TickChip(t.nameOf(p), on: i.people.contains(p), onTap: () {
            TickHaptics.instance.selection();
            final next = {...i.people}; next.contains(p) ? next.remove(p) : next.add(p);
            setState(() => _items = [..._items]..[n] = i.withPeople(next));
          })]),
        ]))),
        if (_extra > 0) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('Tax and tip ${formatCents(_extra)}, shared in proportion.', style: context.ts(TickType.bodyS, color: c.textSecondary))),
        if (shares != null) TickCard(padding: const EdgeInsets.symmetric(horizontal: 16), child: Column(children: [
          for (final (n, e) in shares.entries.indexed) ...[
            if (n > 0) const Hairline(),
            Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Row(children: [
              Expanded(child: Text(t.nameOf(e.key), style: context.ts(TickType.body))),
              Text(formatCents(e.value), style: context.ts(TickType.mono)),
            ])),
          ],
        ])),
        const SizedBox(height: 12),
        PillButton(shares == null ? 'Put someone on every item' : 'Split ${formatCents(total)}', busy: _busy, onTap: shares == null ? null : () => _save(shares, total)),
      ],
    ]);
  }
}
