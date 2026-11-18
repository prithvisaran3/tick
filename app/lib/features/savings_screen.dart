import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../data/activity.dart';
import '../data/demo_seed.dart';
import '../data/nav.dart';
import '../data/ledger.dart';
import '../data/savings.dart';
import '../data/settings.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../design/widgets/more.dart';
import '../domain/payday.dart';
import '../domain/goals.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import '../services/api.dart';
import '../services/haptics.dart';
import 'common.dart';
import 'tally_expense_sheet.dart' show TallyField;
import 'tally_manage.dart' show showUndo;

/// One line under a goal: where it stands and what each paycheck has to carry.
String goalLine(GoalPlan p) {
  final g = p.goal, s = p.status;
  if (g.paused) return 'Paused';
  if (s.state == GoalState.done) return 'Done';
  if (!g.linked) return 'Link an account to track this from its balance';
  if (g.dueDate == null) return '${formatCents(s.remainingCents)} to go · no deadline';
  final by = DateFormat('MMM d').format(g.dueDate!).replaceAll(' ', '\u00a0');          // "Dec 28" never splits across lines
  if (s.paychecksLeft == 0) return '${formatCents(s.remainingCents)} short · the deadline was $by';
  if (s.state == GoalState.behind) return 'Behind by ${formatCents(s.behindByCents)} · ${formatCents(s.perPaycheckCents)} a paycheck catches up by $by';
  return 'On track · ${formatCents(s.perPaycheckCents)} a paycheck until $by';
}

/// Savings: what each account holds and where it's heading, then the goals those balances feed.
class SavingsScreen extends ConsumerWidget {
  const SavingsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final l = ref.watch(ledgerProvider);
    final now = dayOnly(ref.watch(clockProvider)());
    final hist = ref.watch(balanceHistoryProvider);
    final plans = ref.watch(goalPlansProvider);
    final accounts = l.accounts.where((a) => a.type == 'savings').toList();
    final total = accounts.fold<int>(0, (s, a) => s + (a.balanceCents ?? 0));
    final changes = [for (final a in accounts) changeThisMonth(hist.value?[a.id] ?? const [], a.balanceCents ?? 0, now)];
    final known = changes.whereType<int>().toList();
    final month = known.isEmpty ? null : known.fold<int>(0, (s, x) => s + x);
    return TickScreen(child: ListView(padding: const EdgeInsets.only(bottom: 40), children: [
      ScreenTitle('Savings', onBack: () => context.pop()),
      if (l.loading && l.accounts.isEmpty) const ListSkeleton(rows: 3)
      else ...[
        FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(formatCents(total), style: context.ts(TickType.hero))),
        Text(month == null ? 'Tick starts tracking the change from tonight\'s balance' : '${formatCents(month, sign: true)} this month', style: context.ts(TickType.body, color: c.textSecondary)),
        const SizedBox(height: TickSpace.x3),
        if (accounts.isEmpty) const TickCard(child: EmptyState('No savings account yet', 'Link one in Banks and its balance and trend show here.', icon: 'bank'))
        else TickCard(padding: const EdgeInsets.symmetric(horizontal: TickSpace.x4, vertical: TickSpace.x2), child: Column(children: [
          for (final (i, a) in accounts.indexed) ...[
            if (i > 0) const Hairline(),
            Pressable(
              onTap: () { TickHaptics.instance.selection(); openActivity(ref, ActivityQuery(accounts: {a.id})); context.pop(); }, scale: 0.99,
              semanticLabel: '${a.shortLabel}, ${formatCents(a.balanceCents ?? 0)}${changes[i] == null ? '' : ', ${formatCents(changes[i]!, sign: true)} this month'}. Show its transactions',
              child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 60), child: Row(children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text(a.shortLabel, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.ts(TickType.body)),
                  Text(changes[i] == null ? 'No history yet' : '${formatCents(changes[i]!, sign: true)} this month', style: context.ts(TickType.bodyS, color: c.textSecondary)),
                ])),
                if ((hist.value?[a.id]?.length ?? 0) >= 2 && MediaQuery.textScalerOf(context).scale(1) <= 1.3) Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: ExcludeSemantics(child: CustomPaint(size: const Size(64, 26), painter: TrendLine([for (final p in hist.value![a.id]!) p.cents], color: c.text)))),
                Flexible(child: FittedBox(fit: BoxFit.scaleDown, child: Text(formatCents(a.balanceCents ?? 0), style: context.ts(TickType.mono)))),
              ])),
            ),
          ],
        ])),
        const SizedBox(height: TickSpace.x5),
        Text('Goals', style: context.ts(TickType.bodyS, color: c.textSecondary)),
        const SizedBox(height: TickSpace.x2),
        if (plans.isEmpty) TickCard(child: Text('A goal turns a target and a date into an amount per paycheck.', style: context.ts(TickType.body, color: c.textSecondary))),
        for (final p in plans) Padding(padding: const EdgeInsets.only(bottom: TickSpace.x2), child: GoalCard(p: p, onTap: () => showGoalEditor(context, ref, p.goal))),
        const SizedBox(height: TickSpace.x2),
        PillButton('New goal', icon: 'plus', style: plans.isEmpty ? PillStyle.primary : PillStyle.quiet, onTap: () => showGoalEditor(context, ref, null)),
      ],
    ]));
  }
}

