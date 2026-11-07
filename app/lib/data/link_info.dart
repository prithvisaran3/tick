import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/api.dart';
import '../services/session.dart';
import 'ledger.dart';
import 'settings.dart';

/// What GET /plaid/links says about linking NEW banks for this person.
/// Plaid's Trial cap is shared by everyone, so [totalLeft] is the number that matters; [canLink] is false for anyone who is not the owner.
class LinkInfo {
  const LinkInfo({required this.used, required this.cap, required this.left, required this.canLink, required this.totalLeft, this.known = true});
  final int used, cap, left, totalLeft;
  final bool canLink;
  final bool known; // false when the server could not be asked (offline, demo): the buttons stay, the server still enforces

  /// Slots a new link could really use: the smaller of my own and the shared count.
  int get slotsLeft => left < totalLeft ? left : totalLeft;

  factory LinkInfo.fromJson(Map<String, dynamic> j) {
    int n(String k, int d) => (j[k] as num?)?.toInt() ?? d;
    final left = n('left', 0);
    return LinkInfo(used: n('used', 0), cap: n('cap', 10), left: left, canLink: (j['can_link'] as bool?) ?? true, totalLeft: n('total_left', left));
  }
  factory LinkInfo.unknown(int used) => LinkInfo(used: used, cap: 10, left: 10 - used, canLink: true, totalLeft: 10 - used, known: false);
}

/// Null in demo mode (nothing to link). On any failure: [LinkInfo.unknown], never an error state.
final linkInfoProvider = FutureProvider.autoDispose<LinkInfo?>((ref) async {
  if (ref.watch(settingsProvider.select((s) => s.demoMode))) return null;
  final uid = ref.watch(userIdProvider);
  final used = ref.read(ledgerProvider).linksUsed;
  if (uid == null) return LinkInfo.unknown(used);
  try {
    return LinkInfo.fromJson(await ref.read(apiProvider).get('/plaid/links'));
  } catch (_) {
    return LinkInfo.unknown(used);
  }
});
