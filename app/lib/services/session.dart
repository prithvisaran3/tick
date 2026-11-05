import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../data/env.dart';
import 'secure_session.dart';

/// Supabase starts AFTER the first frame so a slow or offline network can never delay launch.
final bootstrapProvider = FutureProvider<void>((ref) async {
  if (!Env.hasSupabase) return;
  await Supabase.initialize(
    url: Env.supabaseUrl, publishableKey: Env.supabasePublishableKey,
    // Keychain, not SharedPreferences: tokens never sit in a plain plist or in a backup.
    authOptions: FlutterAuthClientOptions(
      localStorage: SecureSessionStorage(legacyKey: 'sb-${Uri.parse(Env.supabaseUrl).host.split('.').first}-auth-token'),
      pkceAsyncStorage: const SecurePkceStorage(),
    ),
  );
});

/// Current Supabase session; emits on sign-in, sign-out and token refresh. null while unresolved or signed out.
final authSessionProvider = StreamProvider<Session?>((ref) async* {
  if (!Env.hasSupabase) {
    yield null;
    return;
  }
  final init = ref.watch(bootstrapProvider.future);
  try {
    await init.timeout(const Duration(seconds: 8));
  } on TimeoutException {
    yield null;                                   // slow network: let the app show cached data now, keep waiting in the background
    await init;
  }
  final c = Supabase.instance.client;
  yield c.auth.currentSession;
  yield* c.auth.onAuthStateChange.map((e) => e.session);
});

/// Just the user id, so token refreshes (hourly) don't rebuild the ledger.
final userIdProvider = Provider<String?>((ref) => ref.watch(authSessionProvider.select((a) => a.asData?.value?.user.id)));

/// True until Supabase has told us whether there is a saved session.
final sessionResolvingProvider = Provider<bool>((ref) => Env.hasSupabase && ref.watch(authSessionProvider).isLoading);
