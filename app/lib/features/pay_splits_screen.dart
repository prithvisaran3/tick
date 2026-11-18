import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../data/ledger.dart';
import '../data/pay_splits.dart';
import '../data/settings.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../design/widgets/more.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import '../domain/pay_splits.dart';
import '../services/api.dart';
import '../services/haptics.dart';
import 'common.dart';
import 'profile_screen.dart' show showToast;
import 'tally_expense_sheet.dart' show TallyField;

/// One line as it is being edited: its destination, its kind and what is typed.
class _Line {
  _Line(this.split) : field = TextEditingController(text: switch (split.kind) {
          SplitKind.percent => (split.value / 100).toStringAsFixed(split.value % 100 == 0 ? 0 : 2),
          SplitKind.fixed => formatCents(split.value, symbol: false, raw: true),
          SplitKind.rest => '',
        });
  PaySplit split;
  final TextEditingController field;
  PaySplit get current => switch (split.kind) {
        SplitKind.rest => split.copyWith(value: 0),
        SplitKind.percent => split.copyWith(value: ((double.tryParse(field.text.trim()) ?? 0) * 100).round().clamp(0, 100000)),
        SplitKind.fixed => split.copyWith(value: parseCents(field.text) ?? 0),
      };
}

/// Profile > Pay > Where it goes: one paycheck, several accounts. Every line shows its dollars as you type.
class PaySplitsScreen extends ConsumerStatefulWidget {
  const PaySplitsScreen({super.key});
  @override
  ConsumerState<PaySplitsScreen> createState() => _PaySplitsScreenState();
}

class _PaySplitsScreenState extends ConsumerState<PaySplitsScreen> {
  List<_Line>? _lines;
  ({List<PaySplit> splits, int? netCents})? _suggested;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    ref.read(paySplitsApiProvider).suggested().then((s) { if (mounted) setState(() => _suggested = s); }).catchError((_) {});
  }

  @override
  void dispose() { for (final l in _lines ?? const <_Line>[]) { l.field.dispose(); } super.dispose(); }

  void _set(List<PaySplit> splits) {
    for (final l in _lines ?? const <_Line>[]) { l.field.dispose(); }
    setState(() { _lines = [for (final s in splits) _Line(s)]; _error = null; });
  }

  List<PaySplit> get _current => [for (final l in _lines ?? const <_Line>[]) l.current];

  Future<void> _add() async {
    final l = ref.read(ledgerProvider);
    final used = {for (final s in _current) s.accountId};
    final pick = await showTickSheet<PaySplit>(context, builder: (ctx) => _AccountPicker(accounts: [for (final a in l.accounts) if ((a.type == 'checking' || a.type == 'savings') && !used.contains(a.id)) a]));
    if (pick == null || !mounted) return;
    final hasRest = _current.any((s) => s.kind == SplitKind.rest);
    setState(() => (_lines ??= []).add(_Line(pick.copyWith(kind: hasRest ? SplitKind.fixed : SplitKind.rest))));
  }

  Future<void> _save() async {
    setState(() { _busy = true; _error = null; });
    final overlay = Overlay.of(context, rootOverlay: true);
    try {
      await ref.read(paySplitsApiProvider).save(_current);
      TickHaptics.instance.confirm();
      showToast(overlay, _current.isEmpty ? 'Your paycheck goes to one account' : 'Saved. Tick expects ${_current.length} deposits on payday');
      if (mounted) context.pop();
    } catch (e) {
      if (mounted) setState(() { _busy = false; _error = describeError(e, action: 'save that'); });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final l = ref.watch(ledgerProvider);
    final rule = ref.watch(settingsProvider.select((s) => s.rule));
    final saved = ref.watch(paySplitsProvider);
    if (_lines == null && saved.hasValue) _lines = [for (final s in saved.value!) _Line(s)];
    final net = (rule?.amountCents ?? 0) > 0 ? rule!.amountCents : (_suggested?.netCents ?? 0);
    final lines = _lines ?? const <_Line>[];
    final cur = _current;
    final amounts = splitAmounts(net, cur);
    final problem = splitProblem(net, cur);
    final offer = _suggested != null && _suggested!.splits.length > 1 && lines.isEmpty;
    String name(PaySplit s) => l.account(s.accountId)?.shortLabel ?? (s.mask == null ? (s.label ?? 'Other account') : '${s.label ?? 'Other account'} ••${s.mask}');
    return TickScreen(child: ListView(padding: const EdgeInsets.only(bottom: 40), children: [
      ScreenTitle('Where it goes', onBack: () => context.pop()),
      Text(net > 0 ? '${formatCents(net)} per paycheck' : 'Set your take-home to see dollars', style: context.ts(TickType.body, color: c.textSecondary)),
      const SizedBox(height: TickSpace.x3),
      if (saved.isLoading && _lines == null) const ListSkeleton(rows: 2)
      else if (saved.hasError && _lines == null) ErrorState(onRetry: () async => ref.invalidate(paySplitsProvider))
      else if (lines.isEmpty) TickCard(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('It all lands in one account', style: context.ts(TickType.title, size: 16)),
        const SizedBox(height: 4),
        Text('Add a line for each account your paycheck is split across.', style: context.ts(TickType.bodyS, color: c.textSecondary)),
        if (offer) ...[
          const SizedBox(height: TickSpace.x3),
          Align(alignment: Alignment.centerLeft, child: TickChip('Use my last pay statement', icon: 'import', onTap: () => _set(_suggested!.splits))),
        ],
      ]))
      else for (final (i, line) in lines.indexed) Padding(padding: const EdgeInsets.only(bottom: TickSpace.x2), child: TickCard(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text(name(line.split), maxLines: 1, overflow: TextOverflow.ellipsis, style: context.ts(TickType.title, size: 16))),
          const SizedBox(width: 8),
          Semantics(liveRegion: true, child: Text(net > 0 ? formatCents(amounts[i]) : '', style: context.ts(TickType.mono))),
        ]),
        const SizedBox(height: TickSpace.x2),
        Segmented(options: const ['Percent', 'Amount', 'The rest'], index: line.split.kind.index, onChanged: (k) => setState(() {
          // one rest at a time: taking the rest here hands the old rest line an empty amount to fill in
          if (SplitKind.values[k] == SplitKind.rest) { for (final o in lines) { if (o.split.kind == SplitKind.rest) { o.split = o.split.copyWith(kind: SplitKind.fixed, value: 0); o.field.text = ''; } } }
          line.split = line.split.copyWith(kind: SplitKind.values[k]); line.field.text = ''; _error = null;
        })),
        if (line.split.kind != SplitKind.rest) Padding(padding: const EdgeInsets.only(top: TickSpace.x2), child: TallyField(
            controller: line.field, hint: line.split.kind == SplitKind.percent ? 'Percent, like 10' : 'Amount, like 500.00', label: line.split.kind == SplitKind.percent ? 'Percent of the paycheck' : 'Amount in dollars',
            keyboard: const TextInputType.numberWithOptions(decimal: true), onChanged: (_) => setState(() => _error = null))),
        Align(alignment: Alignment.centerLeft, child: Pressable(
          onTap: () => setState(() { lines.removeAt(i).field.dispose(); _error = null; }), semanticLabel: 'Remove ${name(line.split)}',
          child: Padding(padding: const EdgeInsets.only(top: 10, bottom: 2, right: 16), child: Text('Remove', style: context.ts(TickType.bodyS, color: c.textSecondary))),
        )),
      ]))),
      if (problem != null) Padding(padding: const EdgeInsets.only(top: 4, bottom: 4), child: Semantics(liveRegion: true, child: Text(problem, style: context.ts(TickType.bodyS, color: c.alert)))),
      if (_error != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(_error!, style: context.ts(TickType.bodyS, color: c.alert))),
      const SizedBox(height: TickSpace.x2),
      if (lines.length < 8) PillButton('Add an account', icon: 'plus', style: PillStyle.quiet, onTap: _add),
      const SizedBox(height: TickSpace.x2),
      if (_lines != null && (lines.isNotEmpty || (saved.value?.isNotEmpty ?? false))) PillButton('Save', busy: _busy, onTap: problem == null ? _save : null),
    ]));
  }
}

