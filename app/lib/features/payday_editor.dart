import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../data/ledger.dart';
import '../data/settings.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../design/widgets/more.dart';
import '../design/widgets/pickers.dart';
import '../design/widgets/scaffold.dart';
import '../domain/dates.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import '../domain/payday.dart';
import '../services/haptics.dart';
import 'tally_expense_sheet.dart' show TallyField;

const payFrequencies = [PayFrequency.weekly, PayFrequency.biweekly, PayFrequency.semimonthly, PayFrequency.monthly];

/// How often, one date (or two days of the month), and a live preview before anything is saved.
class PaydayEditor extends StatefulWidget {
  const PaydayEditor({super.key, required this.today, required this.onChanged, this.initial});
  final DateTime today;
  final PaydayRule? initial;
  final ValueChanged<PaydayRule> onChanged;
  @override
  State<PaydayEditor> createState() => _PaydayEditorState();
}

class _PaydayEditorState extends State<PaydayEditor> {
  late PayFrequency _f = widget.initial?.frequency ?? PayFrequency.biweekly;
  late DateTime _anchor = widget.initial == null ? _nextFriday() : nextPayday(widget.initial!, widget.today);
  late List<int> _days = widget.initial?.days ?? const [15, 30];

  DateTime _nextFriday() {
    var d = dayOnly(widget.today);
    while (d.weekday != DateTime.friday) { d = addDays(d, 1); }
    return d;
  }

  PaydayRule get rule => PaydayRule(frequency: _f, anchor: _anchor, amountCents: widget.initial?.amountCents ?? 0, days: _f == PayFrequency.semimonthly ? _days : null);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) widget.onChanged(rule); });
  }

  void _set(VoidCallback f) { TickHaptics.instance.selection(); setState(f); widget.onChanged(rule); }

  Future<void> _pickDate() async {
    final d = await showDateSheet(context, initial: _anchor);
    if (d != null) _set(() => _anchor = dayOnly(d));
  }

  Future<void> _pickDay(int i) async {
    final v = await showTickSheet<int>(context, builder: (ctx) => Wrap(spacing: 6, runSpacing: 6, children: [
      for (var d = 1; d <= 31; d++) TickChip(d == 31 ? 'Last' : '$d', on: _days[i] == d, onTap: () => Navigator.of(ctx).pop(d)),
    ]));
    if (v != null) _set(() => _days = ([..._days]..[i] = v)..sort());
  }

  String _ord(int d) => d == 31 ? 'last day' : '$d${d % 100 >= 11 && d % 100 <= 13 ? 'th' : const ['th', 'st', 'nd', 'rd', 'th', 'th', 'th', 'th', 'th', 'th'][d % 10]}';

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final p = payPreview(rule, widget.today);
    final fmt = DateFormat('MMM d');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Segmented(options: const ['Weekly', 'Biweekly', 'Twice a month', 'Monthly'], index: payFrequencies.indexOf(_f), onChanged: (i) => _set(() => _f = payFrequencies[i])),
      const SizedBox(height: 12),
      if (_f == PayFrequency.semimonthly) ...[
        Text('Which two days?', style: context.ts(TickType.bodyS, color: c.textSecondary)),
        const SizedBox(height: 4),
        Wrap(spacing: 8, children: [TickChip('The ${_ord(_days[0])}', icon: 'calendar', onTap: () => _pickDay(0)), TickChip('The ${_ord(_days[1])}', icon: 'calendar', onTap: () => _pickDay(1))]),
        const SizedBox(height: 4),
        Text('On a weekend or holiday, it counts as the business day before.', style: context.ts(TickType.bodyS, size: 12.5, color: c.textSecondary)),
      ] else ...[
        Text('When\'s your next payday?', style: context.ts(TickType.bodyS, color: c.textSecondary)),
        const SizedBox(height: 4),
        Align(alignment: Alignment.centerLeft, child: TickChip(DateFormat('EEE MMM d').format(_anchor), icon: 'calendar', on: true, onTap: _pickDate)),
      ],
      const SizedBox(height: 12),
      Semantics(container: true, label: 'Current period ${fmt.format(p.period.start)} to ${fmt.format(p.period.end)}. Next paydays ${p.next.map(fmt.format).join(', ')}.', excludeSemantics: true,
        child: TickCard(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text('Current period', style: context.ts(TickType.bodyS, color: c.textSecondary))),
            Flexible(child: Text('${fmt.format(p.period.start)} – ${fmt.format(p.period.end)}', textAlign: TextAlign.right, style: context.ts(TickType.monoS))),
          ]),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(child: Text('Next paydays', style: context.ts(TickType.bodyS, color: c.textSecondary))),
            Flexible(flex: 2, child: Text(p.next.map(fmt.format).join(', '), textAlign: TextAlign.right, style: context.ts(TickType.monoS))),
          ]),
        ])),
      ),
    ]);
  }
}

/// Settings > Payday.
class PaydayScreen extends ConsumerStatefulWidget {
  const PaydayScreen({super.key});
  @override
  ConsumerState<PaydayScreen> createState() => _PaydayScreenState();
}

class _PaydayScreenState extends ConsumerState<PaydayScreen> {
  PaydayRule? _rule;
  late final _amount = TextEditingController(text: () {
    final c = ref.read(settingsProvider).rule?.amountCents ?? 0;
    return c == 0 ? '' : formatCents(c, symbol: false, raw: true);
  }());
  @override
  void dispose() { _amount.dispose(); super.dispose(); }

  void _save() {
    final r = _rule;
    if (r == null) return;
    ref.read(settingsProvider.notifier).update((s) => s.copyWith(rule: PaydayRule(frequency: r.frequency, anchor: r.anchor, amountCents: parseCents(_amount.text) ?? 0, days: r.days)));
    Future<void>.delayed(const Duration(seconds: 1), () => ref.invalidate(payPeriodProvider));      // after the save has reached the server
    TickHaptics.instance.confirm();
    context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final now = ref.watch(clockProvider)();
    return TickPage(title: 'Payday', onBack: () => context.pop(), children: [
      PaydayEditor(today: now, initial: ref.read(settingsProvider).rule, onChanged: (r) => _rule = r),
      const SizedBox(height: 12),
      TallyField(controller: _amount, hint: 'Take-home per paycheck', label: 'Take-home per paycheck', keyboard: const TextInputType.numberWithOptions(decimal: true)),
      const SizedBox(height: 16),
      PillButton('Save', onTap: _save),
    ]);
  }
}
