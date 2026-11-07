import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../data/ledger.dart';
import '../data/paybacks.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import '../services/api.dart';
import '../services/haptics.dart';

/// "Reimbursement for Dishoom?" A question, never an action: nothing links until it is accepted.
class PaybackCard extends ConsumerStatefulWidget {
  const PaybackCard({super.key, required this.s, this.candidate});
  final PaybackSuggestion s;
  final PaybackCandidate? candidate;      // the purchase being asked about; defaults to the likeliest
  @override
  ConsumerState<PaybackCard> createState() => _PaybackCardState();
}

class _PaybackCardState extends ConsumerState<PaybackCard> {
  late PaybackCandidate _c = widget.candidate ?? widget.s.candidates.first;
  bool _busy = false;
  String? _error;

  Future<void> _run(Future<void> Function() f) async {
    setState(() { _busy = true; _error = null; });
    try {
      await f();
      TickHaptics.instance.confirm();
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e, action: 'save that'));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final a = ref.read(paybackActionsProvider);
    final s = widget.s;
    final others = s.candidates.where((x) => x.purchaseId != _c.purchaseId).toList();
    return Padding(padding: const EdgeInsets.only(bottom: 8), child: TickCard(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Reimbursement for ${_c.merchant}?', style: context.ts(TickType.title, size: 15.5)),
      const SizedBox(height: 2),
      Text('${formatCents(s.amountCents)}${s.from == null ? '' : ' from ${s.from}'} on ${DateFormat('MMM d').format(s.date)}. ${_c.merchant} was ${formatCents(_c.amountCents)} on ${DateFormat('MMM d').format(_c.date)}.',
          style: context.ts(TickType.bodyS, color: c.textSecondary)),
      if (others.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Wrap(spacing: 8, runSpacing: 4, children: [
        for (final o in others) TickChip(o.merchant, onTap: _busy ? null : () => setState(() => _c = o)),
      ])),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(child: PillButton('Link it', height: 44, busy: _busy, onTap: () => _run(() => a.link(_c.purchaseId, s.paybackId)))),
        const SizedBox(width: 8),
        Expanded(child: PillButton('Not a payback', height: 44, style: PillStyle.quiet, onTap: _busy ? null : () => _run(() => a.dismiss(s.paybackId)))),
      ]),
      if (_error != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(_error!, style: context.ts(TickType.bodyS, size: 12.5, color: c.alert))),
    ])));
  }
}

/// "Mark Asha as settled?" One tap records it against this bank row.
class BalanceMatchCard extends ConsumerStatefulWidget {
  const BalanceMatchCard({super.key, required this.b});
  final BalanceMatch b;
  @override
  ConsumerState<BalanceMatchCard> createState() => _BalanceMatchCardState();
}

class _BalanceMatchCardState extends ConsumerState<BalanceMatchCard> {
  bool _busy = false;
  String? _error;
  Future<void> _run(Future<void> Function() f) async {
    setState(() { _busy = true; _error = null; });
    try {
      await f();
      TickHaptics.instance.confirm();
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e, action: 'save that'));
    }
    if (mounted) setState(() => _busy = false);
  }
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final b = widget.b;
    final a = ref.read(paybackActionsProvider);
    return Padding(padding: const EdgeInsets.only(bottom: 8), child: TickCard(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Mark ${b.first} as settled?', style: context.ts(TickType.title, size: 15.5)),
      const SizedBox(height: 2),
      Text('${formatCents(b.amountCents)} from ${b.first} on ${DateFormat('MMM d').format(b.date)}, for ${b.groupName}.${b.leftCents > 0 ? ' ${formatCents(b.leftCents)} still left.' : ''}', style: context.ts(TickType.bodyS, color: c.textSecondary)),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(child: PillButton(b.leftCents > 0 ? 'Mark paid' : 'Mark settled', height: 44, busy: _busy, onTap: () => _run(() => a.settleBalance(b)))),
        const SizedBox(width: 8),
        Expanded(child: PillButton('Not this', height: 44, style: PillStyle.quiet, onTap: _busy ? null : () => _run(() => a.dismiss(b.paybackId)))),
      ]),
      if (_error != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(_error!, style: context.ts(TickType.bodyS, size: 12.5, color: c.alert))),
    ])));
  }
}