/// A goal: name, how far, a bar, and one line on where it stands.
class GoalCard extends StatelessWidget {
  const GoalCard({super.key, required this.p, this.onTap, this.trailing});
  final GoalPlan p;
  final VoidCallback? onTap;
  /// A quiet link under the line, like "All goals" on Insights.
  final String? trailing;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final s = p.status;
    final behind = s.state == GoalState.behind && !p.goal.paused;
    final shown = p.goal.mode == 'balance' && p.goal.linked ? p.goal.startCents + s.savedCents : s.savedCents;
    final of = p.goal.mode == 'balance' ? p.goal.targetCents : s.amountCents;
    return TickCard(onTap: onTap, child: Semantics(label: '${p.goal.name}. ${formatCents(shown)} of ${formatCents(of)}. ${goalLine(p)}', excludeSemantics: true, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, runSpacing: 2, children: [
        Text(p.goal.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.ts(TickType.title, size: 16)),
        Text('${formatDollars(shown)} of ${formatDollars(of)}', style: context.ts(TickType.bodyS, color: c.textSecondary)),
      ]),
      const SizedBox(height: TickSpace.x2),
      LayoutBuilder(builder: (context, box) => DecoratedBox(
        decoration: BoxDecoration(color: c.surface2, borderRadius: BorderRadius.circular(TickRadius.pill)),
        child: Align(alignment: Alignment.centerLeft, child: Container(height: 6, width: box.maxWidth * (of == 0 ? 1 : (shown / of).clamp(0.0, 1.0)), decoration: BoxDecoration(color: behind ? c.alert : c.text, borderRadius: BorderRadius.circular(TickRadius.pill)))),
      )),
      const SizedBox(height: TickSpace.x2),
      Text(goalLine(p), style: context.ts(TickType.bodyS, color: behind ? c.alert : c.textSecondary)),
      if (trailing != null) Padding(padding: const EdgeInsets.only(top: TickSpace.x2), child: Text('$trailing  ›', style: context.ts(TickType.body))),
    ])));
  }
}

/// A small line of balances over time. No axes: it only says which way it's going.
class TrendLine extends CustomPainter {
  TrendLine(this.values, {required this.color});
  final List<int> values;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final lo = values.reduce((a, b) => a < b ? a : b), hi = values.reduce((a, b) => a > b ? a : b);
    final span = hi - lo == 0 ? 1 : hi - lo;
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = size.width * i / (values.length - 1);
      final y = hi == lo ? size.height / 2 : size.height - 2 - (size.height - 4) * (values[i] - lo) / span;
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(path, Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 2..strokeCap = StrokeCap.round..strokeJoin = StrokeJoin.round);
  }
  @override
  bool shouldRepaint(TrendLine old) => old.values != values || old.color != color;
}

Future<void> showGoalEditor(BuildContext context, WidgetRef ref, Goal? g) => showTickSheet<void>(context, full: true, builder: (_) => _GoalEditor(goal: g));

class _GoalEditor extends ConsumerStatefulWidget {
  const _GoalEditor({this.goal});
  final Goal? goal;
  @override
  ConsumerState<_GoalEditor> createState() => _GoalEditorState();
}

