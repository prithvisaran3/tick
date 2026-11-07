import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tick/data/bank_step.dart';
import 'package:tick/data/ledger.dart';
import 'package:tick/data/nav.dart';
import 'package:tick/design/theme.dart';
import 'package:tick/domain/models.dart';
import 'package:tick/features/bank_step_screen.dart';
import 'package:tick/services/api.dart';
import 'package:tick/services/bank_link.dart';
import 'package:tick/services/session.dart';
import 'golden_harness.dart';

class _FakeLedger extends LedgerNotifier {
  _FakeLedger(this.s);
  final LedgerState s;
  @override
  LedgerState build() => s;
  @override
  Future<void> refresh() async {}
}

class _Server {
  _Server({this.canLink = true, this.totalLeft = 7, this.tokenStatus = 200, this.completeStatus = 200});
  final bool canLink;
  final int totalLeft;
  final int tokenStatus, completeStatus;
  final calls = <String>[];
  http.Client get client => MockClient((r) async {
        calls.add('${r.method} ${r.url.path}');
        Map<String, dynamic> ok(Map<String, dynamic> j) => j;
        http.Response json(int code, Object j) => http.Response(jsonEncode(j), code, headers: {'content-type': 'application/json'});
        if (r.url.path == '/plaid/links') return json(200, ok({'used': canLink ? 3 : 0, 'cap': 10, 'left': canLink ? 7 : 10, 'can_link': canLink, 'total_left': totalLeft}));
        if (r.url.path == '/plaid/link-token') {
          if (tokenStatus == 403) return json(403, {'detail': 'Linking banks is limited to this Tick\'s owner. You can add purchases from Wallet or import a statement instead.'});
          if (tokenStatus == 409) return json(409, {'detail': 'All 10 bank links are used, so Tick can\'t add another bank.'});
          if (tokenStatus != 200) return json(tokenStatus, {'detail': 'Bank link unavailable (INTERNAL_SERVER_ERROR)'});
          return json(200, {'link_token': 'link-production-abc123456', 'hosted_link_url': 'https://hosted.plaid.test/x', 'links_left': 7});
        }
        if (r.url.path == '/plaid/complete') return completeStatus == 200 ? json(200, {'connections': ['c1'], 'syncing': true}) : json(completeStatus, {'detail': 'x'});
        return json(404, {'detail': 'nope'});
      });
}

Future<(ProviderContainer, GoRouter)> _pump(WidgetTester tester, _Server server, {List<Connection> connections = const [], Future<String> Function(String)? auth, bool signedIn = true, double w = 393, double h = 852}) async {
  await loadFonts();
  final c = await demoContainer(demo: false, overrides: [
    apiProvider.overrideWithValue(Api(client: server.client)),
    userIdProvider.overrideWithValue(signedIn ? 'user-1' : null),
    webAuthProvider.overrideWithValue(auth ?? (u) async => 'tick://plaid-complete'),
    ledgerProvider.overrideWith(() => _FakeLedger(LedgerState(connections: connections))),
  ]);
  addTearDown(c.dispose);
  final router = GoRouter(initialLocation: '/onboarding/bank', routes: [
    GoRoute(path: '/', builder: (_, _) => const Text('TODAY')),
    GoRoute(path: '/onboarding/bank', builder: (_, _) => const BankStepScreen(syncWait: Duration(milliseconds: 300))),
    GoRoute(path: '/import', builder: (_, _) => const Text('IMPORT')),
  ]);
  tester.view.physicalSize = Size(w * 2, h * 2);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: c,
    child: TickTheme(dark: true, child: DefaultTextStyle(style: const TextStyle(fontFamily: 'Satoshi', color: Color(0xFFF5F3EC)), child: WidgetsApp.router(color: const Color(0xFF000000), routerConfig: router))),
  ));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 400));
  return (c, router);
}

Future<void> _drain(WidgetTester tester) => tester.pump(const Duration(seconds: 45));       // the post-link refresh backstops are timers

