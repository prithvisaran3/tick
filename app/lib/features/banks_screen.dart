import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:go_router/go_router.dart';
import '../data/ledger.dart';
import '../data/settings.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../design/widgets/more.dart';
import '../services/api.dart';
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

  Future<void> _link({String? connectionId}) async {
    setState(() { _busy = true; _error = null; });
    try {
      final api = ref.read(apiProvider);
      final j = await api.post('/plaid/link-token', {'connection_id': ?connectionId});
      final url = j['hosted_link_url'] as String?;
      if (url == null) throw ApiException(500, 'no link url');
      await FlutterWebAuth2.authenticate(url: url, callbackUrlScheme: 'tick');
      if (connectionId == null) {
        await api.post('/plaid/complete', {'link_token': j['link_token']});
      } else {
        await api.post('/plaid/sync/$connectionId');
      }
      await ref.read(ledgerProvider.notifier).refresh();
      await _loadLinks();
      // The first sync of a new link runs on the server (up to 12 months of history). Realtime pushes rows in; poll a few times as a backstop.
      for (final s in const [6, 15, 40]) {
        Future<void>.delayed(Duration(seconds: s), () { if (mounted) ref.read(ledgerProvider.notifier).refresh(); });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e is ApiException && e.status == 409 ? 'You have used all 10 bank links.' : 'That didn\'t go through. Try again, nothing was lost.');
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final l = ref.watch(ledgerProvider);
    final demo = ref.watch(settingsProvider).demoMode;
    final c = context.c;
    final left = _left ?? (10 - l.linksUsed);
    return TickScreen(
      child: ListView(children: [
        ScreenTitle('Banks', onBack: () => context.pop()),
        for (final conn in l.connections) ...[
          TickCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(children: [
              Avatar(conn.institution, 'biz'), const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(conn.institution, style: context.ts(TickType.title, size: 16)),
                Text(conn.needsRelink ? 'Needs a quick sign-in to keep syncing.' : (conn.status == 'error' ? 'Having trouble syncing. We will keep trying.' : 'Syncing'), style: context.ts(TickType.bodyS, color: conn.needsRelink ? c.alert : c.textSecondary)),
              ])),
              if (conn.needsRelink) TickChip('Fix', on: true, onTap: _busy ? null : () => _link(connectionId: conn.id)),
            ]),
          ),
          const SizedBox(height: 8),
        ],
        if (l.connections.isEmpty && !demo) const EmptyState('No banks linked', 'Link one and purchases show up on their own.', icon: 'bank'),
        const SizedBox(height: 8),
        TickCard(raised: true, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('You have $left of 10 bank links left.', style: context.ts(TickType.title)),
          const SizedBox(height: 4),
          Text('Removing a link doesn\'t give the slot back.', style: context.ts(TickType.bodyS, color: c.textSecondary)),
        ])),
        const SizedBox(height: 16),
        if (demo)
          Text('Turn off demo mode to link a real bank.', style: context.ts(TickType.body, color: c.textSecondary))
        else if (left <= 0)
          Text('All 10 links are used.', style: context.ts(TickType.body, color: c.alert))
        else
          HoldToConfirm(label: 'Link bank', onConfirmed: () { if (!_busy) _link(); }),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: context.ts(TickType.body, color: c.alert))),
      ]),
    );
  }
}
