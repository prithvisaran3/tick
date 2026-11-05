import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Supabase session and PKCE verifier in the iOS Keychain, readable only while the phone is unlocked and never copied to
/// another device or a backup (kSecAttrAccessibleWhenUnlockedThisDeviceOnly). Replaces supabase_flutter's SharedPreferences default.
const _ios = IOSOptions(accessibility: KeychainAccessibility.unlocked_this_device, synchronizable: false);

/// Thin seam so tests can swap the Keychain for memory.
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class KeychainStore implements SecretStore {
  const KeychainStore();
  static const _s = FlutterSecureStorage(iOptions: _ios);
  @override
  Future<String?> read(String key) => _s.read(key: key);
  @override
  Future<void> write(String key, String value) => _s.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _s.delete(key: key);
}

class SecureSessionStorage extends LocalStorage {
  SecureSessionStorage({this.store = const KeychainStore(), this.key = 'tick.supabase.session', this.legacyKey});
  final SecretStore store;
  final String key;
  /// The SharedPreferences key supabase_flutter used before; a session found there is moved to the Keychain once, then deleted.
  final String? legacyKey;

  @override
  Future<void> initialize() async {
    if (legacyKey == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final old = prefs.getString(legacyKey!);
      if (old != null) {
        if (await store.read(key) == null) await store.write(key, old);
        await prefs.remove(legacyKey!);
      }
    } catch (_) {/* migration is best effort; the person can sign in again */}
  }

  @override
  Future<bool> hasAccessToken() async => (await store.read(key)) != null;
  @override
  Future<String?> accessToken() => store.read(key);
  @override
  Future<void> removePersistedSession() => store.delete(key);
  @override
  Future<void> persistSession(String persistSessionString) => store.write(key, persistSessionString);
}

class SecurePkceStorage extends GotrueAsyncStorage {
  const SecurePkceStorage({this.store = const KeychainStore()});
  final SecretStore store;
  @override
  Future<String?> getItem({required String key}) => store.read('tick.pkce.$key');
  @override
  Future<void> setItem({required String key, required String value}) => store.write('tick.pkce.$key', value);
  @override
  Future<void> removeItem({required String key}) => store.delete('tick.pkce.$key');
}