/// Top of Activity: the newest question, and how many are behind it.
class PaybackBanner extends ConsumerWidget {
  const PaybackBanner({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(paybackSuggestionsProvider).value ?? const <PaybackSuggestion>[];
    final landed = ref.watch(landedSettlementsProvider).value ?? const <LandedSettlement>[];
    final balances = ref.watch(balanceMatchesProvider).value ?? const <BalanceMatch>[];
    if (list.isEmpty && landed.isEmpty && balances.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final b in balances) BalanceMatchCard(key: ValueKey('b${b.paybackId}'), b: b),
      for (final s in landed) Padding(padding: const EdgeInsets.only(bottom: 8), child: TickCard(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('${formatCents(s.amountCents)} from ${s.from} landed. Mark it received?', style: context.ts(TickType.title, size: 15.5)),
        const SizedBox(height: 10),
        PillButton('Mark received', height: 44, onTap: () => ref.read(paybackActionsProvider).received(s)),
      ]))),
      if (list.isNotEmpty) ...[
      PaybackCard(key: ValueKey(list.first.paybackId), s: list.first),
      if (list.length > 1) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('${list.length - 1} more to check', style: context.ts(TickType.bodyS, size: 12.5, color: context.c.textSecondary))),
      ],
    ]);
  }
}

/// On a transaction: the questions about it, and what it is already linked to (with Unlink).
class PaybackDetail extends ConsumerWidget {
  const PaybackDetail({super.key, required this.t});
  final Txn t;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final all = ref.watch(paybackSuggestionsProvider).value ?? const <PaybackSuggestion>[];
    final links = ref.watch(paybackLinksProvider(t.id)).value ?? const <PaybackLink>[];
    final l = ref.watch(ledgerProvider);
    final asPayback = all.where((s) => s.paybackId == t.id);
    final forPurchase = [for (final s in all) for (final x in s.candidates) if (x.purchaseId == t.id) (s, x)];
    String nameOf(String id) => l.txns.where((x) => x.id == id).firstOrNull?.merchant ?? 'That transaction';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (t.reimbursedCents > 0) Padding(padding: const EdgeInsets.only(top: 12), child: TickCard(child: Row(children: [
        Expanded(child: Text('Your share after ${formatCents(t.reimbursedCents)} back', style: context.ts(TickType.body, color: c.textSecondary))),
        Text(formatCents(t.myShareCents), style: context.ts(TickType.mono)),
      ]))),
      for (final x in links) Padding(padding: const EdgeInsets.only(top: 8), child: TickCard(child: Row(children: [
        Expanded(child: Pressable(
          onTap: () => context.push('/txn/${x.purchaseId == t.id ? x.paybackId : x.purchaseId}'), scale: 0.99,
          child: Text('${formatCents(x.amountCents)} · ${nameOf(x.purchaseId == t.id ? x.paybackId : x.purchaseId)}', maxLines: 2, overflow: TextOverflow.ellipsis, style: context.ts(TickType.body)),
        )),
        const SizedBox(width: 8),
        PillButton('Unlink', expand: false, height: 40, style: PillStyle.quiet, onTap: () => ref.read(paybackActionsProvider).unlink(x.paybackId)),
      ]))),
      if (asPayback.isNotEmpty || forPurchase.isNotEmpty) const SizedBox(height: 12),
      for (final s in asPayback) PaybackCard(key: ValueKey('d${s.paybackId}'), s: s),
      for (final (s, x) in forPurchase) PaybackCard(key: ValueKey('p${s.paybackId}'), s: s, candidate: x),
    ]);
  }
}
