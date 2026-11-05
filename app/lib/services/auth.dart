import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:local_auth/local_auth.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../data/env.dart';
import 'web_auth.dart';

enum AuthFailureKind { cancelled, offline, notConfigured, failed }

/// What went wrong signing in, in terms the UI can show calmly.
class AuthFailure implements Exception {
  const AuthFailure(this.kind);
  final AuthFailureKind kind;
  String get message => switch (kind) {
        AuthFailureKind.cancelled => 'Sign-in was cancelled. Try again when you are ready.',
        AuthFailureKind.offline => 'You are offline. Connect and try again.',
        AuthFailureKind.notConfigured => 'This build is not connected to Tick yet. Run it with the values from docs/RUN_ON_MAC.md.',
        AuthFailureKind.failed => 'That didn\'t go through. Try again, nothing was lost.',
      };
  @override
  String toString() => 'AuthFailure(${kind.name})';
}

/// One sign-in flow: Supabase Google OAuth (PKCE) in an ASWebAuthenticationSession, returning to tick://login-callback.
/// It needs no Google iOS client, no reversed client id and no bundle-id match, so a changed bundle id (free Apple account) cannot break it.
/// Requirements (server side, already set): Google provider enabled in Supabase with the web client, redirect `tick://login-callback` allow-listed,
/// and `https://<project>.supabase.co/auth/v1/callback` authorised on the Google web client.
class AuthService {
  static const redirect = 'tick://login-callback';

  Future<void> signInWithGoogle() async {
    if (!Env.hasSupabase) throw const AuthFailure(AuthFailureKind.notConfigured);
    // Fail fast and calmly when offline instead of opening a browser sheet that can't load.
    try {
      await http.get(Uri.parse('${Env.supabaseUrl}/auth/v1/health'), headers: {'apikey': Env.supabasePublishableKey}).timeout(const Duration(seconds: 6));
    } on SocketException { throw const AuthFailure(AuthFailureKind.offline); }
    on TimeoutException { throw const AuthFailure(AuthFailureKind.offline); }
    on http.ClientException { throw const AuthFailure(AuthFailureKind.offline); }
    catch (_) {/* reachable enough: let the real flow report any error */}

    final auth = Supabase.instance.client.auth;
    String callback;
    try {
      final res = await auth.getOAuthSignInUrl(provider: OAuthProvider.google, redirectTo: redirect, queryParams: const {'prompt': 'select_account'});
      callback = await webAuthenticate(res.url);
    } on PlatformException catch (e) {
      throw AuthFailure(e.code == 'CANCELED' ? AuthFailureKind.cancelled : AuthFailureKind.failed);
    } on SocketException {
      throw const AuthFailure(AuthFailureKind.offline);
    } on AuthException {
      throw const AuthFailure(AuthFailureKind.failed);
    }
    try {
      await auth.getSessionFromUrl(Uri.parse(callback));
    } on SocketException {
      throw const AuthFailure(AuthFailureKind.offline);
    } on AuthException {
      throw const AuthFailure(AuthFailureKind.failed);
    }
  }

  Future<void> signOut() async {
    try { await Supabase.instance.client.auth.signOut(); } catch (_) {}
  }

  Session? get session => Env.hasSupabase ? _safeSession() : null;
  Session? _safeSession() {
    try { return Supabase.instance.client.auth.currentSession; } catch (_) { return null; }
  }

  String? get displayName {
    try { return Supabase.instance.client.auth.currentUser?.userMetadata?['full_name'] as String?; } catch (_) { return null; }
  }

  final _local = LocalAuthentication();

  /// Face ID / passcode. Returns false on any failure (never throws, never blocks launch).
  Future<bool> unlock() async {
    try {
      if (!await _local.isDeviceSupported()) return true;           // nothing to unlock with: don't lock the person out
      return await _local.authenticate(localizedReason: 'Unlock Tick');
    } catch (_) {
      return false;
    }
  }
}

final authServiceProvider = Provider<AuthService>((ref) => AuthService());
