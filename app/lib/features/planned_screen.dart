import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../data/ledger.dart';
import '../data/planned.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../design/widgets/more.dart';
import '../domain/money.dart';
import '../domain/payday.dart';
import '../domain/planned.dart';
import '../services/api.dart';
import '../services/haptics.dart';
import 'common.dart';
import 'tally_expense_sheet.dart' show TallyField;
import 'tally_manage.dart' show showUndo;

/// The trade-off in one line.
String tradeOffLine(TradeOff t) => '${t.expense.name} leaves ${formatCents(t.shortfallCents)} less for ${t.goal.name} this paycheck.';

/// One-offs I know are coming. Each comes out of Safe to spend for its pay period until the real purchase shows up.
class PlannedScreen extends ConsumerWidget {
  const PlannedScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final planned = ref.watch(plannedProvider);
    final t = ref.watch(tradeOffProvider);
    final sts = ref.watch(safeToSpendProvider);
    final open = [for (final p in planned.value ?? const <PlannedExpense>[]) if (p.open) p];
    return TickScreen(child: ListView(padding: const EdgeInsets.only(bottom: 40), children: [
      ScreenTitle('Planned', onBack: () => context.pop()),
      Text(sts == null ? 'One-off expenses you know are coming' : '${formatCents(sts.plannedCents)} set aside this pay period', style: context.ts(TickType.body, color: c.textSecondary)),
      const SizedBox(height: TickSpace.x3),
      if (t != null) Padding(padding: const EdgeInsets.only(bottom: TickSpace.x3), child: TradeOffCard(t: t)),
      if (planned.isLoading && !planned.hasValue) const ListSkeleton(rows: 2)
      else if (planned.hasError && !planned.hasValue) ErrorState(onRetry: () async => ref.invalidate(plannedProvider))
      else if (open.isEmpty) const TickCard(child: EmptyState('Nothing planned', 'Add a gift, a trip or a repair and Tick takes it out of Safe to spend ahead of time.', icon: 'calendar'))
      else TickCard(padding: const EdgeInsets.symmetric(horizontal: TickSpace.x4, vertical: TickSpace.x2), child: Column(children: [
        for (final (i, p) in open.indexed) ...[
          if (i > 0) const Hairline(),
          Pressable(
            onTap: () => _remove(context, ref, p), scale: 0.99, semanticLabel: '${p.name}, ${formatCents(p.amountCents)}, ${DateFormat('MMM d').format(p.due)}. Remove',
            child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 60), child: Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.ts(TickType.body)),
                Text(sts != null && countsThisPeriod(p, dayOnly(ref.watch(clockProvider)()), sts.nextPayday) ? '${DateFormat('MMM d').format(p.due)} · this pay period' : DateFormat('MMM d').format(p.due), style: context.ts(TickType.bodyS, color: c.textSecondary)),
              ])),
              const SizedBox(width: 8),
              Text(formatCents(p.amountCents), style: context.ts(TickType.mono)),
            ])),
          ),
        ],
      ])),
      const SizedBox(height: TickSpace.x3),
      PillButton('Plan a one-off', icon: 'plus', style: open.isEmpty ? PillStyle.primary : PillStyle.quiet, onTap: () => showPlanSheet(context, ref)),
    ]));
  }

  Future<void> _remove(BuildContext context, WidgetRef ref, PlannedExpense p) async {
    final ok = await showTickSheet<bool>(context, builder: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Text('${p.name} · ${formatCents(p.amountCents)}', style: ctx.ts(TickType.title)),
      const SizedBox(height: 4),
      Text('Removing it puts ${formatCents(p.amountCents)} back in Safe to spend.', style: ctx.ts(TickType.body, color: ctx.c.textSecondary)),
      const SizedBox(height: TickSpace.x3),
      PillButton('Remove', onTap: () => Navigator.of(ctx).pop(true)),
      const SizedBox(height: TickSpace.x2),
      PillButton('Keep it', style: PillStyle.quiet, onTap: () => Navigator.of(ctx).pop(false)),
    ]));
    if (ok != true || !context.mounted) return;
    final overlay = Overlay.of(context, rootOverlay: true);
    final n = ref.read(plannedProvider.notifier);
    try {
      await n.remove(p);
      showUndo(overlay, '${p.name} removed', () => n.restore(p));
    } catch (_) {/* it stays on the list */}
  }
}

