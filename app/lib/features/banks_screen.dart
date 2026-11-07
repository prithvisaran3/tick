import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../data/ledger.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../design/widgets/more.dart';
import '../data/bank_step.dart';
import '../data/link_info.dart';
import '../services/api.dart';
import '../services/bank_link.dart';
import '../services/haptics.dart';
import '../design/widgets/scaffold.dart';
import '../domain/models.dart';
import '../data/account_counts.dart';
import '../domain/bank_status.dart';
import 'cards.dart';
import 'common.dart';

/// Bank connections. Plaid Hosted Link opens in ASWebAuthenticationSession (the web flow handles OAuth banks like Chase without
/// registering a native redirect), returns to tick://plaid-complete, and the server exchanges the public token into Vault.
/// Link update mode (never a new Item) fixes a connection that needs a quick sign-in.
class BanksScreen extends ConsumerStatefulWidget {
  const BanksScreen({super.key});
  @override
  ConsumerState<BanksScreen> createState() => _BanksScreenState();
}

class _BanksScreenState extends ConsumerState<BanksScreen> {
  String? _error;
  String? _note;
  bool _busy = false;
  VoidCallback? _retryAction;

  /// A new link is a scarce, permanent resource, so the owner confirms it with a hold; re-linking an existing bank (update mode) needs no confirm.
  /// When linking isn't available the tap just shows the one calm line.
  Future<void> _tapLink(LinkInfo info) async {
    if (info.blocked) { TickHaptics.instance.selection(); setState(() { _note = linkLimitedMessage; _error = null; _retryAction = null; }); return; }
    final l = ref.read(ledgerProvider);
    final linked = {for (final c in l.connections) c.institution}.toList()..sort();
    final ok = await showTickSheet<bool>(context, builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Link a bank', style: ctx.ts(TickType.displayM)),
          const SizedBox(height: 8),
          Text('One link covers every account at that bank. Read-only: Tick can\'t move money.', style: ctx.ts(TickType.body)),
          if (linked.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Already linked: ${linked.join(', ')}.', style: ctx.ts(TickType.bodyS, color: ctx.c.textSecondary)),
          ],
          const SizedBox(height: 20),
          HoldToConfirm(label: 'Hold to continue', onConfirmed: () => Navigator.of(ctx).pop(true)),
          const SizedBox(height: 8),
          Center(child: Pressable(onTap: () => Navigator.of(ctx).pop(false), minSize: 44, semanticLabel: 'Not now',
              child: Padding(padding: const EdgeInsets.all(12), child: Text('Not now', style: ctx.ts(TickType.label, color: ctx.c.textSecondary))))),
        ]));
    if (ok == true && mounted) await _link();
  }

  Future<void> _link({String? connectionId, bool accounts = false}) async {
    setState(() { _busy = true; _error = null; _note = null; _retryAction = null; });
    final store = ref.read(bankStepStoreProvider);
    final out = await runBankLink(ref.read(apiProvider), ref.read(webAuthProvider), connectionId: connectionId, accounts: accounts, onStarted: store.setPendingLink, onFinished: store.clearPendingLink);
    if (!mounted) return;
    switch (out.result) {
      case LinkResult.cancelled:
        break;
      case LinkResult.limited:
        _note = out.message;
      case LinkResult.failed:
        _error = out.message;
        _retryAction = () => _link(connectionId: connectionId, accounts: accounts);
      case LinkResult.pending:
        _note = out.message;
      case LinkResult.linked:
        break;
    }
    if (out.result == LinkResult.linked || out.result == LinkResult.pending) {
      await ref.read(ledgerProvider.notifier).refresh();
      ref.invalidate(linkInfoProvider);
      // The first sync of a new link runs on the server (up to 12 months of history). Realtime pushes rows in; poll a few times as a backstop.
      for (final s in const [6, 15, 40]) {
        Future<void>.delayed(Duration(seconds: s), () { if (mounted) ref.read(ledgerProvider.notifier).refresh(); });
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  /// Pull to refresh is a REAL sync: every bank that doesn't need a person is asked for fresh data, then the ledger reloads.
  Future<void> _refresh() async {
    final api = ref.read(apiProvider);
    final conns = ref.read(ledgerProvider).connections.where((c) => !c.needsRelink).toList();
    if (conns.isNotEmpty) {
      await Future.wait([for (final c in conns) api.post('/plaid/sync/${c.id}').then((_) {}).catchError((_) {})]);
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    await ref.read(ledgerProvider.notifier).refresh();
    ref.invalidate(linkInfoProvider);
  }

  Future<void> _retry(Connection c) async {
    setState(() { _error = null; _note = null; _retryAction = null; });
    try {
      await ref.read(apiProvider).post('/plaid/sync/${c.id}');
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e, action: 'refresh that bank'));
    }
    await Future<void>.delayed(const Duration(seconds: 2));
    await ref.read(ledgerProvider.notifier).refresh();
  }

  @override
  Widget build(BuildContext context) {
    final l = ref.watch(ledgerProvider);
    final c = context.c;
    final info = ref.watch(linkInfoProvider).value ?? LinkInfo.unknown(l.linksUsed);
    return TickPage(
      title: 'Banks', onBack: () => context.pop(), onRefresh: _refresh,
      children: [
        for (final conn in l.connections) ...[
          _BankTile(conn: conn, ledger: l, now: ref.watch(clockProvider)(), counts: ref.watch(accountCountsProvider).value ?? const {}, busy: _busy,
              onAction: (a) {
                switch (a) {
                  case BankAction.reconnect: _link(connectionId: conn.id);
                  case BankAction.fixAccounts: _link(connectionId: conn.id, accounts: true);
                  case BankAction.retry: _retry(conn);
                  case BankAction.none: break;
                }
              }),
          const SizedBox(height: 8),
        ],
        if (l.connections.isEmpty && !l.loading) const EmptyState('Track your accounts', 'Link a bank and purchases and balances show up on their own.', icon: 'bank'),
        const CardsSection(showSpend: true),
        const SizedBox(height: 8),
        PillButton('Link a bank', busy: _busy, onTap: _busy ? null : () => _tapLink(info)),
        const SizedBox(height: 8),
        PillButton('Import a statement', style: PillStyle.quiet, height: 52, onTap: () => context.push('/import')),
        if (_note != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_note!, style: context.ts(TickType.body, color: c.textSecondary))),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Semantics(liveRegion: true, child: Text(_error!, style: context.ts(TickType.body, color: c.alert)))),
        if (_error != null && _retryAction != null) Padding(padding: const EdgeInsets.only(top: 8), child: Align(alignment: Alignment.centerLeft, child: TickChip('Retry', icon: 'repeat', on: true, onTap: _busy ? null : _retryAction))),
        const SizedBox(height: 12),
        Text('Apple Card purchases come in from Wallet, or import a statement.', style: context.ts(TickType.bodyS, color: c.textSecondary)),
      ],
    );
  }
}

