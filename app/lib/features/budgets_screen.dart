import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../data/ledger.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../design/widgets/more.dart';
import '../design/widgets/pickers.dart';
import '../domain/budget_plan.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import '../services/haptics.dart';
import 'common.dart';

/// Budgets (light category caps with a pace line) and goals (progress). Create, edit, delete with Hold to confirm.
class BudgetsScreen extends ConsumerWidget {
  const BudgetsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = ref.watch(ledgerProvider);
    final now = ref.watch(clockProvider)();
    final c = context.c;
    return TickScreen(
      child: ListView(padding: const EdgeInsets.only(bottom: 48), children: [
        ScreenTitle('Budgets and goals', onBack: () => context.pop()),
        SectionLabel('Budgets', trailing: TickChip('Add', icon: 'plus', onTap: () => _editBudget(context, ref, null))),
        if (l.budgets.isEmpty)
          const EmptyState('No budgets yet', 'Set a monthly cap on food or rideshare and Tick draws the pace line.', icon: 'goal')
        else
          for (final b in l.budgets) Padding(padding: const EdgeInsets.only(bottom: 8), child: _BudgetCard(b: b, ledger: l, now: now, onTap: () => _editBudget(context, ref, b))),
        SectionLabel('Goals', trailing: TickChip('Add', icon: 'plus', onTap: () => _editGoal(context, ref, null))),
        if (l.goals.isEmpty)
          const EmptyState('No goals yet', 'Name one, set a target, and choose what you move each payday.', icon: 'goal')
        else
          for (final g in l.goals) Padding(padding: const EdgeInsets.only(bottom: 8), child: _GoalCard(g: g, onTap: () => _editGoal(context, ref, g))),
        Padding(padding: const EdgeInsets.only(top: 8), child: Text('Goals set to move money each payday are planned out of Safe to spend.', style: context.ts(TickType.bodyS, color: c.textSecondary))),
      ]),
    );
  }

  Future<void> _editBudget(BuildContext context, WidgetRef ref, Budget? existing) async {
    final l = ref.read(ledgerProvider);
    final taken = l.budgets.map((b) => b.categoryId).toSet();
    String? catId = existing?.categoryId;
    if (existing == null) {
      final cats = l.categories.where((c) => c.kind == 'spend' && !taken.contains(c.id)).toList();
      catId = await showTickSheet<String>(context, builder: (ctx) => SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Which category?', style: ctx.ts(TickType.displayM)), const SizedBox(height: 16),
        Wrap(spacing: 8, runSpacing: 4, children: [for (final c in cats) TickChip(c.name, onTap: () => Navigator.of(ctx).pop(c.id))]),
      ])));
      if (catId == null || !context.mounted) return;
    }
    final name = l.category(catId)?.name ?? 'Category';
    final cents = await showTickSheet<int>(context, full: true, builder: (ctx) => _BudgetEdit(title: name, initial: existing?.capCents ?? 0, onDelete: existing == null ? null : () { ref.read(ledgerProvider.notifier).deleteBudget(existing.id); Navigator.of(ctx).pop(-1); }));
    if (cents != null && cents > 0) ref.read(ledgerProvider.notifier).saveBudget(catId!, cents);
  }

  Future<void> _editGoal(BuildContext context, WidgetRef ref, Goal? g) async {
    final name = g?.name ?? await showTextSheet(context, title: 'Name your goal', hint: 'Emergency fund, Japan trip');
    if (name == null || !context.mounted) return;
    var target = g?.targetCents ?? 0, per = g?.perPaydayCents ?? 0;
    if (g == null) {
      final t = await showAmountSheet(context, title: 'Target for $name');
      if (t == null || !context.mounted) return;
      target = t;
      final p = await showAmountSheet(context, title: 'Move each payday', confirm: 'Add');
      per = p ?? 0;
    } else {
      final res = await showTickSheet<_GoalResult>(context, full: true, builder: (ctx) => _GoalEdit(goal: g, onDelete: () { ref.read(ledgerProvider.notifier).deleteGoal(g.id); Navigator.of(ctx).pop(const _GoalResult.deleted()); }));
      if (res == null || res.deleted) return;
      target = res.target; per = res.per;
    }
    final id = g?.id ?? 'local-g-${DateTime.now().microsecondsSinceEpoch}';
    ref.read(ledgerProvider.notifier).saveGoal(Goal(id: id, name: name, targetCents: target, savedCents: g?.savedCents ?? 0, perPaydayCents: per));
    TickHaptics.instance.pop();
  }
}