/// One line, two choices. Whichever I pick updates the plan; nothing happens until then.
class TradeOffCard extends ConsumerStatefulWidget {
  const TradeOffCard({super.key, required this.t});
  final TradeOff t;
  @override
  ConsumerState<TradeOffCard> createState() => _TradeOffCardState();
}

class _TradeOffCardState extends ConsumerState<TradeOffCard> {
  bool _busy = false;
  String? _error;
  Future<void> _pick(bool moveDeadline) async {
    setState(() { _busy = true; _error = null; });
    try {
      await ref.read(plannedProvider.notifier).resolve(widget.t, moveDeadline: moveDeadline);
      TickHaptics.instance.confirm();
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e, action: 'save that'));
    }
    if (mounted) setState(() => _busy = false);
  }
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final t = widget.t;
    return TickCard(raised: true, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(tradeOffLine(t), style: context.ts(TickType.title, size: 16)),
      const SizedBox(height: TickSpace.x3),
      PillButton('Add ${t.addPerLaterCents % 100 == 0 ? formatDollars(t.addPerLaterCents) : formatCents(t.addPerLaterCents)} to later paychecks', height: 48, busy: _busy, onTap: () => _pick(false)),
      if (t.newDeadline != null) ...[
        const SizedBox(height: TickSpace.x2),
        PillButton('Move deadline to ${DateFormat('MMM d').format(t.newDeadline!)}', height: 48, style: PillStyle.quiet, onTap: _busy ? null : () => _pick(true)),
      ],
      if (_error != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(_error!, style: context.ts(TickType.bodyS, color: c.alert))),
    ]));
  }
}

Future<void> showPlanSheet(BuildContext context, WidgetRef ref) => showTickSheet<void>(context, builder: (_) => const _PlanSheet());

class _PlanSheet extends ConsumerStatefulWidget {
  const _PlanSheet();
  @override
  ConsumerState<_PlanSheet> createState() => _PlanSheetState();
}

class _PlanSheetState extends ConsumerState<_PlanSheet> {
  final _name = TextEditingController(), _amount = TextEditingController();
  late final _date = TextEditingController(text: DateFormat('MM/dd/yyyy').format(ref.read(clockProvider)()));
  String? _error;
  bool _busy = false;
  @override
  void dispose() { _name.dispose(); _amount.dispose(); _date.dispose(); super.dispose(); }

  Future<void> _save() async {
    final cents = parseCents(_amount.text) ?? 0;
    DateTime? due;
    try { due = DateFormat('MM/dd/yyyy').parseStrict(_date.text.trim()); } catch (_) {}
    final today = dayOnly(ref.read(clockProvider)());
    if (_name.text.trim().isEmpty || cents <= 0) { setState(() => _error = 'A name and an amount, please.'); return; }
    if (due == null) { setState(() => _error = 'Enter the date as MM/DD/YYYY.'); return; }
    if (due.isBefore(today)) { setState(() => _error = 'Pick today or a later date.'); return; }
    setState(() { _busy = true; _error = null; });
    try {
      await ref.read(plannedProvider.notifier).add(_name.text.trim(), cents, due);
      TickHaptics.instance.confirm();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() { _busy = false; _error = describeError(e, action: 'save that'); });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    Widget label(String t) => Padding(padding: const EdgeInsets.only(top: TickSpace.x3, bottom: 6), child: Text(t, style: context.ts(TickType.bodyS, color: c.textSecondary)));
    return SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Text('Plan a one-off', style: context.ts(TickType.title)),
      label('What is it'),
      TallyField(controller: _name, hint: 'Like Birthday gift', label: 'Name', autofocus: true, onChanged: (_) => setState(() => _error = null)),
      label('How much'),
      TallyField(controller: _amount, hint: '500.00', label: 'Amount in dollars', keyboard: const TextInputType.numberWithOptions(decimal: true), onChanged: (_) => setState(() => _error = null)),
      label('When'),
      TallyField(controller: _date, hint: 'MM/DD/YYYY', label: 'Date', keyboard: TextInputType.datetime, onChanged: (_) => setState(() => _error = null)),
      if (_error != null) Padding(padding: const EdgeInsets.only(top: TickSpace.x2), child: Text(_error!, style: context.ts(TickType.bodyS, color: c.alert))),
      const SizedBox(height: TickSpace.x4),
      PillButton('Add to the plan', busy: _busy, onTap: _save),
    ]));
  }
}
