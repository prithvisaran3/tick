import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../data/ledger.dart';
import '../data/settings.dart';
import '../design/motion.g.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../design/widgets/more.dart';
import '../domain/money.dart';
import '../domain/receipt.dart';
import '../services/api.dart';
import '../services/haptics.dart';
import '../data/env.dart';

/// The Morning Receipt: yesterday, printed. Lines tick in, total, safe to spend, one advice line, a "Ticked." stamp. Drag up to tear off and share.
class ReceiptScreen extends ConsumerStatefulWidget {
  const ReceiptScreen({super.key, this.advice, this.animate = true});
  final String? advice;
  final bool animate;
  @override
  ConsumerState<ReceiptScreen> createState() => _ReceiptScreenState();
}

class _ReceiptScreenState extends ConsumerState<ReceiptScreen> {
  final _key = GlobalKey();
  int _shown = 0;
  bool _stamped = false;
  double _tear = 0;
  bool _torn = false;
  Timer? _t;
  String? _serverAdvice;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _print());
  }

  Future<void> _fetchAdvice(ReceiptData r) async {
    if (!Env.hasSupabase || ref.read(settingsProvider).demoMode) return;
    try {
      final sts = ref.read(safeToSpendProvider);
      final j = await ref.read(apiProvider).post('/intel/advice', {'total_cents': r.totalCents, 'safe_cents': sts?.cents ?? 0, 'days_to_payday': sts?.daysToPayday ?? 1, 'captures': r.captures, 'top_merchant': r.lines.isEmpty ? null : r.lines.first.merchant});
      if (mounted) setState(() => _serverAdvice = j['text'] as String?);
    } catch (_) {/* local advice stays */}
  }

  Future<void> _print() async {
    final r = buildReceipt(ref.read(ledgerProvider).txns, ref.read(clockProvider)(), cats: {for (final c in ref.read(ledgerProvider).categories) c.id: c}, accounts: {for (final a in ref.read(ledgerProvider).accounts) a.id: a});
    _fetchAdvice(r);
    final n = r.lines.length + (r.moreCount > 0 ? 1 : 0);
    if (!widget.animate || context.reduceMotion) { setState(() { _shown = n; _stamped = true; }); return; }
    await Future<void>.delayed(const Duration(milliseconds: TickMotion.receiptLineIntervalMs * 3));
    for (var i = 1; i <= n; i++) {
      if (!mounted) return;
      TickHaptics.instance.receiptTick();
      setState(() => _shown = i);
      await Future<void>.delayed(const Duration(milliseconds: TickMotion.receiptLineIntervalMs));
    }
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (!mounted) return;
    setState(() => _stamped = true);
    TickHaptics.instance.priceWeight(5000);
    ref.read(settingsProvider.notifier).update((s) => s.copyWith(lastMorningReceipt: DateFormat('yyyy-MM-dd').format(ref.read(clockProvider)())));
  }

  @override
  void dispose() { _t?.cancel(); super.dispose(); }

  Future<void> _tearOff() async {
    if (_torn) return;
    _torn = true;
    TickHaptics.instance.receiptRip();
    try {
      final b = _key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final img = await b.toImage(pixelRatio: 3);
      final bytes = (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/tick-morning-receipt.png')..writeAsBytesSync(bytes);
      await SharePlus.instance.share(ShareParams(files: [XFile(f.path)], text: 'Ticked.'));
    } catch (_) {/* sharing is optional */}
    if (mounted) setState(() { _tear = 0; _torn = false; });
  }

  @override
  Widget build(BuildContext context) {
    final l = ref.watch(ledgerProvider);
    final now = ref.watch(clockProvider)();
    final sts = ref.watch(safeToSpendProvider);
    final c = context.c;
    final r = buildReceipt(l.txns, now, cats: {for (final c in l.categories) c.id: c}, accounts: {for (final a in l.accounts) a.id: a});
    final paper = context.isDark ? TickPalette.paper : TickPalette.paper2;
    final advice = widget.advice ?? _serverAdvice ?? fallbackAdvice(r, sts?.cents ?? 0, sts?.daysToPayday ?? 1);
    final lines = <Widget>[
      for (var i = 0; i < r.lines.length; i++)
        _Line(visible: i < _shown, left: r.lines[i].merchant, right: '−${formatCents(r.lines[i].cents)}'),
      if (r.moreCount > 0) _Line(visible: r.lines.length < _shown, left: 'and ${r.moreCount} more', right: ''),
    ];
    final ink = TickPalette.ink;
    return TickScreen(
      horizontal: 28,
      child: Column(children: [
        SizedBox(height: 52, child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Flexible(child: Semantics(header: true, child: Text('Morning Receipt', maxLines: 1, overflow: TextOverflow.ellipsis, style: context.ts(TickType.bodyS, size: 13, color: c.textSecondary).copyWith(fontWeight: FontWeight.w700)))),
          Text('Yesterday', style: context.ts(TickType.bodyS, color: c.textSecondary)),
        ])),
        const SizedBox(height: 8),
        Expanded(child: SingleChildScrollView(physics: const ClampingScrollPhysics(), child: Column(children: [
        GestureDetector(
          onVerticalDragUpdate: (d) => setState(() => _tear = (_tear + d.delta.dy).clamp(-260.0, 0.0)),
          onVerticalDragEnd: (_) { if (_tear < -TickMotion.receiptLineIntervalMs - 0 && _tear.abs() > 120) { _tearOff(); } else { setState(() => _tear = 0); } },
          child: Transform.translate(
            offset: Offset(0, _tear), child: Transform.rotate(angle: -0.01 + _tear / 4000,
              child: RepaintBoundary(
                key: _key,
                child: PhysicalShape(clipper: const ZigZagClipper(), clipBehavior: Clip.antiAlias, color: paper, elevation: 14, shadowColor: const Color(0xFF000000), child: Container(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 44),
                  color: paper,
                  child: DefaultTextStyle(
                    style: TextStyle(color: ink, decoration: TextDecoration.none),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Yesterday, ${DateFormat('EEE MMM d').format(r.day)}', style: context.ts(TickType.displayM, color: ink, size: 26)),
                      const SizedBox(height: 4),
                      Text('${r.captures} ${r.captures == 1 ? 'capture' : 'captures'}', style: context.ts(TickType.monoS, size: 12, color: TickPalette.graphite)),
                      const SizedBox(height: 14), const _Dash(), const SizedBox(height: 6),
                      if (r.captures == 0) Padding(padding: const EdgeInsets.symmetric(vertical: 16), child: Text('Quiet day. Your wallet says thanks.', style: context.ts(TickType.body, color: ink))) else ...lines,
                      const SizedBox(height: 6), const _Dash(), const SizedBox(height: 12),
                      Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                        Text('Total spent', style: context.ts(TickType.monoS, color: TickPalette.graphite)),
                        const SizedBox(width: 8),
                        Flexible(child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight, child: Text(formatCents(r.totalCents), style: context.ts(TickType.hero, color: ink, size: 44)))),
                      ]),
                      const SizedBox(height: 8),
                      Row(crossAxisAlignment: CrossAxisAlignment.center, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                        Flexible(child: Text('Safe to spend', style: context.ts(TickType.monoS, color: TickPalette.graphite))),
                        const SizedBox(width: 8),
                        Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2), decoration: BoxDecoration(color: TickPalette.volt, borderRadius: BorderRadius.circular(99)), child: Text(sts == null ? '—' : formatDollars(sts.cents), style: context.ts(TickType.monoL, color: ink))),
                      ]),
                      const SizedBox(height: 16),
                      Text(advice, style: context.ts(TickType.body, color: ink)),
                      const SizedBox(height: 14),
                      Align(
                        alignment: Alignment.centerRight,
                        child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 52), child: _stamped
                            ? PopIn(fromScale: 1.15, fromTilt: 0.2, spring: TickSprings.pop, child: Transform.rotate(angle: -0.14, child: UnconstrainedBox(child: Container(padding: const EdgeInsets.symmetric(horizontal: 20), alignment: Alignment.center, decoration: BoxDecoration(color: TickPalette.volt, borderRadius: BorderRadius.circular(99), border: Border.all(color: ink, width: 3)), child: Text('Ticked.', style: context.ts(TickType.displayM, color: ink, size: 22))))))
                            : const SizedBox()),
                      ),
                    ]),
                  ),
                )),
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [TickIcon('share', size: 20, color: c.textSecondary), const SizedBox(width: 8), Flexible(child: Text('Tear off to share', style: context.ts(TickType.body, color: c.textSecondary)))]),
        const SizedBox(height: 16),
        ]))),
        Padding(padding: const EdgeInsets.only(bottom: 44), child: PillButton('Show me today', onTap: () => context.go('/'))),
      ]),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.visible, required this.left, required this.right});
  final bool visible;
  final String left, right;
  @override
  Widget build(BuildContext context) => AnimatedOpacity(
        duration: const Duration(milliseconds: 120), opacity: visible ? 1 : 0,
        child: Padding(padding: const EdgeInsets.symmetric(vertical: 5), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Expanded(child: Text(left, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.ts(TickType.mono, size: 14.5, color: TickPalette.ink))), const SizedBox(width: 12), Text(right, style: context.ts(TickType.mono, size: 14.5, color: TickPalette.ink)),
        ])),
      );
}

class _Dash extends StatelessWidget {
  const _Dash();
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (_, cs) => Row(children: [for (var i = 0; i < (cs.maxWidth / 10).floor(); i++) Expanded(child: Container(height: 2, margin: const EdgeInsets.only(right: 4), color: TickPalette.graphite.withValues(alpha: 0.5)))]));
}

/// A torn paper edge along the bottom: 12pt teeth, 8pt deep.
class ZigZagClipper extends CustomClipper<Path> {
  const ZigZagClipper({this.tooth = 12, this.depth = 8});
  final double tooth;
  final double depth;
  @override
  Path getClip(Size size) {
    final p = Path()..moveTo(0, 0)..lineTo(size.width, 0)..lineTo(size.width, size.height - depth);
    var x = size.width;
    var up = false;
    while (x > 0) {
      x = (x - tooth / 2).clamp(0, size.width);
      p.lineTo(x, up ? size.height - depth : size.height);
      up = !up;
    }
    p.lineTo(0, size.height - depth);
    p.close();
    return p;
  }
  @override
  bool shouldReclip(covariant ZigZagClipper old) => old.tooth != tooth || old.depth != depth;
}
