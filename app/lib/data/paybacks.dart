import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/api.dart';
import 'ledger.dart';
import 'remote.dart';
import 'settings.dart';
import 'tally_store.dart';

@immutable
class PaybackCandidate {
  const PaybackCandidate({required this.purchaseId, required this.merchant, required this.amountCents, required this.leftCents, required this.date});
  final String purchaseId;
  final String merchant;
  final int amountCents;
  final int leftCents;
  final DateTime date;
}

/// A person-to-person credit that may be someone paying me back. Nothing is linked until I say so.
@immutable
class PaybackSuggestion {
  const PaybackSuggestion({required this.paybackId, required this.amountCents, required this.date, this.from, this.candidates = const []});
  final String paybackId;
  final int amountCents;
  final String? from;
  final DateTime date;
  final List<PaybackCandidate> candidates;
  factory PaybackSuggestion.fromJson(Map<String, dynamic> j) => PaybackSuggestion(
      paybackId: j['payback_id'] as String, amountCents: (j['amount_cents'] as num).toInt(), from: j['from'] as String?, date: DateTime.parse(j['date'] as String),
      candidates: [for (final c in (j['candidates'] as List? ?? const [])) PaybackCandidate(purchaseId: c['purchase_id'] as String, merchant: (c['merchant'] ?? 'that purchase') as String,
          amountCents: (c['amount_cents'] as num).toInt(), leftCents: (c['left_cents'] as num).toInt(), date: DateTime.parse(c['date'] as String))]);
}

@immutable
class PaybackLink {
  const PaybackLink(this.purchaseId, this.paybackId, this.amountCents);
  final String purchaseId;
  final String paybackId;
  final int amountCents;
}

/// Someone said "I paid" and exactly that amount from them has landed.
@immutable
class LandedSettlement {
  const LandedSettlement(this.settlementId, this.paybackId, this.amountCents, this.from);
  final String settlementId;
  final String paybackId;
  final int amountCents;
  final String from;
}

/// A credit that looks like someone paying down what they owe me: the same or part of it.
@immutable
class BalanceMatch {
  const BalanceMatch({required this.paybackId, required this.amountCents, required this.groupId, required this.groupName, required this.memberId, required this.name, required this.leftCents, required this.date});
  final String paybackId;
  final int amountCents;
  final String groupId;
  final String groupName;
  final String memberId;
  final String name;
  final int leftCents; // still owed after this
  final DateTime date;
  String get first => name.trim().split(' ').first;
}

/// One call feeds all three questions. Offline, or in demo mode, there are simply none to show.
final _suggestionsProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  ref.watch(ledgerRevisionProvider);
  if (ref.watch(settingsProvider.select((s) => s.demoMode)) || ref.watch(remoteProvider) == null) return const {};
  try {
    return await ref.read(apiProvider).get('/paybacks/suggestions');
  } catch (_) {
    return const {};
  }
});

final landedSettlementsProvider = FutureProvider<List<LandedSettlement>>((ref) async {
  final j = await ref.watch(_suggestionsProvider.future);
  return [for (final s in (j['settlements'] as List? ?? const [])) LandedSettlement(s['settlement_id'] as String, s['payback_id'] as String, (s['amount_cents'] as num).toInt(), (s['from'] ?? 'Someone') as String)];
});

final balanceMatchesProvider = FutureProvider<List<BalanceMatch>>((ref) async {
  final j = await ref.watch(_suggestionsProvider.future);
  return [for (final b in (j['balances'] as List? ?? const [])) BalanceMatch(paybackId: b['payback_id'] as String, amountCents: (b['amount_cents'] as num).toInt(), groupId: b['group_id'] as String, groupName: b['group_name'] as String,
      memberId: b['member_id'] as String, name: b['name'] as String, leftCents: (b['left_cents'] as num).toInt(), date: DateTime.parse(b['date'] as String))];
});

/// Suggestions come from the server, which sees the whole ledger.
final paybackSuggestionsProvider = FutureProvider<List<PaybackSuggestion>>((ref) async {
  final j = await ref.watch(_suggestionsProvider.future);
  return [for (final s in (j['suggestions'] as List? ?? const [])) PaybackSuggestion.fromJson((s as Map).cast<String, dynamic>())];
});

/// Paybacks already linked to a purchase, or the purchase a payback is linked to.
final paybackLinksProvider = FutureProvider.family<List<PaybackLink>, String>((ref, txnId) async {
  ref.watch(ledgerRevisionProvider);
  final r = ref.watch(remoteProvider);
  if (r == null || ref.watch(settingsProvider.select((s) => s.demoMode))) return const [];
  final rows = await r.db.from('txn_paybacks').select('purchase_id,payback_id,amount_cents').or('purchase_id.eq.$txnId,payback_id.eq.$txnId');
  return [for (final x in rows) PaybackLink(x['purchase_id'] as String, x['payback_id'] as String, (x['amount_cents'] as num).toInt())];
});

class PaybackActions {
  PaybackActions(this.ref);
  final Ref ref;
  Future<void> _after() async {
    await ref.read(ledgerProvider.notifier).refresh();
    ref.invalidate(_suggestionsProvider);
  }
  Future<void> link(String purchaseId, String paybackId) async {
    await ref.read(apiProvider).post('/paybacks/link', {'purchase_id': purchaseId, 'payback_id': paybackId});
    await _after();
  }
  Future<void> received(LandedSettlement s) async {
    await ref.read(apiProvider).post('/paybacks/received', {'settlement_id': s.settlementId, 'payback_id': s.paybackId});
    await _after();
  }
  Future<void> settleBalance(BalanceMatch b) async {
    await ref.read(apiProvider).post('/paybacks/settle', {'payback_id': b.paybackId, 'group_id': b.groupId, 'member_id': b.memberId});
    await ref.read(tallyProvider.notifier).refresh();
    await _after();
  }
  Future<void> unlink(String paybackId) async {
    await ref.read(apiProvider).post('/paybacks/unlink', {'payback_id': paybackId});
    await _after();
  }
  Future<void> dismiss(String paybackId) async {
    await ref.read(apiProvider).post('/paybacks/dismiss', {'payback_id': paybackId});
    await _after();
  }
}

final paybackActionsProvider = Provider<PaybackActions>(PaybackActions.new);