class _AccountPicker extends StatefulWidget {
  const _AccountPicker({required this.accounts});
  final List<Account> accounts;
  @override
  State<_AccountPicker> createState() => _AccountPickerState();
}

class _AccountPickerState extends State<_AccountPicker> {
  bool _other = false;
  final _name = TextEditingController();
  @override
  void dispose() { _name.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    if (_other) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Text('Another account', style: context.ts(TickType.title)),
        const SizedBox(height: 4),
        Text('One Tick doesn\'t see, like a brokerage. It won\'t count in Cash.', style: context.ts(TickType.bodyS, color: c.textSecondary)),
        const SizedBox(height: TickSpace.x3),
        TallyField(controller: _name, hint: 'Name, like Brokerage', label: 'Account name', autofocus: true, onChanged: (_) => setState(() {})),
        const SizedBox(height: TickSpace.x3),
        PillButton('Add', onTap: _name.text.trim().isEmpty ? null : () => Navigator.of(context).pop(PaySplit(label: _name.text.trim(), kind: SplitKind.fixed))),
      ]);
    }
    return SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Text('Which account?', style: context.ts(TickType.title)),
      const SizedBox(height: TickSpace.x2),
      for (final a in widget.accounts) Pressable(
        onTap: () { TickHaptics.instance.selection(); Navigator.of(context).pop(PaySplit(accountId: a.id, kind: SplitKind.fixed)); }, scale: 0.99,
        child: SizedBox(height: 52, child: Row(children: [
          Expanded(child: Text(a.shortLabel, style: context.ts(TickType.body))),
          Text(a.type == 'savings' ? 'Savings' : 'Checking', style: context.ts(TickType.bodyS, color: c.textSecondary)),
        ])),
      ),
      Pressable(
        onTap: () => setState(() => _other = true), scale: 0.99,
        child: SizedBox(height: 52, child: Align(alignment: Alignment.centerLeft, child: Text('Another account  ›', style: context.ts(TickType.body, color: c.textSecondary)))),
      ),
    ]));
  }
}
