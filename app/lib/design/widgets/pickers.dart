import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';
import '../../domain/calendar.dart';
import '../../domain/money.dart';
import '../theme.dart';
import '../tokens.g.dart';
import 'core.dart';
import 'motion.dart';
import 'more.dart';

/// Custom month-grid date picker in a sheet. Returns the picked day.
Future<DateTime?> showDateSheet(BuildContext context, {required DateTime initial, DateTime? first}) {
  return showTickSheet<DateTime>(context, builder: (ctx) => _DateSheet(initial: initial, first: first));
}

class _DateSheet extends StatefulWidget {
  const _DateSheet({required this.initial, this.first});
  final DateTime initial;
  final DateTime? first;
  @override
  State<_DateSheet> createState() => _DateSheetState();
}

class _DateSheetState extends State<_DateSheet> {
  late DateTime _month = DateTime(widget.initial.year, widget.initial.month, 1);
  late DateTime _sel = widget.initial;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final cells = monthCells(_month);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        Pressable(onTap: () => setState(() => _month = addMonths(_month, -1)), semanticLabel: 'Previous month', child: SizedBox(width: 44, height: 44, child: Center(child: TickIcon('chevron-left', color: c.text)))),
        Expanded(child: Center(child: Text(DateFormat('MMMM yyyy').format(_month), style: context.ts(TickType.title)))),
        Pressable(onTap: () => setState(() => _month = addMonths(_month, 1)), semanticLabel: 'Next month', child: SizedBox(width: 44, height: 44, child: Center(child: TickIcon('chevron-right', color: c.text)))),
      ]),
      const SizedBox(height: 8),
      Row(children: [for (final d in 'SMTWTFS'.split('')) Expanded(child: Center(child: Text(d, style: context.ts(TickType.bodyS, size: 12, color: c.textSecondary))))]),
      const SizedBox(height: 4),
      GridView.count(
        crossAxisCount: 7, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), padding: EdgeInsets.zero, childAspectRatio: 1.15,
        children: [
          for (final d in cells)
            if (d == null) const SizedBox() else _Day(d: d, selected: d.year == _sel.year && d.month == _sel.month && d.day == _sel.day, enabled: widget.first == null || !d.isBefore(widget.first!), onTap: () => setState(() => _sel = d)),
        ],
      ),
      const SizedBox(height: 12),
      PillButton('Add', onTap: () => Navigator.of(context).pop(_sel)),
    ]);
  }
}

class _Day extends StatelessWidget {
  const _Day({required this.d, required this.selected, required this.enabled, required this.onTap});
  final DateTime d;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Pressable(
      onTap: enabled ? onTap : null, scale: 0.9, semanticLabel: DateFormat('EEEE MMMM d').format(d),
      child: Center(
        child: Container(
          width: 40, height: 40, alignment: Alignment.center,
          decoration: BoxDecoration(color: selected ? c.accent : const Color(0x00000000), shape: BoxShape.circle, border: selected && !context.isDark ? Border.all(color: TickPalette.ink, width: 1.5) : null),
          child: Text('${d.day}', style: context.ts(TickType.mono, color: selected ? c.onAccent : (enabled ? c.text : c.textSecondary.withValues(alpha: 0.4)))),
        ),
      ),
    );
  }
}

/// Number-pad sheet that returns cents (or null if dismissed).
Future<int?> showAmountSheet(BuildContext context, {required String title, int initialCents = 0, String confirm = 'Add'}) {
  return showTickSheet<int>(context, full: true, builder: (ctx) => _AmountSheet(title: title, initialCents: initialCents, confirm: confirm));
}

class _AmountSheet extends StatefulWidget {
  const _AmountSheet({required this.title, required this.initialCents, required this.confirm});
  final String title;
  final int initialCents;
  final String confirm;
  @override
  State<_AmountSheet> createState() => _AmountSheetState();
}

class _AmountSheetState extends State<_AmountSheet> {
  late String _v = widget.initialCents == 0 ? '' : (widget.initialCents / 100).toStringAsFixed(2).replaceAll(RegExp(r'\.00$'), '');
  void _key(String k) => setState(() {
        if (k == '<') { if (_v.isNotEmpty) _v = _v.substring(0, _v.length - 1); }
        else if (k == '.') { if (!_v.contains('.')) _v = _v.isEmpty ? '0.' : '$_v.'; }
        else if (_v.length < 9 && !RegExp(r'\.\d\d$').hasMatch(_v)) { _v += k; }
      });
  int get _cents => parseCents(_v.endsWith('.') ? _v.substring(0, _v.length - 1) : _v) ?? 0;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Text(widget.title, style: context.ts(TickType.displayM)),
      const SizedBox(height: 16),
      Sticker(padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 12), child: RollingDigits('\$${_v.isEmpty ? '0' : _v}', style: context.ts(TickType.hero, color: c.onAccent, size: 52))),
      const SizedBox(height: 8),
      NumberPad(onKey: _key),
      PillButton(widget.confirm, onTap: _cents > 0 ? () => Navigator.of(context).pop(_cents) : null),
    ]);
  }
}

/// One-line text prompt sheet (category names, goal names).
Future<String?> showTextSheet(BuildContext context, {required String title, String initial = '', String hint = '', String confirm = 'Add'}) {
  return showTickSheet<String>(context, builder: (ctx) => _TextSheet(title: title, initial: initial, hint: hint, confirm: confirm));
}

class _TextSheet extends StatefulWidget {
  const _TextSheet({required this.title, required this.initial, required this.hint, required this.confirm});
  final String title, initial, hint, confirm;
  @override
  State<_TextSheet> createState() => _TextSheetState();
}

class _TextSheetState extends State<_TextSheet> {
  late final _ctl = TextEditingController(text: widget.initial);
  final _focus = FocusNode();
  @override
  void dispose() { _ctl.dispose(); _focus.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(widget.title, style: context.ts(TickType.displayM)),
      const SizedBox(height: 16),
      Container(
        height: 52, padding: const EdgeInsets.symmetric(horizontal: 16), decoration: BoxDecoration(color: c.surface1, borderRadius: BorderRadius.circular(999)),
        child: Stack(alignment: Alignment.centerLeft, children: [
          if (_ctl.text.isEmpty) IgnorePointer(child: Text(widget.hint, style: context.ts(TickType.body, color: c.textSecondary))),
          EditableText(controller: _ctl, focusNode: _focus, autofocus: true, style: context.ts(TickType.body), cursorColor: c.text, backgroundCursorColor: c.surface2, selectionColor: c.hairline, onChanged: (_) => setState(() {}), onSubmitted: (v) { if (v.trim().isNotEmpty) Navigator.of(context).pop(v.trim()); }),
        ]),
      ),
      const SizedBox(height: 16),
      PillButton(widget.confirm, onTap: _ctl.text.trim().isEmpty ? null : () => Navigator.of(context).pop(_ctl.text.trim())),
    ]);
  }
}
