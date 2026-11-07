import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/session.dart';
import 'ledger.dart';
import 'settings.dart';

/// Per-person memory for the optional "Track a bank account" onboarding step, kept in local storage keyed by user id
/// (a second person on the same phone gets their own). Nothing here is a secret: a flag and an unfinished Plaid link-token.
class BankStepStore {
  BankStepStore(this._p, this._uid);
  final SharedPreferences? _p;
  final String? _uid;
  String get _suffix => _uid ?? 'guest';

  bool get seen => _p?.getBool('tick.bankStepSeen.$_suffix') ?? false;
  Future<void> markSeen() async => _p?.setBool('tick.bankStepSeen.$_suffix', true);

  /// The Plaid link-token of a link the person started but we haven't finished exchanging (the app may have been killed mid-link).
  /// Exchanging it again is safe: /plaid/complete is idempotent, one session is one Item and one slot.
  String? get pendingLink => _p?.getString('tick.pendingLink.$_suffix');
  Future<void> setPendingLink(String token) async => _p?.setString('tick.pendingLink.$_suffix', token);
  Future<void> clearPendingLink() async => _p?.remove('tick.pendingLink.$_suffix');
}

final bankStepStoreProvider = Provider<BankStepStore>((ref) => BankStepStore(ref.watch(sharedPrefsProvider), ref.watch(userIdProvider)));

/// Where setup goes next: the optional bank step once for a signed-in person with no banks who hasn't seen it, otherwise Today.
String routeAfterSetup(WidgetRef ref) {
  final s = ref.read(settingsProvider);
  if (s.demoMode || ref.read(userIdProvider) == null) return '/';
  final store = ref.read(bankStepStoreProvider);
  if (store.seen) return '/';
  if (ref.read(ledgerProvider).connections.isNotEmpty) { store.markSeen(); return '/'; }
  return '/onboarding/bank';
}
