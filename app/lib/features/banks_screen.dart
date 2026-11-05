import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../data/ledger.dart';
import '../data/settings.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../design/widgets/more.dart';
import '../services/api.dart';
import '../services/web_auth.dart';
import '../design/widgets/refresh.dart';
import '../domain/models.dart';
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
  int? _left;

  @override
  void initState() {
    super.initState();
    _loadLinks();
  }

  Future<void> _loadLinks() async {
    if (ref.read(settingsProvider).demoMode) return;
    try {
      final j = await ref.read(apiProvider).get('/plaid/links');
      if (mounted) setState(() => _left = (j['left'] as num).toInt());
    } catch (_) {}
  }

  /// Every NEW link costs one of 10 lifetime slots (Plaid Trial). Always confirm first; re-linking an existing bank (update mode) is free.
  Future<void> _confirmNewLink() async {
    final l = ref.read(ledgerProvider);
    final left = _left ?? (10 - l.linksUsed);
    final linked = {for (final c in l.connections) c.institution}.toList()..sort();
    final ok = await showTickSheet<bool>(context, builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Link a bank', style: ctx.ts(TickType.displayM)),
          const SizedBox(height: 8),
          Text('This uses 1 of your $left remaining links. Removing a link never gives it back.', style: ctx.ts(TickType.body)),
          const SizedBox(height: 8),
          Text('One link covers every account at that bank. Link SoFi once for checking, savings and the loan.', style: ctx.ts(TickType.bodyS, color: ctx.c.textSecondary)),
          if (linked.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Already linked: ${linked.join(', ')}. Don\'t link these again.', style: ctx.ts(TickType.bodyS, color: ctx.c.textSecondary)),
          ],
          const SizedBox(height: 20),
          HoldToConfirm(label: 'Hold to use 1 link', onConfirmed: () => Navigator.of(ctx).pop(true)),
          const SizedBox(height: 8),
          Center(child: Pressable(onTap: () => Navigator.of(ctx).pop(false), minSize: 44, semanticLabel: 'Not now',
              child: Padding(padding: const EdgeInsets.all(12), child: Text('Not now', style: ctx.ts(TickType.label, color: ctx.c.textSecondary))))),
        ]));
    if (ok == true && mounted) await _link();
  }

  Future<void> _link({String? connectionId}) async {
    setState(() { _busy = true; _error = null; _note = null; });
    var bankDone = false;          // after Plaid's sheet closes, the Item may already exist even if our call fails
    try {
      final api = ref.read(apiProvider);
      final j = await api.post('/plaid/link-token', {'connection_id': ?connectionId});
      final url = j['hosted_link_url'] as String?;
      if (url == null) throw ApiException(500, 'no link url');
      await webAuthenticate(url);
      bankDone = true;
      if (connectionId == null) {
        final r = await api.post('/plaid/complete', {'link_token': j['link_token']});
        if ((r['connections'] as List?)?.isEmpty ?? true) _note = 'Still finishing up. Your bank shows here in a minute.';
      } else {
        await api.post('/plaid/sync/$connectionId');
      }
      await ref.read(ledgerProvider.notifier).refresh();
      await _loadLinks();
      // The first sync of a new link runs on the server (up to 12 months of history). Realtime pushes rows in; poll a few times as a backstop.
      for (final s in const [6, 15, 40]) {
        Future<void>.delayed(Duration(seconds: s), () { if (mounted) ref.read(ledgerProvider.notifier).refresh(); });
      }
    } on PlatformException catch (e) {
      // Closing the Plaid sheet is not an error.
      if (mounted && e.code != 'CANCELED') setState(() => _error = 'That didn\'t go through. Try again, nothing was lost.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e is ApiException && e.status == 409
          ? 'You have used all 10 bank links.'
          : bankDone && connectionId == null
              // The bank side finished; the server usually completes it from Plaid's webhook. Re-linking now could cost another slot.
              ? 'Your bank may still be connecting. Pull to refresh in a minute before you link again.'
              : 'That didn\'t go through. Try again, nothing was lost.');
      if (bankDone) Future<void>.delayed(const Duration(seconds: 8), () { if (mounted) { ref.read(ledgerProvider.notifier).refresh(); _loadLinks(); } });
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _refresh() async {
    await ref.read(ledgerProvider.notifier).refresh();
    await _loadLinks();
  }

  @override
  Widget build(BuildContext context) {
    final l = ref.watch(ledgerProvider);
    final demo = ref.watch(settingsProvider).demoMode;
    final c = context.c;
    final left = _left ?? (10 - l.linksUsed);
    return TickScreen(
      child: TickScrollView(onRefresh: _refresh, slivers: [SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.only(bottom: 48), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ScreenTitle('Banks', onBack: () => context.pop()),
        for (final conn in l.connections) ...[
          TickCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(children: [
              Avatar(conn.institution, 'biz'), const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(conn.institution, style: context.ts(TickType.title, size: 16)),
                Text(conn.needsRelink ? 'Needs a quick sign-in to keep syncing.' : (conn.status == 'error' ? 'Having trouble syncing. We will keep trying.' : _accountsLine(l, conn)), style: context.ts(TickType.bodyS, color: conn.needsRelink ? c.alert : c.textSecondary)),
              ])),
              if (conn.needsRelink) TickChip('Fix', on: true, onTap: _busy ? null : () => _link(connectionId: conn.id)),
            ]),
          ),
          const SizedBox(height: 8),
        ],
        if (l.connections.isEmpty && !demo) const EmptyState('No banks linked', 'Link one and purchases show up on their own.', icon: 'bank'),
        const CardsSection(showSpend: true),
        const SizedBox(height: 8),
        TickCard(raised: true, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('You have $left of 10 bank links left.', style: context.ts(TickType.title)),
          const SizedBox(height: 4),
          Text('Removing a link doesn\'t give the slot back. One link covers every account at a bank.', style: context.ts(TickType.bodyS, color: c.textSecondary)),
        ])),
        const SizedBox(height: 16),
        if (demo)
          Text('Turn off demo mode to link a real bank.', style: context.ts(TickType.body, color: c.textSecondary))
        else if (left <= 0)
          Text('All 10 links are used.', style: context.ts(TickType.body, color: c.alert))
        else
          PillButton('Link a bank', busy: _busy, onTap: _busy ? null : _confirmNewLink),
        if (_note != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_note!, style: context.ts(TickType.body, color: c.textSecondary))),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: context.ts(TickType.body, color: c.alert))),
        const SizedBox(height: 12),
        Text('Apple Card isn\'t on Plaid. Purchases come in from Wallet, and you can import a statement in Settings.', style: context.ts(TickType.bodyS, color: c.textSecondary)),
      ])))]),
    );
  }

  String _accountsLine(LedgerState l, Connection conn) {
    final n = l.accounts.where((a) => a.institution == conn.institution).length;
    return n == 0 ? 'Syncing' : n == 1 ? 'Syncing 1 account' : 'Syncing $n accounts';
  }
}