class _BudgetCard extends StatelessWidget {
  const _BudgetCard({required this.b, required this.ledger, required this.now, required this.onTap});
  final Budget b;
  final LedgerState ledger;
  final DateTime now;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final cat = ledger.category(b.categoryId);
    final p = budgetPace(spentCents: spentInMonth(ledger.txns, b.categoryId, now), capCents: b.capCents, now: now);
    final fillColor = p.state == PaceState.over || p.state == PaceState.hot ? c.alert : c.text;
    return TickCard(
      onTap: onTap,
      child: Semantics(
        label: '${cat?.name ?? 'Category'} budget, ${p.line}',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Avatar(cat?.name ?? '?', cat?.colorKey ?? 'shop', size: 32), const SizedBox(width: 12),
            Expanded(child: Text(cat?.name ?? 'Category', style: context.ts(TickType.title, size: 16))),
            Text('${formatDollars(p.spentCents)} of ${formatDollars(p.capCents)}', style: context.ts(TickType.monoS)),
          ]),
          const SizedBox(height: 12),
          // The pace line: a tick where you would be if spending were even across the month.
          LayoutBuilder(builder: (_, cs) {
            final w = cs.maxWidth;
            return SizedBox(height: 16, child: Stack(alignment: Alignment.centerLeft, clipBehavior: Clip.none, children: [
              Container(height: 8, decoration: BoxDecoration(color: c.surface2, borderRadius: BorderRadius.circular(8))),
              TweenAnimationBuilder<double>(tween: Tween(begin: 0, end: p.fill / 1.3), duration: const Duration(milliseconds: 500), curve: Curves.easeOutBack,
                  builder: (_, v, _) => Container(width: w * v.clamp(0.0, 1.0), height: 8, decoration: BoxDecoration(color: fillColor, borderRadius: BorderRadius.circular(8)))),
              Positioned(left: (w * p.paceFraction / 1.3).clamp(0.0, w - 2), child: Container(width: 2, height: 16, color: c.textSecondary)),
            ]));
          }),
          const SizedBox(height: 8),
          Text(p.line, style: context.ts(TickType.bodyS, color: p.state == PaceState.hot || p.state == PaceState.over ? c.alert : c.textSecondary)),
        ]),
      ),
    );
  }
}

class _GoalCard extends StatelessWidget {
  const _GoalCard({required this.g, required this.onTap});
  final Goal g;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final prog = goalProgress(g);
    return TickCard(
      onTap: onTap,
      child: Semantics(
        label: '${g.name}, ${(prog * 100).round()} percent of ${formatDollars(g.targetCents)}',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(g.name, style: context.ts(TickType.title, size: 16))),
            Text('${formatDollars(g.savedCents)} of ${formatDollars(g.targetCents)}', style: context.ts(TickType.monoS)),
          ]),
          const SizedBox(height: 12),
          LayoutBuilder(builder: (_, cs) => Stack(children: [
            Container(height: 8, decoration: BoxDecoration(color: c.surface2, borderRadius: BorderRadius.circular(8))),
            TweenAnimationBuilder<double>(tween: Tween(begin: 0, end: prog), duration: const Duration(milliseconds: 500), curve: Curves.easeOutBack,
                builder: (_, v, _) => Container(width: cs.maxWidth * v.clamp(0.0, 1.0), height: 8, decoration: BoxDecoration(color: c.accent, borderRadius: BorderRadius.circular(8), border: context.isDark ? null : Border.all(color: TickPalette.ink, width: 1)))),
          ])),
          const SizedBox(height: 8),
          Text(g.savedCents >= g.targetCents ? 'Goal reached.' : (g.perPaydayCents > 0 ? '${formatDollars(g.perPaydayCents)} each payday.' : 'Not moving money automatically.'), style: context.ts(TickType.bodyS, color: c.textSecondary)),
        ]),
      ),
    );
  }
}

