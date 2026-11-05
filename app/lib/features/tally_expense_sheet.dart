import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/tally_store.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../design/widgets/more.dart';
import '../domain/money.dart';
import '../domain/tally.dart';
import '../services/haptics.dart';

/// A one-line text field in the app's own look (no Material). Owns its FocusNode: creating one inside build would drop focus (and the
/// keyboard) on every keystroke.
class TallyField extends StatefulWidget {
  const TallyField({super.key, required this.controller, required this.hint, this.onChanged, this.keyboard, this.autofocus = false, this.label});
  final TextEditingController controller;
  final String hint;
  final String? label;
  final ValueChanged<String>? onChanged;
  final TextInputType? keyboard;
  final bool autofocus;
  @override
  State<TallyField> createState() => _TallyFieldState();
}

class _TallyFieldState extends State<TallyField> {
  final FocusNode _focus = FocusNode();
  @override
  void dispose() { _focus.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Semantics(
      textField: true, label: widget.label ?? widget.hint,
      child: Container(
        constraints: const BoxConstraints(minHeight: 52), padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(color: c.surface1, borderRadius: BorderRadius.circular(TickRadius.card)),
        child: Stack(alignment: Alignment.centerLeft, children: [
          ListenableBuilder(listenable: widget.controller, builder: (_, _) => widget.controller.text.isEmpty ? IgnorePointer(child: Text(widget.hint, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.ts(TickType.body, color: c.textSecondary))) : const SizedBox.shrink()),
          EditableText(controller: widget.controller, focusNode: _focus, autofocus: widget.autofocus, keyboardType: widget.keyboard, style: context.ts(TickType.body), cursorColor: c.text, backgroundCursorColor: c.surface2, selectionColor: c.hairline, onChanged: widget.onChanged),
        ]),
      ),
    );
  }
}

/// Add or split an expense in a group. [prefill] comes from "Split this" on an Activity row.
Future<void> showExpenseSheet(BuildContext context, {required TallyGroup group, TallyExpense? edit, String? description, int? cents, String? transactionId, DateTime? on}) =>
    showTickSheet<void>(context, full: true, builder: (_) => ExpenseSheet(group: group, edit: edit, description: description, cents: cents, transactionId: transactionId, on: on));

class ExpenseSheet extends ConsumerStatefulWidget {
  const ExpenseSheet({super.key, required this.group, this.edit, this.description, this.cents, this.transactionId, this.on});
  final TallyGroup group;
  final TallyExpense? edit;
  final String? description;
  final int? cents;
  final String? transactionId;
  final DateTime? on;
  @override
  ConsumerState<ExpenseSheet> createState() => _ExpenseSheetState();
}

class _ExpenseSheetState extends ConsumerState<ExpenseSheet> {
  late final TextEditingController _desc, _amount;
  final Map<String, TextEditingController> _w = {};
  late SplitType _type;
  late Set<String> _in; // who shares it
  late String _paidBy;
  bool _busy = false;

  List<String> get _everyone => [me, ...widget.group.memberIds];

  @override
  void initState() {
    super.initState();
    final e = widget.edit;
    _desc = TextEditingController(text: e?.description ?? widget.description ?? '');
    final c = e?.amountCents ?? widget.cents;
    _amount = TextEditingController(text: c == null ? '' : formatCents(c, symbol: false, raw: true));
    _type = e?.splitType ?? SplitType.equal;
    _in = e != null ? e.shares.keys.toSet() : _everyone.toSet();
    _paidBy = e?.paidBy ?? me;
    if (e != null && _type != SplitType.equal) {
      for (final s in e.shares.entries) { _w[s.key] = TextEditingController(text: _type == SplitType.exact ? formatCents(s.value, symbol: false, raw: true) : (e.weights[s.key]?.toString().replaceFirst(RegExp(r'\.0$'), '') ?? '')); }
    }
  }

  @override
  void dispose() {
    _desc.dispose(); _amount.dispose();
    for (final c in _w.values) { c.dispose(); }
    super.dispose();
  }

  TextEditingController _ctl(String id) => _w.putIfAbsent(id, () => TextEditingController(text: _type == SplitType.shares ? '1' : ''));

  int get _total => parseCents(_amount.text) ?? 0;

  /// The shares for the current inputs, or null while they don't add up / are incomplete.
  Map<String, int>? get _shares {
    final who = _everyone.where(_in.contains).toList();
    if (_total <= 0 || who.isEmpty) return null;
    switch (_type) {
      case SplitType.equal: return splitEqual(_total, who);
      case SplitType.exact: return splitExact(_total, {for (final p in who) p: parseCents(_ctl(p).text) ?? 0});
      case SplitType.percent:
        final w = {for (final p in who) p: num.tryParse(_ctl(p).text) ?? 0};
        return (w.values.fold<num>(0, (a, b) => a + b) - 100).abs() > 0.001 ? null : splitWeighted(_total, w);
      case SplitType.shares: return splitWeighted(_total, {for (final p in who) p: num.tryParse(_ctl(p).text) ?? 0});
    }
  }

