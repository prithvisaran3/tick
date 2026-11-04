import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:local_auth/local_auth.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../data/env.dart';

class AuthService {
  bool _inited = false;

  Future<void> _init() async {
    if (_inited) return;
    await GoogleSignIn.instance.initialize(clientId: Env.googleIosClientId.isEmpty ? null : Env.googleIosClientId, serverClientId: Env.googleWebClientId.isEmpty ? null : Env.googleWebClientId);
    _inited = true;
  }

  /// Google -> Supabase via signInWithIdToken (nonce check is disabled server-side because google_sign_in does not expose one).
  Future<bool> signInWithGoogle() async {
    await _init();
    final account = await GoogleSignIn.instance.authenticate();
    final idToken = account.authentication.idToken;
    if (idToken == null) throw StateError('No ID token from Google');
    await Supabase.instance.client.auth.signInWithIdToken(provider: OAuthProvider.google, idToken: idToken);
    return true;
  }

  Future<void> signOut() async {
    try { await GoogleSignIn.instance.signOut(); } catch (_) {}
    await Supabase.instance.client.auth.signOut();
  }

  Session? get session => Env.hasSupabase ? Supabase.instance.client.auth.currentSession : null;
  String? get displayName => Supabase.instance.client.auth.currentUser?.userMetadata?['full_name'] as String?;

  final _local = LocalAuthentication();
  Future<bool> unlock() async {
    try {
      return await _local.authenticate(localizedReason: 'Unlock Tick');
    } catch (_) {
      return false;
    }
  }
}

final authServiceProvider = Provider<AuthService>((ref) => AuthService());
