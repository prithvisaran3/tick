// App-side security controls (Part 6). Native pieces (Keychain, file protection, capture detection) are behind seams tested here;
// the Swift side can only be checked on a device (docs/NEXT.md).
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tick/domain/money.dart';
import 'package:tick/services/lock.dart';
import 'package:tick/services/privacy.dart';
import 'package:tick/services/secure_session.dart';

class MemoryStore implements SecretStore {
  final m = <String, String>{};
  @override
  Future<String?> read(String key) async => m[key];
  @override
  Future<void> write(String key, String value) async => m[key] = value;
  @override
  Future<void> delete(String key) async => m.remove(key);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the Supabase session lives in the secret store and an old SharedPreferences copy is moved, then deleted', () async {
    SharedPreferences.setMockInitialValues({'sb-proj-auth-token': '{"access_token":"old"}', 'tick.settings': '{}'});
    final store = MemoryStore();
    final s = SecureSessionStorage(store: store, legacyKey: 'sb-proj-auth-token');
    await s.initialize();
    expect(await s.accessToken(), '{"access_token":"old"}');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('sb-proj-auth-token'), isFalse);            // no session left in a plain plist
    await s.persistSession('{"access_token":"new"}');
    expect(await s.hasAccessToken(), isTrue);
    await s.removePersistedSession();
    expect(await s.hasAccessToken(), isFalse);
    final pkce = SecurePkceStorage(store: store);
    await pkce.setItem(key: 'verifier', value: 'v');
    expect(await pkce.getItem(key: 'verifier'), 'v');
    expect(store.m.keys, contains('tick.pkce.verifier'));
  });

  test('Keychain items are this-device-only and only while unlocked', () {
    final src = File('lib/services/secure_session.dart').readAsStringSync();
    expect(src, contains('KeychainAccessibility.unlocked_this_device'));
    expect(src, contains('synchronizable: false'));
  });

  test('hide amounts masks every formatted amount, but never exported numbers', () {
    MoneyMask.hidden = true;
    addTearDown(() => MoneyMask.hidden = false);
    expect(formatCents(-184000), r'$••••');
    expect(formatDollars(21400), r'$••••');
    expect(formatCents(-184000, raw: true), '−\$1,840.00');
    MoneyMask.hidden = false;
    expect(formatDollars(21400), r'$214');
  });

  test('Face ID asks again only after the chosen timeout', () {
    expect(shouldRelock(Duration.zero, 0), isFalse);
    expect(shouldRelock(const Duration(seconds: 1), 0), isTrue);
    expect(shouldRelock(const Duration(seconds: 59), 60), isFalse);
    expect(shouldRelock(const Duration(minutes: 1), 60), isTrue);
  });

  test('privacy channel soft-fails without the native side', () async {
    await Privacy.protect(['/nope']);
    expect(await Privacy.isCaptured(), isFalse);
  });

  test('the cached ledger and Activity page are protected after every write', () {
    for (final f in ['lib/data/ledger_cache.dart', 'lib/data/activity.dart']) {
      expect(File(f).readAsStringSync(), contains('Privacy.protect'), reason: f);
    }
  });

  test('builds carry no secrets: the only dart-defines are the URL, the publishable key and switches', () {
    final env = File('lib/data/env.dart').readAsStringSync();
    final names = RegExp(r"fromEnvironment\('([A-Z_]+)'").allMatches(env).map((m) => m.group(1)).toSet();
    expect(names, {'SUPABASE_URL', 'SUPABASE_PUBLISHABLE_KEY', 'API_BASE_URL', 'TICK_PERF', 'TICK_WIDGETS'});
  });

  test('the app never mints capture tokens or writes them itself', () {
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      final s = f.readAsStringSync();
      expect(s.contains("from('ingest_tokens').insert"), isFalse, reason: f.path);
      expect(s.contains('Random.secure'), isFalse, reason: f.path);
    }
  });
}