class _GoalEditorState extends ConsumerState<_GoalEditor> {
  late final _name = TextEditingController(text: widget.goal?.name ?? '');
  late final _target = TextEditingController(text: widget.goal == null ? '' : formatCents(widget.goal!.targetCents, symbol: false, raw: true));
  late final _due = TextEditingController(text: widget.goal?.dueDate == null ? '' : DateFormat('MM/dd/yyyy').format(widget.goal!.dueDate!));
  late String _mode = widget.goal?.mode ?? 'save_more';
  late Set<String> _accounts = {...?widget.goal?.accountIds};
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.goal == null) _accounts = {for (final a in ref.read(ledgerProvider).accounts) if (a.type == 'savings') a.id};
  }

  @override
  void dispose() { _name.dispose(); _target.dispose(); _due.dispose(); super.dispose(); }

  DateTime? get _deadline { try { return _due.text.trim().isEmpty ? null : DateFormat('MM/dd/yyyy').parseStrict(_due.text.trim()); } catch (_) { return null; } }

  /// The goal as typed, measured from today's balance when it's new or its accounts changed.
  Goal? _draft(DateTime today) {
    final target = parseCents(_target.text) ?? 0;
    if (_name.text.trim().isEmpty || target <= 0) return null;
    final l = ref.read(ledgerProvider);
    final old = widget.goal;
    final ids = _accounts.toList()..sort();
    final same = old != null && old.linked && old.mode == _mode && old.accountIds.toSet().containsAll(ids) && ids.length == old.accountIds.length;
    final linked = l.accounts.where((a) => ids.contains(a.id)).fold<int>(0, (s, a) => s + (a.balanceCents ?? 0));
    return Goal(id: old?.id ?? 'local-g-${DateTime.now().microsecondsSinceEpoch}', name: _name.text.trim(), targetCents: target, savedCents: old?.savedCents ?? 0, perPaydayCents: old?.perPaydayCents ?? 0,
        paused: old?.paused ?? false, mode: _mode, startCents: same ? old.startCents : linked, startDate: same ? old.startDate : today, dueDate: _deadline, accountIds: ids);
  }

  Future<void> _save() async {
    final today = dayOnly(ref.read(clockProvider)());
    final g = _draft(today);
    if (g == null) { setState(() => _error = 'A name and an amount, please.'); return; }
    if (_due.text.trim().isNotEmpty && _deadline == null) { setState(() => _error = 'Enter the deadline as MM/DD/YYYY, or leave it empty.'); return; }
    if (_deadline != null && !_deadline!.isAfter(today)) { setState(() => _error = 'Pick a deadline after today.'); return; }
    if (g.accountIds.isEmpty) { setState(() => _error = 'Pick the account this goal is saved in.'); return; }
    if (g.mode == 'balance' && g.targetCents <= g.startCents) { setState(() => _error = 'That account already holds ${formatCents(g.startCents)}. Pick a higher balance, or use Save this much.'); return; }
    setState(() { _busy = true; _error = null; });
    try {
      await ref.read(ledgerProvider.notifier).saveGoal(g);
      TickHaptics.instance.confirm();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() { _busy = false; _error = describeError(e, action: 'save that'); });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final l = ref.watch(ledgerProvider);
    final today = dayOnly(ref.watch(clockProvider)());
    final s = ref.watch(settingsProvider);
    final rule = s.demoMode ? demoPaydayRule(today) : s.rule;
    final g = widget.goal;
    final draft = _draft(today);
    final preview = draft == null || !draft.linked ? null : planGoal(draft, l.accounts, rule, today);
    Widget label(String t) => Padding(padding: const EdgeInsets.only(top: TickSpace.x3, bottom: 6), child: Text(t, style: context.ts(TickType.bodyS, color: c.textSecondary)));
    return SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Text(g == null ? 'New goal' : 'Edit goal', style: context.ts(TickType.title)),
      label('Name'),
      TallyField(controller: _name, hint: 'Like Emergency fund', label: 'Goal name', onChanged: (_) => setState(() => _error = null)),
      label('What counts as done'),
      Segmented(options: const ['Save this much', 'Reach a balance'], index: _mode == 'save_more' ? 0 : 1, onChanged: (i) => setState(() { _mode = i == 0 ? 'save_more' : 'balance'; _error = null; })),
      label(_mode == 'save_more' ? 'How much more, from today' : 'The balance to reach'),
      TallyField(controller: _target, hint: '9000.00', label: 'Amount in dollars', keyboard: const TextInputType.numberWithOptions(decimal: true), onChanged: (_) => setState(() => _error = null)),
      label('Deadline (optional)'),
      TallyField(controller: _due, hint: 'MM/DD/YYYY', label: 'Deadline', keyboard: TextInputType.datetime, onChanged: (_) => setState(() => _error = null)),
      label('Saved in'),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final a in l.accounts.where((a) => a.type == 'savings' || a.type == 'checking'))
          TickChip(a.shortLabel, on: _accounts.contains(a.id), onTap: () => setState(() { _accounts.contains(a.id) ? _accounts.remove(a.id) : _accounts.add(a.id); _error = null; })),
      ]),
      if (preview != null && preview.goal.dueDate != null && preview.status.state != GoalState.done) Padding(padding: const EdgeInsets.only(top: TickSpace.x3), child: Semantics(liveRegion: true, child: Text(
          preview.status.paychecksLeft == 0 ? 'No paychecks land before that date.' : '${preview.status.paychecksLeft} ${preview.status.paychecksLeft == 1 ? 'paycheck' : 'paychecks'} left · ${formatCents(preview.status.perPaycheckCents)} each',
          style: context.ts(TickType.title, size: 16)))),
      if (_error != null) Padding(padding: const EdgeInsets.only(top: TickSpace.x2), child: Text(_error!, style: context.ts(TickType.bodyS, color: c.alert))),
      const SizedBox(height: TickSpace.x4),
      PillButton('Save', busy: _busy, onTap: _save),
      if (g != null) ...[
        const SizedBox(height: TickSpace.x2),
        Row(children: [
          Expanded(child: PillButton(g.paused ? 'Resume' : 'Pause', style: PillStyle.quiet, height: 48, onTap: () async { await ref.read(ledgerProvider.notifier).saveGoal(g.copyWith(paused: !g.paused)); if (context.mounted) Navigator.of(context).pop(); })),
          const SizedBox(width: 8),
          Expanded(child: PillButton('Delete', style: PillStyle.quiet, height: 48, onTap: () async {
            final overlay = Overlay.of(context, rootOverlay: true);
            final n = ref.read(ledgerProvider.notifier);
            await n.deleteGoal(g.id);
            showUndo(overlay, '${g.name} deleted', () => n.saveGoal(Goal(id: 'local-g-${DateTime.now().microsecondsSinceEpoch}', name: g.name, targetCents: g.targetCents, savedCents: g.savedCents,
                perPaydayCents: g.perPaydayCents, paused: g.paused, mode: g.mode, startCents: g.startCents, startDate: g.startDate, dueDate: g.dueDate, accountIds: g.accountIds)));
            if (context.mounted) Navigator.of(context).pop();
          })),
        ]),
      ],
    ]));
  }
}

