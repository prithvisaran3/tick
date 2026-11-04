import 'dart:math' as math;
import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../data/ledger.dart';
import '../design/motion.g.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../design/widgets/more.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import '../services/haptics.dart';
import 'activity_screen.dart';
import 'common.dart';

/// Caught: low-confidence captures as a card stack. Right = looks right, left = fix it, up = Business.
class CaughtScreen extends ConsumerStatefulWidget {
  const CaughtScreen({super.key});
  @override
  ConsumerState<CaughtScreen> createState() => _CaughtScreenState();
}

class _CaughtScreenState extends ConsumerState<CaughtScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _fly;
  Offset _drag = Offset.zero;
  Offset _target = Offset.zero;
  bool _flying = false;
  final Set<String> _done = {};

  @override
  void initState() {
    super.initState();
    _fly = AnimationController.unbounded(vsync: this);
  }

  @override
  void dispose() { _fly.dispose(); super.dispose(); }

  void _update(DragUpdateDetails d) { if (!_flying) setState(() => _drag += d.delta); }

  void _end(DragEndDetails d, Txn t) {
    const k = TickMotion.caughtCommitPx;
    if (_drag.dx > k) { _commit(t, const Offset(600, 0), 'right'); }
    else if (_drag.dx < -k) { _commit(t, const Offset(-600, 0), 'left'); }
    else if (_drag.dy < -k) { _commit(t, const Offset(0, -800), 'up'); }
    else { _springBack(); }
  }

  void _springBack() {
    final from = _drag;
    _flying = true;
    _fly.value = 0;
    _fly.addListener(_backTick(from));
    _fly.animateWith(SpringSimulation(springOf(TickSprings.standard), 0, 1, 0)).whenComplete(() { _flying = false; });
  }

  VoidCallback _backTick(Offset from) {
    late VoidCallback cb;
    cb = () {
      setState(() => _drag = from * (1 - _fly.value));
      if ((_fly.value - 1).abs() < 0.001) _fly.removeListener(cb);
    };
    return cb;
  }

  Future<void> _commit(Txn t, Offset target, String dir) async {
    if (_flying) return;
    _flying = true;
    final n = ref.read(ledgerProvider.notifier);
    switch (dir) {
      case 'right': TickHaptics.instance.sortRight(); n.markLooksRight(t.id);
      case 'up': TickHaptics.instance.sortUp(); n.toggleBusiness(t.id);
      case 'left': TickHaptics.instance.sortLeft();
    }
    final from = _drag;
    _target = target;
    _fly.value = 0;
    void tick() => setState(() => _drag = Offset.lerp(from, _target, _fly.value.clamp(0, 1))!);
    _fly.addListener(tick);
    await _fly.animateTo(1, duration: Duration(milliseconds: context.reduceMotion ? 150 : 260), curve: Curves.easeIn);
    _fly.removeListener(tick);
    if (!mounted) return;
    setState(() { _done.add(t.id); _drag = Offset.zero; _flying = false; });
    if (dir == 'left') {
      await showCategorySheet(context, ref, t);
      ref.read(ledgerProvider.notifier).patch(t.id, (x) => x.copyWith(needsReview: false));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = ref.watch(ledgerProvider);
    final c = context.c;
    final queue = l.needsReview.where((t) => !_done.contains(t.id)).toList();
    final progress = (_drag.dx.abs() / TickMotion.caughtCommitPx).clamp(0.0, 1.0);
    return TickScreen(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ScreenTitle('Caught', onBack: () => context.pop(), trailing: Text(queue.isEmpty ? '' : '${queue.length} to check', style: context.ts(TickType.body, color: c.textSecondary))),
        Expanded(
          child: queue.isEmpty
              ? const EmptyState('All clear', 'Nothing to check. Tick will flag the next odd one.')
              : Stack(children: [
                  for (var i = math.min(queue.length, 3) - 1; i >= 0; i--)
                    Positioned(
                      left: 0, right: 0, top: 16,
                      child: i == 0 ? _top(queue[0], progress) : Transform.translate(offset: Offset(0, 16.0 * i - 8 * progress), child: Transform.scale(scale: 1 - 0.05 * i + 0.02 * progress, child: Transform.rotate(angle: (i.isOdd ? 0.035 : -0.035), child: Opacity(opacity: 1 - 0.25 * i, child: _CardBody(t: queue[i], ledger: l, plain: true))))),
                    ),
                ]),
        ),
        if (queue.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 32, top: 8),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
              _Act('edit', 'Fix it', () => _commit(queue[0], const Offset(-600, 0), 'left'), false),
              _Act('briefcase', 'Business', () => _commit(queue[0], const Offset(0, -800), 'up'), false),
              _Act('check', 'Looks right', () => _commit(queue[0], const Offset(600, 0), 'right'), true),
            ]),
          ),
      ]),
    );
  }

  Widget _top(Txn t, double progress) => GestureDetector(
        onPanUpdate: _update, onPanEnd: (d) => _end(d, t),
        child: Transform.translate(offset: _drag, child: Transform.rotate(angle: _drag.dx / 900, child: _CardBody(t: t, ledger: ref.read(ledgerProvider), plain: false))),
      );
}

