import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/pay_splits.dart';
import '../services/api.dart';
import 'ledger.dart';
import 'remote.dart';
import 'settings.dart';

/// My paycheck's destinations, in order. Empty: the whole paycheck lands in one account.
final paySplitsProvider = FutureProvider<List<PaySplit>>((ref) async {
  ref.watch(ledgerRevisionProvider);
  final r = ref.watch(remoteProvider);
  if (r == null || ref.watch(settingsProvider.select((s) => s.demoMode))) return const [];
  final rows = await r.db.from('pay_splits').select('account_id,label,mask,kind,value,sort').order('sort');
  return [for (final j in rows) PaySplit.fromJson(j)];
});

class PaySplitsApi {
  PaySplitsApi(this.ref);
  final Ref ref;
  /// The whole set at once: the database checks it (one rest, percents within 100%, my accounts) and replaces what was there.
  Future<void> save(List<PaySplit> splits) async {
    final r = ref.read(remoteProvider);
    if (r == null) throw ApiException(0, 'Sign in to save this.');
    await r.db.rpc('save_pay_splits', params: {'p': [for (final s in splits) s.toJson()]});
    ref.invalidate(paySplitsProvider);
    ref.read(ledgerProvider.notifier).refresh();
  }
  /// The latest pay statement's deposit lines as split lines, and its net. Nothing is saved.
  Future<({List<PaySplit> splits, int? netCents})> suggested() async {
    final j = await ref.read(apiProvider).get('/pay/splits/suggested');
    return (splits: [for (final s in (j['splits'] as List? ?? const [])) PaySplit.fromJson((s as Map).cast<String, dynamic>())], netCents: (j['net_cents'] as num?)?.toInt());
  }
}

final paySplitsApiProvider = Provider<PaySplitsApi>(PaySplitsApi.new);
