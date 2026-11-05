import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../domain/models.dart';
import '../services/session.dart';
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
      db.from('transactions').select().gte('occurred_at', DateTime.now().subtract(const Duration(days: 130)).toUtc().toIso8601String()).order('occurred_at', ascending: false).limit(1200),
      db.from('recurring').select().eq('status', 'active'),
      db.from('expected').select().eq('status', 'expected'),
      db.from('goals').select(),
      db.from('connections').select('id,institution,status,sync_state,last_synced_at,sync_started_at,created_at,last_error,historical_complete,last_added'),
      db.from('budgets').select(),
      db.from('rules').select(),
      // Lifetime bank links = distinct Plaid Items ever created, removed ones included (append-only table).
      db.from('plaid_items').select('item_id'),
    ]);
    return LedgerState(
      // Each row is parsed on its own: one malformed row is skipped, it can never fail the whole refresh.
      categories: _each(r[0], Category.fromJson),
      accounts: _each(r[1], Account.fromJson),
      txns: _each(r[2], Txn.fromJson),
      recurring: _each(r[3], _rec),
      expected: _each(r[4], _exp),
      goals: [for (final j in r[5]) Goal(id: j['id'] as String, name: j['name'] as String, targetCents: (j['target_cents'] as num).toInt(), savedCents: (j['saved_cents'] as num).toInt(), perPaydayCents: (j['per_payday_cents'] as num).toInt())],
      linksUsed: (r[9] as List).length > (r[6] as List).length ? (r[9] as List).length : (r[6] as List).length,
      connections: [for (final j in r[6]) Connection.fromJson(j)].where((c) => c.status != 'removed').toList(),
      budgets: [for (final j in r[7]) Budget(id: j['id'] as String, categoryId: j['category_id'] as String, capCents: (j['monthly_cap_cents'] as num).toInt())],
      rules: [for (final j in r[8]) if (j['category_id'] != null) LearnedRule(id: j['id'] as String, pattern: j['pattern'] as String, categoryId: j['category_id'] as String)],
    );
  }

  List<T> _each<T>(List<dynamic> rows, T Function(Map<String, dynamic>) f) {
    final out = <T>[];
    for (final j in rows) {
      try { out.add(f(j as Map<String, dynamic>)); } catch (_) {/* skip bad row */}
    }
    return out;
  }

  Recurring _rec(Map<String, dynamic> j) => Recurring(
      id: j['id'] as String, merchant: j['merchant'] as String, cadence: Cadence.values.firstWhere((c) => c.name == j['cadence'], orElse: () => Cadence.monthly),
      expectedCents: (j['expected_cents'] as num).toInt(), nextDate: DateTime.parse(j['next_date'] as String), categoryId: j['category_id'] as String?,
      priceHistory: [for (final p in (j['price_history'] as List? ?? const [])) ((p as Map)['cents'] as num).toInt()]);
  Expected _exp(Map<String, dynamic> j) => Expected(
      id: j['id'] as String, kind: ExpectedKind.values.firstWhere((k) => k.name == j['kind'], orElse: () => ExpectedKind.refund), label: j['label'] as String,
      amountCents: (j['amount_cents'] as num).toInt(), date: DateTime.parse(j['expected_date'] as String));

  /// Expected money that landed in the last two days.
  Future<List<Expected>> recentLanded() async {
    final since = DateTime.now().subtract(const Duration(days: 2)).toIso8601String().substring(0, 10);
    final rows = await db.from('expected').select().eq('status', 'landed').gte('expected_date', since);
    return [for (final j in rows) _exp(j)];
  }

  RealtimeChannel listen(void Function() onChange) {
    final ch = db.channel('tick-live');
    for (final t in ['transactions', 'expected', 'connections']) {
      ch.onPostgresChanges(event: PostgresChangeEvent.all, schema: 'public', table: t, callback: (_) => onChange());
    }
    return ch..subscribe();
  }

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

  Future<Budget> upsertBudget(String categoryId, int cap) async {
    final j = await db.from('budgets').upsert({'category_id': categoryId, 'monthly_cap_cents': cap}, onConflict: 'user_id,category_id').select().single();
    return Budget(id: j['id'] as String, categoryId: categoryId, capCents: cap);
  }

  Future<void> deleteBudget(String id) => db.from('budgets').delete().eq('id', id);

  Future<Goal> upsertGoal(Goal g) async {
    final row = {'name': g.name, 'target_cents': g.targetCents, 'saved_cents': g.savedCents, 'per_payday_cents': g.perPaydayCents};
    final j = _isUuid(g.id) ? await db.from('goals').update(row).eq('id', g.id).select().single() : await db.from('goals').insert(row).select().single();
    return Goal(id: j['id'] as String, name: g.name, targetCents: g.targetCents, savedCents: g.savedCents, perPaydayCents: g.perPaydayCents);
  }

  Future<void> deleteGoal(String id) => db.from('goals').delete().eq('id', id);

  Future<Account> upsertManualAccount(Account a, int cents) async {
    final row = {'name': a.name, 'type': 'checking', 'balance_cents': cents, 'available_cents': cents, 'is_manual': true, 'include_in_safe': true};
    final j = _isUuid(a.id) ? await db.from('accounts').update(row).eq('id', a.id).select().single() : await db.from('accounts').insert(row).select().single();
    return Account.fromJson(j);
  }

  Future<Category> insertCategory(String name, String colorKey) async {
    final j = await db.from('categories').insert({'name': name, 'color_key': colorKey, 'icon': 'card', 'kind': 'spend', 'sort': 99}).select().single();
    return Category.fromJson(j);
  }

  Future<void> renameCategory(String id, String name) => db.from('categories').update({'name': name}).eq('id', id);
  Future<void> deleteRule(String id) => db.from('rules').delete().eq('id', id);
  Future<void> recordPayday(int moved) => db.from('paydays').upsert({'day': DateTime.now().toIso8601String().substring(0, 10), 'moved_cents': moved}, onConflict: 'user_id,day');

  /// The payday rule saved by an earlier install, if any (so a reinstall does not ask again).
  Future<PaydayRule?> loadPaydayRule() async {
    final j = await db.from('settings').select('payday_rule').maybeSingle();
    final r = j?['payday_rule'];
    if (r is! Map) return null;
    try {
      return PaydayRule(
        frequency: PayFrequency.values.firstWhere((f) => f.name == r['frequency'], orElse: () => PayFrequency.biweekly),
        anchor: DateTime.parse(r['next_date'] as String), amountCents: (r['amount_cents'] as num).toInt());
    } catch (_) {
      return null;
    }
  }

  Future<void> savePaydayRule(Map<String, dynamic> rule) => db.from('settings').update({'payday_rule': rule}).eq('user_id', db.auth.currentUser!.id);

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

/// Rebuilds only when the signed-in user changes (sign-in, sign-out), never on hourly token refresh.
final remoteProvider = Provider<Remote?>((ref) {
  if (!Env.hasSupabase) return null;
  final uid = ref.watch(userIdProvider);
  if (uid == null) return null;
  try {
    return Remote(Supabase.instance.client);
  } catch (_) {
    return null;
  }
});
