import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tick/data/demo_seed.dart';
import 'package:tick/data/ledger.dart';
import 'package:tick/data/ledger_codec.dart';
import 'package:tick/data/link_info.dart';
import 'package:tick/data/settings.dart';
import 'package:tick/domain/csv.dart';
import 'package:tick/domain/models.dart';
import 'package:tick/services/api.dart';
import 'package:tick/services/auth.dart';
import 'package:tick/services/bank_link.dart';
import 'package:tick/services/haptics.dart';
import 'package:tick/services/web_auth.dart';
import 'golden_harness.dart';

void main() {
  apiMessageTests();
  TestWidgetsFlutterBinding.ensureInitialized();
  TickHaptics.instance.recordOnly = true;
  final now = fixedNow;
  LedgerState demoState() {
    final d = buildDemo(now);
    return LedgerState(categories: d.categories, accounts: d.accounts, txns: d.txns, recurring: d.recurring, expected: d.expected, goals: d.goals, budgets: d.budgets, linksUsed: 3,
        connections: const [Connection(id: 'c1', institution: 'Chase', status: 'login_required')], rules: const [LearnedRule(id: 'r1', pattern: 'uber', categoryId: 'cat-rideshare')]);
  }

  group('offline snapshot codec', () {
    test('round trip keeps everything the screens need', () {
      final s = demoState();
      final json = jsonDecode(jsonEncode(encodeLedger(s, userId: 'u1'))) as Map<String, dynamic>;     // through real JSON text
      final back = decodeLedger(json)!;
      expect(back.txns.length, s.txns.length);
      expect(back.txns.first.amountCents, s.txns.first.amountCents);
      expect(back.txns.first.occurredAt.isAtSameMomentAs(s.txns.first.occurredAt), isTrue);
      expect(back.txns.first.needsReview, s.txns.first.needsReview);
      expect(back.recurring.length, s.recurring.length);
      expect(back.recurring.first.priceHistory, s.recurring.first.priceHistory);
      expect(back.goals.map((g) => g.perPaydayCents), s.goals.map((g) => g.perPaydayCents));
      expect(back.budgets.length, s.budgets.length);
      expect(back.connections.single.needsRelink, isTrue);
      expect(back.rules.single.pattern, 'uber');
      expect(back.accounts.map((a) => a.availableCents), s.accounts.map((a) => a.availableCents));
      expect(back.linksUsed, 3);
      expect(json['userId'], 'u1');
    });

    test('corrupt, wrong-version or truncated data decodes to null and never throws', () {
      expect(decodeLedger({'v': 99}), isNull);
      expect(decodeLedger({'v': 1, 'txns': 'nope'}), isNull);
      expect(decodeLedger({'v': 1, 'txns': [{'id': 1}]}), isNull);
      expect(decodeLedger(<String, dynamic>{}), isNull);
    });

    test('very long histories are capped so the file stays small', () {
      final many = [for (var i = 0; i < 3000; i++) Txn(id: 't$i', amountCents: -100, occurredAt: now.subtract(Duration(hours: i)), merchant: 'x')];
      expect((encodeLedger(LedgerState(txns: many))['txns'] as List).length, 1200);
    });
  });

  group('settings and ledger providers', () {
    test('corrupt saved settings fall back to defaults instead of crashing launch', () async {
      SharedPreferences.setMockInitialValues({'tick.settings': '{not json'});
      final prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(overrides: [sharedPrefsProvider.overrideWithValue(prefs)]);
      addTearDown(c.dispose);
      expect(c.read(settingsProvider).onboardingDone, isFalse);
      expect(prefs.getString('tick.settings'), isNull);
    });

    test('an unrelated settings change does not wipe the ledger (regression: ledger watched all settings)', () async {
      final c = await demoContainer(demo: false);
      addTearDown(c.dispose);
      final n = c.read(ledgerProvider.notifier);
      await n.add(amountCents: -1234, merchant: 'Corner Store');
      final before = c.read(ledgerProvider).txns.length;
      c.read(settingsProvider.notifier).update((s) => s.copyWith(lastMorningReceipt: '2026-11-04'));
      c.read(settingsProvider.notifier).update((s) => s.copyWith(sound: false));
      expect(c.read(ledgerProvider).txns.length, before);
      expect(c.read(ledgerProvider).txns.any((t) => t.merchant == 'Corner Store'), isTrue);
    });

    test('guest mode has default categories so quick add can categorise', () async {
      final c = await demoContainer(demo: false);
      addTearDown(c.dispose);
      expect(c.read(ledgerProvider).categories, isNotEmpty);
      final t = await c.read(ledgerProvider.notifier).add(amountCents: -500, merchant: 'Blue Bottle');
      expect(c.read(ledgerProvider).category(t.categoryId)?.name, 'Coffee');
    });

    test('last-known data is on screen immediately from the snapshot (no loading state)', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        clockProvider.overrideWithValue(() => now),
        initialLedgerProvider.overrideWithValue(CachedLedger(null, demoState())),
      ]);
      addTearDown(c.dispose);
      final l = c.read(ledgerProvider);
      expect(l.loading, isFalse);
      expect(l.txns, isNotEmpty);
    });

    test('patching or resolving a purchase that vanished is a no-op, not a crash', () async {
      final c = await demoContainer();
      addTearDown(c.dispose);
      await c.read(ledgerProvider.notifier).markLooksRight('does-not-exist');
      await c.read(ledgerProvider.notifier).toggleBusiness('does-not-exist');
      await c.read(ledgerProvider.notifier).recategorize('does-not-exist', 'cat-other');
    });

    test('wipeLocal forgets everything', () async {
      final c = await demoContainer(demo: false);
      addTearDown(c.dispose);
      await c.read(ledgerProvider.notifier).add(amountCents: -100, merchant: 'x');
      await c.read(ledgerProvider.notifier).wipeLocal();
      expect(c.read(ledgerProvider).txns, isEmpty);
    });
  });

  group('api client', () {
    test('GET retries 5xx with backoff then succeeds; errors become plain text', () async {
      var calls = 0;
      final api = Api(client: MockClient((r) async => ++calls < 3 ? http.Response('{"detail":"x"}', 503) : http.Response('{"ok":true}', 200)));
      expect((await api.get('/plaid/links'))['ok'], true);
      expect(calls, 3);
    });

    test('POST is never retried blindly; 4xx detail strings pass through, lists and 5xx become a specific plain sentence', () async {
      var calls = 0;
      final api = Api(client: MockClient((r) async { calls++; return http.Response('{"detail":"You have used all 10 bank links."}', 409); }));
      await expectLater(api.post('/plaid/link-token'), throwsA(isA<ApiException>().having((e) => e.message, 'message', 'You have used all 10 bank links.')));
      expect(calls, 1);
      final bad = Api(client: MockClient((r) async => http.Response('{"detail":[{"loc":["body"],"msg":"field required"}]}', 422)));
      await expectLater(bad.post('/x'), throwsA(isA<ApiException>().having((e) => e.message, 'message', contains('isn\'t valid'))));
      final boom = Api(client: MockClient((r) async => http.Response('<html>oops secret stack</html>', 500)));
      await expectLater(boom.post('/x'), throwsA(isA<ApiException>().having((e) => e.message, 'message', allOf(contains('having trouble'), isNot(contains('secret'))))));
    });

    test('non-idempotent Plaid POSTs are sent exactly once on 5xx, timeout and dropped connections', () async {
      for (final fail in <Future<http.Response> Function()>[
        () async => http.Response('{}', 502),
        () async { await Future<void>.delayed(const Duration(milliseconds: 80)); return http.Response('{}', 200); },
        () async => throw const SocketException('reset'),
        () async => throw http.ClientException('closed'),
      ]) {
        var calls = 0;
        final api = Api(client: MockClient((r) { calls++; return fail(); }));
        await expectLater(api.post('/plaid/complete', {'link_token': 'link-x'}, const Duration(milliseconds: 20)), throwsA(isA<ApiException>()));
        expect(calls, 1, reason: 'a retried /plaid/complete could race the webhook');
      }
    });

    test('offline and timeouts surface as offline errors after retries', () async {
      var calls = 0;
      final off = Api(client: MockClient((r) async { calls++; throw const SocketException('down'); }));
      await expectLater(off.get('/health'), throwsA(isA<ApiException>().having((e) => e.offline, 'offline', true)));
      expect(calls, 3);                                  // 1 try + 2 retries
      final slow = Api(client: MockClient((r) async { await Future<void>.delayed(const Duration(milliseconds: 200)); return http.Response('{}', 200); }));
      await expectLater(slow.get('/x', timeout: const Duration(milliseconds: 20)), throwsA(isA<ApiException>().having((e) => e.offline, 'offline', true)));
    });

    test('a 401 is retried once, a second 401 is reported', () async {
      var calls = 0;
      final api = Api(client: MockClient((r) async { calls++; return http.Response('{"detail":"token expired"}', 401); }));
      await expectLater(api.get('/x'), throwsA(isA<ApiException>().having((e) => e.status, 'status', 401)));
      expect(calls, 2);
    });
  });

  group('web auth channel', () {
    const channel = MethodChannel('tick/webauth');
    tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

    test('returns the callback url from the native session', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'authenticate');
        expect((call.arguments as Map)['scheme'], 'tick');
        return 'tick://login-callback?code=abc';
      });
      expect(await webAuthenticate('https://example.com/auth'), 'tick://login-callback?code=abc');
    });

    test('a closed sheet surfaces as CANCELED', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async => throw PlatformException(code: 'CANCELED'));
      await expectLater(webAuthenticate('https://example.com/auth'), throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'CANCELED')));
    });
  });

  group('auth failures', () {
    test('each failure kind has calm copy, cancelled is not an error tone', () {
      for (final k in AuthFailureKind.values) {
        final m = AuthFailure(k).message;
        expect(m, isNotEmpty);
        expect(m.toLowerCase(), isNot(contains('exception')));
      }
      expect(const AuthFailure(AuthFailureKind.offline).message, contains('offline'));
      expect(const AuthFailure(AuthFailureKind.failed).message, contains('Sign-in didn\'t finish'));
    });

    test('without Supabase config sign-in reports notConfigured instead of hanging', () async {
      await expectLater(AuthService().signInWithGoogle(), throwsA(isA<AuthFailure>().having((f) => f.kind, 'kind', AuthFailureKind.notConfigured)));
    });
  });

  group('manual balance and csv', () {
    test('typing a balance creates one manual account and changes Safe to spend honestly', () async {
      final c = await demoContainer(demo: false);
      addTearDown(c.dispose);
      c.read(settingsProvider.notifier).update((s) => s.copyWith(rule: PaydayRule(frequency: PayFrequency.biweekly, anchor: DateTime(2026, 11, 6), amountCents: 231000)));
      expect(c.read(ledgerProvider).accounts, isEmpty);
      await c.read(ledgerProvider.notifier).setManualBalance(120000);
      await c.read(ledgerProvider.notifier).setManualBalance(150000); // editing replaces, never duplicates
      final accts = c.read(ledgerProvider).accounts;
      expect(accts.length, 1);
      expect(accts.single.availableCents, 150000);
      expect(c.read(safeToSpendProvider)!.cashCents, 150000);
    });

    test('csv cells are quoted and spreadsheet formulas neutralised', () {
      expect(csvCell('Blue "Bottle"'), '"Blue ""Bottle"""');
      expect(csvCell('=HYPERLINK("http://evil")'), startsWith("\"'="));
      expect(csvCell('+1 555'), startsWith("\"'+"));
      expect(csvCell('-5'), startsWith("\"'-"));
      expect(csvCell('normal'), '"normal"');
      final l = LedgerState(categories: defaultCategories, txns: [Txn(id: 'a', amountCents: -1840, occurredAt: now, merchant: '=cmd', categoryId: 'cat-coffee')]);
      final csv = buildCsv(l);
      expect(csv.split('\n')[1], contains('-18.40'));
      expect(csv, contains("\"'=cmd\""));
    });
  });

  test('exactly one list per route enables Hero (duplicate tags would throw during navigation)', () {
    var uses = 0;
    for (final f in Directory('lib/features').listSync().whereType<File>()) {
      uses += RegExp(r'hero: true').allMatches(f.readAsStringSync()).length;
    }
    expect(uses, 1);
  });
}

