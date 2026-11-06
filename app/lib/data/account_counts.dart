import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'ledger.dart';
import 'remote.dart';
import 'settings.dart';

class AccountCount {
  const AccountCount(this.count, this.latest);
  final int count;
  final DateTime? latest;
}

/// Transactions held per account (Banks shows them so "synced" is never just a word). SQL in live mode, a local count in demo.
final accountCountsProvider = FutureProvider<Map<String, AccountCount>>((ref) async {
  ref.watch(ledgerRevisionProvider);
  final demo = ref.watch(settingsProvider.select((s) => s.demoMode));
  final remote = ref.watch(remoteProvider);
  if (!demo && remote != null) {
    final j = await remote.db.rpc('tick_account_counts') as Map;
    return {for (final e in j.entries) e.key as String: AccountCount((e.value['count'] as num).toInt(), DateTime.tryParse('${e.value['latest']}')?.toLocal())};
  }
  final out = <String, AccountCount>{};
  for (final t in ref.read(ledgerProvider).txns) {
    final id = t.accountId;
    if (id == null) continue;
    final cur = out[id];
    out[id] = AccountCount((cur?.count ?? 0) + 1, cur?.latest == null || t.occurredAt.isAfter(cur!.latest!) ? t.occurredAt : cur.latest);
  }
  return out;
});