/// Payday on Home: one card, one number, one button. "Done" is checked against the next balance sync.
class MoveToSavingsCard extends ConsumerStatefulWidget {
  const MoveToSavingsCard({super.key});
  @override
  ConsumerState<MoveToSavingsCard> createState() => _MoveToSavingsCardState();
}

class _MoveToSavingsCardState extends ConsumerState<MoveToSavingsCard> {
  bool _busy = false;
  String? _error;
  Future<void> _run(Future<void> Function() f) async {
    setState(() { _busy = true; _error = null; });
    try { await f(); TickHaptics.instance.confirm(); } catch (e) { if (mounted) setState(() => _error = describeError(e, action: 'save that')); }
    if (mounted) setState(() => _busy = false);
  }
  @override
  Widget build(BuildContext context) {
    final m = ref.watch(paydayMoveProvider);
    if (m == null) return const SizedBox.shrink();
    final c = context.c;
    final moves = ref.read(goalMovesProvider.notifier);
    final (title, body) = switch (m.state) {
      MoveState.none => ('Move ${formatCents(m.cents)} to savings', 'That keeps your goals on time this paycheck.'),
      MoveState.done => ('Marked moved', 'Tick checks it against your next savings balance.'),
      _ => ('Tick hasn\'t seen it reach savings', 'The balance hasn\'t gone up yet. Transfers can take a day or two.'),
    };
    return Padding(padding: const EdgeInsets.only(bottom: TickSpace.x3), child: TickCard(onTap: () => context.push('/savings'), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(title, style: context.ts(TickType.title)),
      const SizedBox(height: 2),
      Text(body, style: context.ts(TickType.bodyS, color: c.textSecondary)),
      const SizedBox(height: TickSpace.x3),
      if (m.state == MoveState.none) PillButton('Done', height: 48, busy: _busy, onTap: () => _run(() => moves.markDone(m.payday, m.cents)))
      else Align(alignment: Alignment.centerLeft, child: Pressable(
        onTap: _busy ? null : () => _run(() => moves.undo(m.payday)), semanticLabel: 'Undo marking it moved',
        child: Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Text('Not moved yet? Undo', style: context.ts(TickType.bodyS, color: c.textSecondary))),
      )),
      if (_error != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(_error!, style: context.ts(TickType.bodyS, color: c.alert))),
    ])));
  }
}