class _Act extends StatelessWidget {
  const _Act(this.icon, this.label, this.onTap, this.primary);
  final String icon;
  final String label;
  final VoidCallback onTap;
  final bool primary;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Pressable(
      onTap: onTap, semanticLabel: label,
      child: Column(children: [
        Container(width: 56, height: 56, alignment: Alignment.center, decoration: BoxDecoration(color: primary ? c.accent : c.surface2, shape: BoxShape.circle), child: TickIcon(icon, color: primary ? c.onAccent : c.text)),
        const SizedBox(height: 8),
        Text(label, style: context.ts(TickType.bodyS, color: c.textSecondary).copyWith(fontWeight: FontWeight.w700)),
      ]),
    );
  }
}

class _CardBody extends StatelessWidget {
  const _CardBody({required this.t, required this.ledger, required this.plain});
  final Txn t;
  final LedgerState ledger;
  final bool plain;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final cat = ledger.category(t.categoryId);
    final acct = ledger.account(t.accountId);
    return Container(
      height: 410, padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(color: c.surface2, borderRadius: BorderRadius.circular(TickRadius.card), border: Border.all(color: c.hairline), boxShadow: plain ? null : const [BoxShadow(color: Color(0x99000000), blurRadius: 50, offset: Offset(0, 30), spreadRadius: -24)]),
      child: plain ? null : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${sourceLabel(t.source)} · ${DateFormat('h:mm a').format(t.occurredAt)}', style: context.ts(TickType.bodyS, size: 13, color: c.textSecondary).copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 16),
        PopIn(onLanded: () => TickHaptics.instance.capturePop(t.amountCents), child: Sticker(hole: true, padding: const EdgeInsets.fromLTRB(52, 14, 40, 14), child: Text(formatCents(t.amountCents.abs()), style: context.ts(TickType.hero, color: c.onAccent, size: 54)))),
        const SizedBox(height: 24),
        Text(t.merchant, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.ts(TickType.displayM, size: 30)),
        const SizedBox(height: 4),
        Text(acct?.label ?? 'Account not set', style: context.ts(TickType.body, color: c.textSecondary)),
        const SizedBox(height: 16),
        Wrap(spacing: 8, children: [TickChip(cat?.name ?? 'Other'), TickChip(t.isBusiness ? 'Business ✓' : '+ Business')]),
        const Spacer(),
        Container(
          width: double.infinity, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), decoration: BoxDecoration(color: c.surface1, borderRadius: BorderRadius.circular(TickRadius.card)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Why check', style: context.ts(TickType.bodyS, size: 13, color: c.textSecondary).copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text('${(t.confidence * 100).round()}% sure it\'s ${t.merchant}. The merchant text was messy.', style: context.ts(TickType.body, size: 14.5)),
          ]),
        ),
      ]),
    );
  }
}
