import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app.dart';
import 'data/ledger.dart';
import 'data/ledger_cache.dart';
import 'data/settings.dart';
import 'services/errors.dart';

/// Startup budget: first frame needs only SharedPreferences and the on-disk snapshot (decoded off the UI isolate).
/// Supabase, haptics, notifications and everything networked start AFTER the first frame.
Future<void> main() async {
  await AppErrors.guarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    AppErrors.install();
    final prefs = await SharedPreferences.getInstance();
    final cached = await LedgerCache.read();
    runApp(ProviderScope(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        initialLedgerProvider.overrideWithValue(cached == null ? null : CachedLedger(cached.userId, cached.state)),
      ],
      child: const TickApp(),
    ));
  });
}