  String? get _hint {
    if (_total <= 0) return null;
    final who = _everyone.where(_in.contains).toList();
    if (who.isEmpty) return 'Pick at least one person.';
    if (_type == SplitType.exact) {
      final left = _total - who.fold<int>(0, (a, p) => a + (parseCents(_ctl(p).text) ?? 0));
      return left == 0 ? null : (left > 0 ? '${formatCents(left)} left to assign' : '${formatCents(-left)} over');
    }
    if (_type == SplitType.percent) {
      final left = 100 - who.fold<num>(0, (a, p) => a + (num.tryParse(_ctl(p).text) ?? 0));
      return left.abs() < 0.001 ? null : (left > 0 ? '$left% left to assign' : '${-left}% over');
    }
    return null;
  }

  Future<void> _save() async {
    final shares = _shares;
    if (shares == null || _desc.text.trim().isEmpty || _busy) return;
    setState(() => _busy = true);
    final ok = await ref.read(tallyProvider.notifier).saveExpense(TallyExpense(
        id: widget.edit?.id ?? '', groupId: widget.group.id, description: _desc.text.trim(), amountCents: _total, paidBy: _paidBy, shares: shares,
        spentOn: widget.edit?.spentOn ?? widget.on ?? DateTime.now(), splitType: _type,
        weights: _type == SplitType.percent || _type == SplitType.shares ? {for (final p in shares.keys) p: num.tryParse(_ctl(p).text) ?? 0} : const {}, transactionId: widget.edit?.transactionId ?? widget.transactionId));
    if (!mounted) return;
    if (ok) { TickHaptics.instance.confirm(); Navigator.of(context).pop(); } else { setState(() => _busy = false); }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final st = ref.watch(tallyProvider);
    final shares = _shares;
    final hint = _hint;
    return SingleChildScrollView(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Text(widget.edit == null ? 'Split an expense' : 'Edit expense', style: context.ts(TickType.title)),
        const SizedBox(height: 12),
        TallyField(controller: _desc, hint: 'What was it for?', label: 'What was it for', onChanged: (_) => setState(() {})),
        const SizedBox(height: 8),
        TallyField(controller: _amount, hint: 'Amount in dollars, like 42.50', label: 'Amount in dollars', keyboard: const TextInputType.numberWithOptions(decimal: true), onChanged: (_) => setState(() {})),
        const SizedBox(height: 16),
        Text('Paid by', style: context.ts(TickType.bodyS, color: c.textSecondary)),
        const SizedBox(height: 4),
        Wrap(spacing: 8, children: [for (final p in _everyone) TickChip(st.nameOf(p), on: _paidBy == p, onTap: () { TickHaptics.instance.selection(); setState(() => _paidBy = p); })]),
        const SizedBox(height: 12),
        Segmented(options: const ['Equal', 'Exact', 'Percent', 'Shares'], index: _type.index, onChanged: (i) { TickHaptics.instance.selection(); setState(() { _type = SplitType.values[i]; for (final w in _w.values) { w.clear(); } }); }),
        const SizedBox(height: 12),
        for (final p in _everyone) _row(context, st, p, shares),
        if (hint != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(hint, style: context.ts(TickType.bodyS, color: c.alert))),
        const SizedBox(height: 16),
        PillButton(shares == null || _desc.text.trim().isEmpty ? 'Split it' : 'Split ${formatCents(_total)}', busy: _busy, onTap: shares == null || _desc.text.trim().isEmpty ? null : _save),
      ]),
    );
  }

  Widget _row(BuildContext context, TallyState st, String p, Map<String, int>? shares) {
    final c = context.c;
    final on = _in.contains(p);
    final person = p == me ? null : st.person(p);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Pressable(
          onTap: () { TickHaptics.instance.selection(); setState(() { on ? _in.remove(p) : _in.add(p); }); }, semanticLabel: '${st.nameOf(p)}, ${on ? 'included' : 'left out'}', minSize: 44,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 24, height: 24, decoration: BoxDecoration(shape: BoxShape.circle, color: on ? c.accent : const Color(0x00000000), border: Border.all(color: on ? c.accent : c.hairline, width: 1.5)),
                child: on ? Center(child: TickIcon('check', size: 16, color: c.onAccent)) : null),
            const SizedBox(width: 10),
            Avatar(p == me ? 'Y' : (person?.name ?? '?'), person?.colorKey ?? 'biz', size: 32),
          ]),
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(st.nameOf(p), maxLines: 1, overflow: TextOverflow.ellipsis, style: context.ts(TickType.body))),
        if (on && _type != SplitType.equal)
          SizedBox(width: 92, child: TallyField(controller: _ctl(p), hint: _type == SplitType.exact ? '0.00' : _type == SplitType.percent ? '%' : 'x', label: '${st.nameOf(p)} ${_type.name}', keyboard: const TextInputType.numberWithOptions(decimal: true), onChanged: (_) => setState(() {})))
        else if (on && shares != null)
          Text(formatCents(shares[p] ?? 0), style: context.ts(TickType.mono)),
      ]),
    );
  }
}