void main() {
  testWidgets('skip goes to Today, is remembered for this person, and never calls Plaid', (tester) async {
    final s = _Server();
    final (c, router) = await _pump(tester, s);
    expect(find.text('Track a bank account'), findsOneWidget);
    expect(find.textContaining('Read-only', findRichText: true), findsOneWidget);
    await tester.tap(find.text('Skip for now'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(router.state.uri.path, '/');
    expect(c.read(bankStepStoreProvider).seen, isTrue);
    expect(s.calls.where((x) => x.contains('link-token') || x.contains('complete')), isEmpty);
  });

  testWidgets('link success: syncing state, then Activity, pending link cleared, one token and one exchange', (tester) async {
    final s = _Server();
    final (c, router) = await _pump(tester, s);
    await tester.tap(find.text('Link a bank'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Syncing your accounts…'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 600));
    expect(router.state.uri.path, '/');
    expect(c.read(shellTabProvider), 1, reason: 'lands on Activity');
    expect(s.calls.where((x) => x == 'POST /plaid/link-token').length, 1);
    expect(s.calls.where((x) => x == 'POST /plaid/complete').length, 1);
    expect(c.read(bankStepStoreProvider).pendingLink, isNull);
    await _drain(tester);
  });

  testWidgets('cancelling the Plaid sheet is quiet: still on the step, no error, can skip', (tester) async {
    final s = _Server();
    final (_, router) = await _pump(tester, s, auth: (u) async => throw PlatformException(code: 'CANCELED'));
    await tester.tap(find.text('Link a bank'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(router.state.uri.path, '/onboarding/bank');
    expect(find.textContaining('went through'), findsNothing);
    expect(find.text('Skip for now'), findsOneWidget);
    expect(s.calls.where((x) => x.contains('complete')), isEmpty);
  });

  testWidgets('link error: a specific reason, a retry, and skipping still works', (tester) async {
    final s = _Server(tokenStatus: 502);
    final (_, router) = await _pump(tester, s);
    await tester.tap(find.text('Link a bank'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('Bank link unavailable'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    await tester.tap(find.text('Skip for now'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(router.state.uri.path, '/');
  });

  testWidgets('a server 403 on a stale screen shows the owner-only reason, not a bare failure', (tester) async {
    final s = _Server(tokenStatus: 403);
    await _pump(tester, s);
    await tester.tap(find.text('Link a bank'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('limited to this Tick'), findsWidgets);
    expect(find.textContaining('didn\'t go through'), findsNothing);
  });

  testWidgets('offline during the exchange after the bank finished says it may still be connecting', (tester) async {
    final c0 = _Server(completeStatus: 200);
    final client = MockClient((r) async {
      if (r.url.path == '/plaid/complete') throw http.ClientException('down');
      return http.Response(jsonEncode(r.url.path == '/plaid/links' ? {'used': 0, 'cap': 10, 'left': 10, 'can_link': true, 'total_left': 10} : {'link_token': 'link-production-abc123456', 'hosted_link_url': 'https://h/x'}), 200);
    });
    final out = await runBankLink(Api(client: client), (u) async => 'tick://plaid-complete');
    expect(out.result, LinkResult.pending);
    expect(out.message, stillConnecting);
    expect(c0.calls, isEmpty);
  });

  testWidgets('non-owner: no Link button, clear copy, Continue and import', (tester) async {
    final s = _Server(canLink: false);
    final (_, router) = await _pump(tester, s);
    expect(find.text('Link a bank'), findsNothing);
    expect(find.textContaining('Banks are linked by this Tick\'s owner', findRichText: true), findsOneWidget);
    expect(find.text('Continue'), findsOneWidget);
    expect(find.text('Import a statement'), findsOneWidget);
    await tester.tap(find.text('Import a statement'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(router.state.uri.path, '/import');
  });

  testWidgets('every Plaid slot used: owner sees the same no-link copy instead of a button that can only fail', (tester) async {
    await _pump(tester, _Server(totalLeft: 0));
    expect(find.text('Link a bank'), findsNothing);
    expect(find.text('Continue'), findsOneWidget);
  });

  testWidgets('already linked: the step skips itself', (tester) async {
    final (c, router) = await _pump(tester, _Server(), connections: const [Connection(id: 'c1', institution: 'Chase', status: 'active')]);
    await tester.pump(const Duration(milliseconds: 500));
    expect(router.state.uri.path, '/');
    expect(find.text('Track a bank account'), findsNothing);
    expect(c.read(bankStepStoreProvider).seen, isTrue);
  });

  testWidgets('fits an iPhone SE at large text without overflow', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _pump(tester, _Server(), w: 320, h: 568);
    expect(tester.takeException(), isNull);
    expect(find.text('Skip for now'), findsOneWidget);
  });

  test('resuming a killed link: an idempotent exchange clears the pending token; a dead token is dropped; offline keeps it', () async {
    var cleared = 0;
    final ok = Api(client: MockClient((r) async => http.Response(jsonEncode({'connections': ['c1']}), 200)));
    expect(await resumePendingLink(ok, 'link-production-abc', () async => cleared++), isTrue);
    expect(cleared, 1);
    final dead = Api(client: MockClient((r) async => http.Response(jsonEncode({'detail': 'link session not found'}), 404)));
    expect(await resumePendingLink(dead, 'link-production-abc', () async => cleared++), isFalse);
    expect(cleared, 2);
    final off = Api(client: MockClient((r) async => throw http.ClientException('down')));
    expect(await resumePendingLink(off, 'link-production-abc', () async => cleared++), isFalse);
    expect(cleared, 2, reason: 'offline: keep the token for the next launch');
  });
}