class _BankTile extends StatelessWidget {
  const _BankTile({required this.conn, required this.ledger, required this.now, required this.counts, required this.busy, required this.onAction});
  final Connection conn;
  final LedgerState ledger;
  final DateTime now;
  final Map<String, AccountCount> counts;
  final bool busy;
  final void Function(BankAction) onAction;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final big = MediaQuery.textScalerOf(context).scale(1) > 1.4; // action chip drops below the text so it can't push it off screen
    final accts = ledger.accounts.where((a) => a.connectionId == conn.id).toList();
    final total = accts.fold<int>(0, (s, a) => s + (counts[a.id]?.count ?? 0));
    final st = bankStatus(conn, now, txnCount: total);
    final color = switch (st.tone) { BankTone.good => c.textSecondary, BankTone.working => c.textSecondary, BankTone.warn => c.alert, BankTone.bad => c.alert };
    return TickCard(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Semantics(
        label: '${conn.institution}. ${st.title}. ${st.detail ?? ''}', container: true,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Avatar(conn.institution, 'biz'), const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(conn.institution, style: context.ts(TickType.title, size: 16)),
              const SizedBox(height: 2),
              Row(children: [
                if (st.busy) ...[const TickLoader(size: 5), const SizedBox(width: 8)],
                Flexible(child: Text(st.title, style: context.ts(TickType.bodyS, color: color))),
              ]),
              if (st.detail != null) Text(st.detail!, style: context.ts(TickType.bodyS, size: 12.5, color: c.textSecondary)),
            ])),
            if (st.actionLabel != null && !big) ...[const SizedBox(width: 8), TickChip(st.actionLabel!, on: st.tone != BankTone.good, onTap: busy ? null : () => onAction(st.action))],
          ]),
          if (st.actionLabel != null && big) Padding(padding: const EdgeInsets.only(top: 8), child: Align(alignment: Alignment.centerLeft, child: TickChip(st.actionLabel!, on: st.tone != BankTone.good, onTap: busy ? null : () => onAction(st.action)))),
          if (accts.isNotEmpty) ...[
            const SizedBox(height: 10),
            for (final a in accts)
              Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Row(children: [
                Expanded(child: Text(a.shortLabel, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.ts(TickType.bodyS))),
                const SizedBox(width: 8),
                Flexible(child: Text(a.isLoan ? 'loan' : '${counts[a.id]?.count ?? 0} transactions', maxLines: 1, overflow: TextOverflow.ellipsis, style: context.ts(TickType.monoS, size: 12, color: c.textSecondary))),
              ])),
          ],
        ]),
      ),
    );
  }
}
