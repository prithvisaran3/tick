import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/ledger.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../design/widgets/more.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import '../domain/natural_input.dart';
import 'package:image_picker/image_picker.dart';
import '../services/api.dart';
import '../services/haptics.dart';

/// Quick add: custom number pad (amount, merchant, Add = 3 taps) plus one-line natural input.
Future<void> showQuickAdd(BuildContext context, {int? prefillCents, String? prefillMerchant}) =>
    showTickSheet<void>(context, full: true, builder: (_) => QuickAdd(prefillCents: prefillCents, prefillMerchant: prefillMerchant));

class QuickAdd extends ConsumerStatefulWidget {
  const QuickAdd({super.key, this.prefillCents, this.prefillMerchant});
  final int? prefillCents;
  final String? prefillMerchant;
  @override
  ConsumerState<QuickAdd> createState() => _QuickAddState();
}

class _QuickAddState extends ConsumerState<QuickAdd> {
  String _amount = '';
  bool _income = false;
  late final TextEditingController _line = TextEditingController(text: widget.prefillMerchant ?? '');
  final _focus = FocusNode();
  ParsedEntry? _parsed;
  String? _receiptPath;
  String? _scanMsg;

  Future<void> _scan() async {
    try {
      final x = await ImagePicker().pickImage(source: ImageSource.camera, maxWidth: 1800, imageQuality: 80);
      if (x == null) return;
      setState(() => _scanMsg = 'Reading receipt…');
      final j = await ref.read(apiProvider).postFile('/receipts/scan', 'file', await x.readAsBytes(), 'receipt.jpg');
      _receiptPath = j['path'] as String?;
      final e = j['extracted'] as Map<String, dynamic>?;
      setState(() {
        _scanMsg = e == null ? 'Saved the photo. Type the total to finish.' : null;
        if (e != null) {
          final t = (e['total'] as num?)?.toDouble();
          if (t != null) _amount = t.toStringAsFixed(2).replaceAll(RegExp(r'\.00$'), '');
          _line.text = (e['merchant'] ?? '').toString();
        }
      });
    } catch (e) {
      if (mounted) setState(() => _scanMsg = describeError(e, action: 'read that receipt'));
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.prefillCents != null) _amount = (widget.prefillCents!.abs() / 100).toStringAsFixed(2).replaceAll(RegExp(r'\.00$'), '');
  }

  @override
  void dispose() { _line.dispose(); _focus.dispose(); super.dispose(); }

  void _key(String k) {
    setState(() {
      if (k == '<') { if (_amount.isNotEmpty) _amount = _amount.substring(0, _amount.length - 1); }
      else if (k == '.') { if (!_amount.contains('.')) _amount = _amount.isEmpty ? '0.' : '$_amount.'; }
      else if (_amount.length < 9 && !(RegExp(r'\.\d\d$').hasMatch(_amount))) { _amount += k; }
    });
  }

  int get _cents => parseCents(_amount.endsWith('.') ? _amount.substring(0, _amount.length - 1) : _amount) ?? 0;

  Future<void> _submit() async {
    final n = ref.read(ledgerProvider.notifier);
    final now = ref.read(clockProvider)();
    final text = _line.text.trim();
    // One-line natural input wins when it parses and no amount was typed on the pad.
    if (_cents == 0 && text.isNotEmpty) {
      final p = parseNatural(text, now);
      if (p == null) return;
      final cat = p.categoryHint == null ? null : ref.read(ledgerProvider).categoryByName(p.categoryHint!)?.id;
      if (p.isRecurring) {
        await n.addRecurring(Recurring(id: 'local-r-${now.microsecondsSinceEpoch}', merchant: p.merchant, cadence: Cadence.monthly, expectedCents: p.amountCents.abs(), nextDate: nextDayOfMonth(p.recurringDayOfMonth!, now), categoryId: cat, priceHistory: [p.amountCents.abs()]));
      } else {
        await n.add(amountCents: p.amountCents, merchant: p.merchant, at: p.date?.add(const Duration(hours: 12)), categoryId: cat);
      }
      TickHaptics.instance.capturePop(p.amountCents);
      if (mounted) Navigator.of(context).pop();
      return;
    }
    if (_cents == 0) return;
    final merchant = text.isEmpty ? (_income ? 'Income' : 'Expense') : text;
    if (_receiptPath != null && !_income) {
      try {
        await ref.read(apiProvider).post('/receipts/confirm', {'path': _receiptPath, 'merchant': merchant, 'total': _cents / 100});
        await n.refresh();
        TickHaptics.instance.capturePop(_cents);
        if (mounted) Navigator.of(context).pop();
        return;
      } catch (_) {/* fall through to a plain add */}
    }
    await n.add(amountCents: _income ? _cents : -_cents, merchant: merchant);
    TickHaptics.instance.capturePop(_cents);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final shown = _amount.isEmpty ? '0' : _amount;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text('Add', style: context.ts(TickType.displayM)),
        Pressable(onTap: _scan, semanticLabel: 'Scan receipt', child: TickIcon('camera', color: c.text)),
        SizedBox(width: 180, child: Segmented(options: const ['Spent', 'Got'], index: _income ? 1 : 0, onChanged: (i) => setState(() => _income = i == 1))),
      ]),
      const SizedBox(height: 16),
      Sticker(hole: true, padding: const EdgeInsets.fromLTRB(52, 12, 40, 12), child: Text('${_income ? '+' : ''}\$$shown', style: context.ts(TickType.hero, color: c.onAccent, size: 52))),
      const SizedBox(height: 16),
      Container(
        height: 48, padding: const EdgeInsets.symmetric(horizontal: 16), decoration: BoxDecoration(color: c.surface1, borderRadius: BorderRadius.circular(999)),
        child: Row(children: [
          Expanded(child: Stack(alignment: Alignment.centerLeft, children: [
            if (_line.text.isEmpty) IgnorePointer(child: Text('Merchant, or "uber 18"', style: context.ts(TickType.body, color: c.textSecondary))),
            EditableText(controller: _line, focusNode: _focus, style: context.ts(TickType.body), cursorColor: c.text, backgroundCursorColor: c.surface2, selectionColor: c.hairline, onChanged: (v) => setState(() => _parsed = parseNatural(v, ref.read(clockProvider)())), onSubmitted: (_) => _submit()),
          ])),
        ]),
      ),
      if (_scanMsg != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_scanMsg!, style: context.ts(TickType.bodyS, color: c.textSecondary))),
      if (_cents == 0 && _parsed != null)
        Padding(padding: const EdgeInsets.only(top: 8), child: Text('${_parsed!.isRecurring ? 'Monthly bill' : _parsed!.isIncome ? 'Money in' : 'Spent'}: ${_parsed!.merchant}, ${formatCents(_parsed!.amountCents.abs())}', style: context.ts(TickType.bodyS, color: c.textSecondary))),
      const SizedBox(height: 8),
      NumberPad(onKey: _key),
      ActionButton('Add', onPressed: _submit),
    ]);
  }
}
