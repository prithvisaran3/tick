import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../domain/models.dart';
import 'env.dart';
import 'ledger.dart';

/// Supabase-backed persistence. Null when the app is built without Supabase config (tests, gallery).
class Remote {
  Remote(this.db);
  final SupabaseClient db;

  Future<LedgerState> loadAll() async {
    final r = await Future.wait([
      db.from('categories').select().order('sort'),
      db.from('accounts').select(),
      db.from('transactions').select().order('occurred_at', ascending: false).limit(1500),
      db.from('recurring').select().eq('status', 'active'),
      db.from('expected').select().eq('status', 'expected'),
      db.from('goals').select(),
      db.from('connections').select('id,institution,status'),
    ]);
    return LedgerState(
      categories: [for (final j in r[0]) Category.fromJson(j)],
      accounts: [for (final j in r[1]) Account.fromJson(j)],
      txns: [for (final j in r[2]) Txn.fromJson(j)],
      recurring: [for (final j in r[3]) _rec(j)],
      expected: [for (final j in r[4]) _exp(j)],
      goals: [for (final j in r[5]) Goal(id: j['id'] as String, name: j['name'] as String, targetCents: (j['target_cents'] as num).toInt(), savedCents: (j['saved_cents'] as num).toInt(), perPaydayCents: (j['per_payday_cents'] as num).toInt())],
      linksUsed: (r[6] as List).length,
      connections: [for (final j in r[6]) Connection.fromJson(j)].where((c) => c.status != 'removed').toList(),
    );
  }

  Recurring _rec(Map<String, dynamic> j) => Recurring(
      id: j['id'] as String, merchant: j['merchant'] as String, cadence: Cadence.values.firstWhere((c) => c.name == j['cadence']),
      expectedCents: (j['expected_cents'] as num).toInt(), nextDate: DateTime.parse(j['next_date'] as String), categoryId: j['category_id'] as String?,
      priceHistory: [for (final p in (j['price_history'] as List? ?? const [])) ((p as Map)['cents'] as num).toInt()]);
  Expected _exp(Map<String, dynamic> j) => Expected(
      id: j['id'] as String, kind: ExpectedKind.values.firstWhere((k) => k.name == j['kind']), label: j['label'] as String,
      amountCents: (j['amount_cents'] as num).toInt(), date: DateTime.parse(j['expected_date'] as String));

  bool _isUuid(String? s) => s != null && RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-').hasMatch(s);

  Future<Txn> insertTxn(Txn t) async {
    final row = await db.from('transactions').insert({
      'amount_cents': t.amountCents, 'occurred_at': t.occurredAt.toUtc().toIso8601String(), 'merchant_raw': t.merchant, 'merchant_clean': t.merchant,
      'category_id': _isUuid(t.categoryId) ? t.categoryId : null, 'account_id': _isUuid(t.accountId) ? t.accountId : null, 'tags': t.tags, 'note': t.note,
      'confidence': t.confidence, 'needs_review': t.needsReview, 'sources': [{'source': t.source, 'at': DateTime.now().toUtc().toIso8601String()}],
    }).select().single();
    return Txn.fromJson(row);
  }

  Future<void> updateTxn(Txn t) => db.from('transactions').update({
        'category_id': _isUuid(t.categoryId) ? t.categoryId : null, 'tags': t.tags, 'needs_review': t.needsReview, 'confidence': t.confidence, 'note': t.note, 'merchant_clean': t.merchant,
      }).eq('id', t.id);

  /// Learned rule: the next purchase at this merchant gets this category (rules win over AI).
  Future<void> learnRule(String merchant, String categoryId) async {
    if (!_isUuid(categoryId)) return;
    await db.from('rules').upsert({'pattern': merchant.toLowerCase(), 'category_id': categoryId, 'source': 'learned'}, onConflict: 'user_id,pattern');
  }

  Future<void> markUserEdited(String id, List<String> fields) => db.from('transactions').update({'user_edited': fields}).eq('id', id);

  Future<void> insertRecurring(Recurring r) => db.from('recurring').insert({
        'merchant': r.merchant, 'cadence': r.cadence.name, 'expected_cents': r.expectedCents, 'next_date': r.nextDate.toIso8601String().substring(0, 10),
        'category_id': _isUuid(r.categoryId) ? r.categoryId : null, 'is_manual': true,
        'price_history': [{'date': DateTime.now().toIso8601String().substring(0, 10), 'cents': r.expectedCents}]});
}

final remoteProvider = Provider<Remote?>((ref) {
  if (!Env.hasSupabase) return null;
  try {
    final c = Supabase.instance.client;
    return c.auth.currentSession == null ? null : Remote(c);
  } catch (_) {
    return null;
  }
});