void apiMessageTests() {
  group('every status has its own user-facing message', () {
    test('messageForStatus', () {
      expect(messageForStatus(401, 'token expired'), contains('signed out'));
      expect(messageForStatus(403, null), contains('access'));
      expect(messageForStatus(403, 'Linking banks is limited to this Tick\'s owner.'), contains('owner'));
      expect(messageForStatus(404, null), contains('wasn\'t found'));
      expect(messageForStatus(409, null), contains('conflicts'));
      expect(messageForStatus(422, [{'msg': 'x'}]), contains('isn\'t valid'));
      expect(messageForStatus(429, null), contains('Too many'));
      expect(messageForStatus(500, '<html>secret</html>'), allOf(contains('having trouble'), isNot(contains('secret'))));
      expect(messageForStatus(502, 'Bank link unavailable (ITEM_LOGIN_REQUIRED)'), contains('ITEM_LOGIN_REQUIRED'));
      for (final s in [400, 401, 403, 404, 409, 422, 429, 500, 502, 503]) {
        expect(messageForStatus(s, null), isNot(contains('That didn\'t go through')), reason: 'status $s');
      }
    });
    test('linkErrorMessage separates 403 from 409 and names other causes', () {
      expect(linkErrorMessage(ApiException(403, 'x')), linkLimitedMessage);
      expect(linkErrorMessage(ApiException(409, 'x')), linkLimitedMessage);
      expect(linkErrorMessage(ApiException(0, 'Can\'t reach Tick right now.', offline: true)), contains('reach'));
      expect(linkErrorMessage(ApiException(502, 'Bank link unavailable (X)')), contains('Bank link unavailable'));
      expect(linkErrorMessage(StateError('x')), 'Couldn\'t link that bank. Try again.');
    });
  });
}
