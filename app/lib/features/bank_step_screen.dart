import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../data/bank_step.dart';
import '../data/ledger.dart';
import '../data/link_info.dart';
import '../data/nav.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../design/widgets/more.dart';
import '../services/api.dart';
import '../services/bank_link.dart';
import '../services/haptics.dart';

enum _Phase { idle, linking, syncing }

/// Onboarding, optional: "Track a bank account". Link now (Plaid Hosted Link), skip, or import a statement. Skipping never blocks, nags or breaks anything;
/// Banks and Settings link later. Shown once per person (see [BankStepStore]); a person who already has banks never sees it.
class BankStepScreen extends ConsumerStatefulWidget {
  const BankStepScreen({super.key, this.syncWait = const Duration(milliseconds: 2500)});
  final Duration syncWait; // how long "syncing" may hold before moving on: the first sync continues in the background
  @override
  ConsumerState<BankStepScreen> createState() => _BankStepScreenState();
}

class _BankStepScreenState extends ConsumerState<BankStepScreen> {
  _Phase _phase = _Phase.idle;
  String? _error;
  String? _note;
  bool _left = false;

  @override
  void initState() {
    super.initState();
    // Shown means seen: whatever happens next (skip, link, kill), this step does not come back.
    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) ref.read(bankStepStoreProvider).markSeen(); });
  }

  void _leave({String? then, bool toActivity = false}) {
    if (_left || !mounted) return;
    _left = true;
    if (toActivity) ref.read(shellTabProvider.notifier).go(1);
    final router = GoRouter.of(context);
    router.go('/');
    if (then != null) Future<void>.microtask(() => router.push(then));
  }

  Future<void> _link() async {
    if (_phase != _Phase.idle) return;
    if (ref.read(linkInfoProvider).value?.blocked ?? false) {
      TickHaptics.instance.selection();
      setState(() { _note = linkLimitedMessage; _error = null; });
      return;
    }
    setState(() { _phase = _Phase.linking; _error = null; _note = null; });
    final store = ref.read(bankStepStoreProvider);
    final out = await runBankLink(ref.read(apiProvider), ref.read(webAuthProvider), onStarted: store.setPendingLink, onFinished: store.clearPendingLink);
    if (!mounted) return;
    switch (out.result) {
      case LinkResult.cancelled:
        setState(() => _phase = _Phase.idle);
      case LinkResult.limited:
        setState(() { _phase = _Phase.idle; _note = out.message; });
      case LinkResult.failed:
        setState(() { _phase = _Phase.idle; _error = out.message; });
      case LinkResult.linked:
      case LinkResult.pending:
        TickHaptics.instance.success();
        setState(() { _phase = _Phase.syncing; _note = out.message; });
        ref.invalidate(linkInfoProvider);
        // Don't wait for the whole sync: refresh once, give the first rows a moment, then land on Activity where each bank shows its sync status.
        unawaited(ref.read(ledgerProvider.notifier).refresh());
        for (final s in const [6, 15, 40]) {
          Future<void>.delayed(Duration(seconds: s), () { if (mounted) ref.read(ledgerProvider.notifier).refresh(); });
        }
        await Future<void>.delayed(widget.syncWait);
        _leave(toActivity: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final tight = MediaQuery.textScalerOf(context).scale(1.0) > 1.25;
    ref.watch(linkInfoProvider);                     // start asking early, so a tap can answer at once
    final ledger = ref.watch(ledgerProvider);
    // A returning person who already has banks never needs this step.
    if (_phase == _Phase.idle && !ledger.loading && ledger.connections.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _leave());
    }

    Widget body;
    if (_phase == _Phase.syncing) {
      body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SizedBox(height: 56),
        const Center(child: TickLoader(size: 12)),
        const SizedBox(height: 32),
        Text('Syncing your accounts…', style: context.ts(TickType.displayL)),
        const SizedBox(height: 12),
        Text(_note ?? 'Purchases appear as they arrive. You can keep going while the rest loads.', style: context.ts(TickType.bodyL, color: c.textSecondary)),
        const Spacer(),
        PillButton('Continue', onTap: () => _leave(toActivity: true)),
        const SizedBox(height: 28),
      ]);
    } else {
      body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SizedBox(height: 32),
        Text('Track a bank account', style: context.ts(TickType.displayL)),
        const SizedBox(height: 12),
        Text('Link a bank and purchases and balances show up on their own. Read-only: Tick can\'t move money.', style: context.ts(TickType.bodyL, color: c.textSecondary)),
        if (tight) const SizedBox(height: 24) else const Spacer(),
        if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: Semantics(liveRegion: true, child: Text(_error!, style: context.ts(TickType.body, color: c.alert)))),
        if (_note != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: Semantics(liveRegion: true, child: Text(_note!, style: context.ts(TickType.body, color: c.textSecondary)))),
        PillButton(_error != null ? 'Try again' : 'Link a bank', style: PillStyle.inverse, busy: _phase == _Phase.linking, onTap: _phase == _Phase.linking ? null : _link),
        const SizedBox(height: 8),
        PillButton('Import a statement', style: PillStyle.quiet, height: 52, onTap: _phase == _Phase.linking ? null : () => _leave(then: '/import')),
        const SizedBox(height: 4),
        Center(child: Pressable(onTap: _phase == _Phase.linking ? null : () => _leave(), minSize: 44, semanticLabel: 'Skip for now',
            child: Padding(padding: const EdgeInsets.all(12), child: Text('Skip for now', style: context.ts(TickType.body, color: c.textSecondary).copyWith(fontWeight: FontWeight.w700))))),
        const SizedBox(height: 28),
      ]);
    }
    return TickScreen(child: Column(children: [
      const SizedBox(height: 52, child: Row(children: [Wordmark(size: 24)])),
      Expanded(child: tight || _phase != _Phase.syncing && MediaQuery.sizeOf(context).height < 640 ? SingleChildScrollView(child: body) : body),
    ]));
  }
}