class _BudgetEdit extends StatefulWidget {
  const _BudgetEdit({required this.title, required this.initial, this.onDelete});
  final String title;
  final int initial;
  final VoidCallback? onDelete;
  @override
  State<_BudgetEdit> createState() => _BudgetEditState();
}

class _BudgetEditState extends State<_BudgetEdit> {
  late String _v = widget.initial == 0 ? '' : (widget.initial / 100).toStringAsFixed(2).replaceAll(RegExp(r'\.00$'), '');
  void _key(String k) => setState(() {
        if (k == '<') { if (_v.isNotEmpty) _v = _v.substring(0, _v.length - 1); }
        else if (k == '.') { if (!_v.contains('.')) _v = _v.isEmpty ? '0.' : '$_v.'; }
        else if (_v.length < 8 && !RegExp(r'\.\d\d$').hasMatch(_v)) { _v += k; }
      });
  int get _cents => parseCents(_v.endsWith('.') ? _v.substring(0, _v.length - 1) : _v) ?? 0;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Text('${widget.title} cap', style: context.ts(TickType.displayM)),
      Text('Per month', style: context.ts(TickType.body, color: c.textSecondary)),
      const SizedBox(height: 12),
      Sticker(padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 12), child: Text('\$${_v.isEmpty ? '0' : _v}', style: context.ts(TickType.hero, color: c.onAccent, size: 52))),
      const SizedBox(height: 8),
      NumberPad(onKey: _key),
      PillButton('Add', onTap: _cents > 0 ? () => Navigator.of(context).pop(_cents) : null),
      if (widget.onDelete != null) ...[const SizedBox(height: 8), HoldToConfirm(label: 'Delete budget', danger: true, onConfirmed: widget.onDelete!)],
    ]);
  }
}

class _GoalResult {
  const _GoalResult(this.target, this.per) : deleted = false;
  const _GoalResult.deleted() : target = 0, per = 0, deleted = true;
  final int target, per;
  final bool deleted;
}

class _GoalEdit extends StatefulWidget {
  const _GoalEdit({required this.goal, required this.onDelete});
  final Goal goal;
  final VoidCallback onDelete;
  @override
  State<_GoalEdit> createState() => _GoalEditState();
}

class _GoalEditState extends State<_GoalEdit> {
  late String _target = (widget.goal.targetCents / 100).toStringAsFixed(2).replaceAll(RegExp(r'\.00$'), '');
  late String _per = widget.goal.perPaydayCents == 0 ? '' : (widget.goal.perPaydayCents / 100).toStringAsFixed(2).replaceAll(RegExp(r'\.00$'), '');
  int _field = 0;
  void _key(String k) => setState(() {
        var v = _field == 0 ? _target : _per;
        if (k == '<') { if (v.isNotEmpty) v = v.substring(0, v.length - 1); }
        else if (k == '.') { if (!v.contains('.')) v = v.isEmpty ? '0.' : '$v.'; }
        else if (v.length < 8 && !RegExp(r'\.\d\d$').hasMatch(v)) { v += k; }
        if (_field == 0) { _target = v; } else { _per = v; }
      });
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    Widget row(String t, String v, int i) => Pressable(onTap: () => setState(() => _field = i), scale: 1, child: Container(
          margin: const EdgeInsets.only(bottom: 8), padding: const EdgeInsets.symmetric(horizontal: 16), height: 52,
          decoration: BoxDecoration(color: c.surface1, borderRadius: BorderRadius.circular(999), border: Border.all(color: _field == i ? c.text : c.hairline, width: 1.5)),
          child: Row(children: [Expanded(child: Text(t, style: context.ts(TickType.title, size: 16))), Text('\$${v.isEmpty ? '0' : v}', style: context.ts(TickType.mono))])));
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Text(widget.goal.name, style: context.ts(TickType.displayM)),
      const SizedBox(height: 12),
      row('Target', _target, 0), row('Move each payday', _per, 1),
      NumberPad(onKey: _key),
      PillButton('Add', onTap: (parseCents(_target) ?? 0) > 0 ? () => Navigator.of(context).pop(_GoalResult(parseCents(_target) ?? 0, parseCents(_per) ?? 0)) : null),
      const SizedBox(height: 8),
      HoldToConfirm(label: 'Delete goal', danger: true, onConfirmed: widget.onDelete),
    ]);
  }
}
