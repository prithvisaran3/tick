import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/api.dart';
import 'ledger.dart';
import 'remote.dart';
import 'settings.dart';

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

final landedSettlementsProvider = FutureProvider<List<LandedSettlement>>((ref) async {
  ref.watch(ledgerRevisionProvider);
  if (ref.watch(settingsProvider.select((s) => s.demoMode)) || ref.watch(remoteProvider) == null) return const [];
  try {
    final j = await ref.read(apiProvider).get('/paybacks/suggestions');
    return [for (final s in (j['settlements'] as List? ?? const [])) LandedSettlement(s['settlement_id'] as String, s['payback_id'] as String, (s['amount_cents'] as num).toInt(), (s['from'] ?? 'Someone') as String)];
  } catch (_) {
    return const [];
  }
});

/// Suggestions come from the server, which sees the whole ledger. Offline, or in demo mode, there are simply none to show.
final paybackSuggestionsProvider = FutureProvider<List<PaybackSuggestion>>((ref) async {
  ref.watch(ledgerRevisionProvider);
  if (ref.watch(settingsProvider.select((s) => s.demoMode)) || ref.watch(remoteProvider) == null) return const [];
  try {
    final j = await ref.read(apiProvider).get('/paybacks/suggestions');
    return [for (final s in (j['suggestions'] as List? ?? const [])) PaybackSuggestion.fromJson((s as Map).cast<String, dynamic>())];
  } catch (_) {
    return const [];
  }
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
    ref.invalidate(paybackSuggestionsProvider);
  }
  Future<void> link(String purchaseId, String paybackId) async {
    await ref.read(apiProvider).post('/paybacks/link', {'purchase_id': purchaseId, 'payback_id': paybackId});
    await _after();
  }
  Future<void> received(LandedSettlement s) async {
    await ref.read(apiProvider).post('/paybacks/received', {'settlement_id': s.settlementId, 'payback_id': s.paybackId});
    ref.invalidate(landedSettlementsProvider);
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
