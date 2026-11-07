import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' hide Category;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import '../services/privacy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../domain/flows.dart';
import '../domain/merchant_name.dart';
import '../domain/models.dart';
import '../services/session.dart';
import 'ledger.dart';
import 'ledger_codec.dart';
import 'remote.dart';
import 'settings.dart';
import '../domain/dates.dart';

const activityPageSize = 40;

/// Account type chips. 'Loans' covers the student loan.
const accountTypeChips = <(String, String)>[('checking', 'Checking'), ('savings', 'Savings'), ('credit', 'Credit cards'), ('loan', 'Loans')];

/// What Activity shows: ONE continuous list across every month, optionally filtered. Server side this maps 1:1 onto the arguments of
/// tick_activity_page / tick_flows. [upTo] ("Jump to month") starts the list at the end of that New York month instead of today.
@immutable
class ActivityQuery {
  const ActivityQuery({this.since, this.until, this.upTo, this.types = const {}, this.accounts = const {}, this.categories = const {}, this.query = '', this.business = false, this.review = false});
  final DateTime? upTo;
  /// An exact range (UTC instants, [since, until)), from Ask Tick's "See the transactions".
  final DateTime? since;
  final DateTime? until;
  final Set<String> types;
  final Set<String> accounts;
  final Set<String> categories;
  final String query;
  final bool business;
  final bool review;

  bool get anyFilter => filterCount > 0;
  /// How many filters are active (the badge on the filter button). Search counts as one.
  int get filterCount => (types.isNotEmpty ? 1 : 0) + (accounts.isNotEmpty ? 1 : 0) + (categories.isNotEmpty ? 1 : 0) + (query.trim().isNotEmpty ? 1 : 0) + (business ? 1 : 0) + (review ? 1 : 0) + (since != null ? 1 : 0);
  DateTime? get to => upTo == null ? until : etToUtc(DateTime(upTo!.year, upTo!.month + 1, 1));

  ActivityQuery copyWith({DateTime? upTo, bool clearUpTo = false, Set<String>? types, Set<String>? accounts, Set<String>? categories, String? query, bool? business, bool? review}) =>
      ActivityQuery(since: since, until: until, upTo: clearUpTo ? null : (upTo ?? this.upTo), types: types ?? this.types, accounts: accounts ?? this.accounts, categories: categories ?? this.categories,
          query: query ?? this.query, business: business ?? this.business, review: review ?? this.review);
  ActivityQuery clearFilters() => ActivityQuery(upTo: upTo);
  /// The same filters with no month limit (used for month totals, which apply their own bounds).
  ActivityQuery get filtersOnly => ActivityQuery(since: since, until: until, types: types, accounts: accounts, categories: categories, query: query, business: business, review: review);

  /// Arguments for the server. [from]/[to] override the list bounds (month totals, day totals).
  Map<String, dynamic> rpcArgs({DateTime? from, DateTime? to, bool useBounds = true}) => {
        'p_from': (from ?? since)?.toUtc().toIso8601String(),
        'p_to': (to ?? (useBounds ? this.to : null))?.toUtc().toIso8601String(),
        'p_types': types.isEmpty ? null : types.toList(),
        'p_accounts': accounts.isEmpty ? null : accounts.toList(),
        'p_categories': categories.isEmpty ? null : categories.toList(),
        'p_query': query.trim().isEmpty ? null : query.trim(),
        'p_business': business,
        'p_review': review,
      };

  /// Local mirror of the server's tick_filtered (demo mode and the guest ledger).
  bool matches(Txn t, LedgerState l, {DateTime? from, DateTime? until}) {
    final at = t.occurredAt.toUtc();
    final hi = until ?? to;
    final lo = from ?? since;
    if (lo != null && at.isBefore(lo)) return false;
    if (hi != null && !at.isBefore(hi)) return false;
    if (types.isNotEmpty && !types.contains(l.account(t.accountId)?.type ?? 'checking')) return false;
    if (accounts.isNotEmpty && !accounts.contains(t.accountId)) return false;
    if (categories.isNotEmpty && !categories.contains(t.categoryId)) return false;
    if (business && !t.isBusiness) return false;
    if (review && !t.needsReview) return false;
    final q = query.trim().toLowerCase();
    if (q.isNotEmpty) {
      final hay = '${t.merchant} ${t.note ?? ''}'.toLowerCase();
      if (!hay.contains(q) && !(l.category(t.categoryId)?.name.toLowerCase().contains(q) ?? false)) return false;
    }
    return true;
  }

  @override
  bool operator ==(Object other) =>
      other is ActivityQuery && other.upTo == upTo && other.since == since && other.until == until && setEquals(other.types, types) && setEquals(other.accounts, accounts) && setEquals(other.categories, categories) &&
      other.query == query && other.business == business && other.review == review;
  @override
  int get hashCode => Object.hash(upTo, since, until, Object.hashAllUnordered(types), Object.hashAllUnordered(accounts), Object.hashAllUnordered(categories), query, business, review);
}

DateTime monthOf(DateTime d) => DateTime(d.year, d.month, 1);

class PageData {
  const PageData(this.rows, this.dayTotals);
  final List<Txn> rows;
  final Map<DateTime, int> dayTotals; // net per New York day, over the WHOLE filter (not just these rows)
}

class MonthSummary {
  const MonthSummary(this.month, this.totals);
  final DateTime month;
  final Totals totals;
}

class MerchantTotal {
  const MerchantTotal(this.merchant, this.cents, this.count);
  final String merchant;
  final int cents;
  final int count;
}

abstract class ActivitySource {
  Future<List<MerchantTotal>> topMerchants(DateTime from, DateTime to, {int limit = 8});
  Future<PageData> page(ActivityQuery q, {DateTime? beforeAt, String? beforeId, int limit = activityPageSize});
  Future<Totals> totals(ActivityQuery q, {DateTime? from, DateTime? to});
  Future<List<MonthSummary>> months(ActivityQuery q);
}

/// Live: everything is computed by Postgres (RLS applies; SECURITY INVOKER functions).
class RemoteActivitySource implements ActivitySource {
  RemoteActivitySource(this.db);
  final SupabaseClient db;
  static const _timeout = Duration(seconds: 15);

  Map<DateTime, int> _days(Object? o) => {for (final e in ((o as Map?) ?? const {}).entries) DateTime.parse(e.key as String): (e.value as num).toInt()};

  @override
  Future<PageData> page(ActivityQuery q, {DateTime? beforeAt, String? beforeId, int limit = activityPageSize}) async {
    final j = await db.rpc('tick_activity_page', params: {...q.rpcArgs(), 'p_before_at': beforeAt?.toUtc().toIso8601String(), 'p_before_id': beforeId, 'p_limit': limit}).timeout(_timeout);
    final m = (j as Map).cast<String, dynamic>();
    final rows = <Txn>[];
    for (final r in (m['rows'] as List? ?? const [])) {
      try { rows.add(Txn.fromJson((r as Map).cast<String, dynamic>())); } catch (_) {/* skip a bad row */}
    }
    return PageData(rows, _days(m['day_totals']));
  }

  @override
  Future<Totals> totals(ActivityQuery q, {DateTime? from, DateTime? to}) async {
    final args = q.rpcArgs(from: from, to: to, useBounds: from == null && to == null);
    final j = await db.rpc('tick_flows', params: args).timeout(_timeout);
    return Totals.fromJson((j as Map).cast<String, dynamic>());
  }

  @override
  Future<List<MerchantTotal>> topMerchants(DateTime from, DateTime to, {int limit = 8}) async {
    final j = await db.rpc('tick_top_merchants', params: {'p_from': from.toUtc().toIso8601String(), 'p_to': to.toUtc().toIso8601String(), 'p_limit': limit}).timeout(_timeout);
    return [for (final m in (j as List)) MerchantTotal(m['merchant'] as String, (m['cents'] as num).toInt(), (m['count'] as num).toInt())];
  }

  @override
  Future<List<MonthSummary>> months(ActivityQuery q) async {
    final j = await db.rpc('tick_months', params: {'p_types': q.types.isEmpty ? null : q.types.toList(), 'p_accounts': q.accounts.isEmpty ? null : q.accounts.toList()}).timeout(_timeout);
    return [for (final m in (j as List)) MonthSummary(DateTime.parse((m as Map)['month'] as String), Totals.fromJson(m.cast<String, dynamic>()))];
  }
}

/// Demo mode and the signed-out guest ledger: the same rules over the rows held on the phone.
class LocalActivitySource implements ActivitySource {
  LocalActivitySource(this.l, {this.includeFriends = false});
  final bool includeFriends;
  final LedgerState l;
  Map<String, Category> get _cats => {for (final c in l.categories) c.id: c};
  Map<String, Account> get _accts => {for (final a in l.accounts) a.id: a};

  List<Txn> _filtered(ActivityQuery q) => l.txns.where((t) => q.matches(t, l)).toList()
    ..sort((a, b) { final c = b.occurredAt.compareTo(a.occurredAt); return c != 0 ? c : b.id.compareTo(a.id); });

  @override
  Future<PageData> page(ActivityQuery q, {DateTime? beforeAt, String? beforeId, int limit = activityPageSize}) async {
    final all = _filtered(q);
    var start = 0;
    if (beforeAt != null) {
      start = all.indexWhere((t) => t.occurredAt.isBefore(beforeAt) || (t.occurredAt == beforeAt && t.id.compareTo(beforeId ?? '') < 0));
      if (start < 0) start = all.length;
    }
    final rows = all.skip(start).take(limit).toList();
    final days = {for (final t in rows) etDay(t.occurredAt)};
    final totals = <DateTime, int>{};
    for (final d in days) {
      final t = computeTotals(all.where((t) => etDay(t.occurredAt) == d), cats: _cats, accounts: _accts, includeFriends: includeFriends);
      totals[d] = t.netCents;
    }
    return PageData(rows, totals);
  }

  @override
  Future<Totals> totals(ActivityQuery q, {DateTime? from, DateTime? to}) async {
    final rows = l.txns.where((t) => q.matches(t, l, from: from, until: to ?? (from == null ? q.to : null)));
    return computeTotals(rows, cats: _cats, accounts: _accts, includeFriends: includeFriends);
  }

  @override
  Future<List<MerchantTotal>> topMerchants(DateTime from, DateTime to, {int limit = 8}) async {
    final by = <String, (int, int)>{};
    for (final t in l.txns) {
      final at = t.occurredAt.toUtc();
      if (at.isBefore(from) || !at.isBefore(to)) continue;
      final o = outOf(t, cats: _cats, accounts: _accts, includeFriends: includeFriends);
      if (o == 0) continue;
      final k = cleanMerchant(t.merchant);
      final cur = by[k] ?? (0, 0);
      by[k] = (cur.$1 + o, cur.$2 + 1);
    }
    final out = [for (final e in by.entries) if (e.value.$1 > 0) MerchantTotal(e.key, e.value.$1, e.value.$2)]..sort((a, b) => b.cents.compareTo(a.cents));
    return out.take(limit).toList();
  }

  @override
  Future<List<MonthSummary>> months(ActivityQuery q) async {
    final base = ActivityQuery(types: q.types, accounts: q.accounts);
    final ms = {for (final t in l.txns.where((t) => base.matches(t, l))) monthOf(etDay(t.occurredAt))}.toList()..sort((a, b) => b.compareTo(a));
    return [for (final m in ms) MonthSummary(m, await totals(base, from: etToUtc(m), to: etToUtc(DateTime(m.year, m.month + 1, 1))))];
  }
}

final activitySourceProvider = Provider<ActivitySource>((ref) {
  final demo = ref.watch(settingsProvider.select((s) => s.demoMode));
  final remote = ref.watch(remoteProvider);
  if (!demo && remote != null) return RemoteActivitySource(remote.db);
  return LocalActivitySource(ref.watch(ledgerProvider), includeFriends: ref.watch(settingsProvider.select((s) => s.includeFriends)));
});

class ActivityState {
  const ActivityState({required this.query, this.rows = const [], this.dayTotals = const {}, this.totals, this.months = const [], this.loading = true,
      this.loadingMore = false, this.hasMore = false, this.error = false, this.offline = false});
  final ActivityQuery query;
  final List<Txn> rows;
  final Map<DateTime, int> dayTotals;
  final Totals? totals;
  final List<MonthSummary> months;
  final bool loading; // first page
  final bool loadingMore;
  final bool hasMore;
  final bool error; // the first page failed and there is nothing to show
  final bool offline; // showing the cached first page
  ActivityState copyWith({List<Txn>? rows, Map<DateTime, int>? dayTotals, Totals? totals, List<MonthSummary>? months, bool? loading, bool? loadingMore,
          bool? hasMore, bool? error, bool? offline}) =>
      ActivityState(query: query, rows: rows ?? this.rows, dayTotals: dayTotals ?? this.dayTotals, totals: totals ?? this.totals, months: months ?? this.months,
          loading: loading ?? this.loading, loadingMore: loadingMore ?? this.loadingMore, hasMore: hasMore ?? this.hasMore, error: error ?? this.error,
          offline: offline ?? this.offline);
}

/// Server-side keyset pagination (occurred_at desc, id desc), 40 rows a page, totals and month strip from SQL.
class ActivityNotifier extends Notifier<ActivityState> {
  int _gen = 0;

  @override
  ActivityState build() {
    ref.watch(activitySourceProvider);
    // Live changes (Realtime -> ledger refresh) refresh the first page and the totals without throwing away what is scrolled.
    ref.listen(ledgerRevisionProvider, (_, _) => _reloadKeepingScroll());
    final q = stateOrNull?.query ?? const ActivityQuery();
    Future.microtask(() => _load(q));
    return ActivityState(query: q);
  }

  ActivitySource get _src => ref.read(activitySourceProvider);

  Future<void> setQuery(ActivityQuery q) async {
    if (q == state.query) return;
    state = ActivityState(query: q, months: state.months);
    await _load(q);
  }

  Future<void> refresh() async {
    await ref.read(ledgerProvider.notifier).refresh();
    await _load(state.query, keepRows: false);
  }

  Future<void> _reloadKeepingScroll() async {
    if (state.rows.length > activityPageSize) {
      await _loadTotals(state.query, _gen);
      return;
    }
    await _load(state.query, keepRows: true);
  }

  Future<void> _load(ActivityQuery q, {bool keepRows = false}) async {
    final gen = ++_gen;
    if (!keepRows) state = state.copyWith(loading: state.rows.isEmpty, error: false);
    unawaited(_loadTotals(q, gen));
    try {
      final p = await _src.page(q);
      if (gen != _gen) return;
      state = state.copyWith(rows: p.rows, dayTotals: p.dayTotals, loading: false, hasMore: p.rows.length >= activityPageSize, error: false, offline: false);
      if (_isDefault(q)) unawaited(ActivityCache.write(p, ref.read(userIdProvider)));
    } catch (_) {
      if (gen != _gen) return;
      final cached = _isDefault(q) ? await ActivityCache.read(ref.read(userIdProvider)) : null;
      if (gen != _gen) return;
      if (cached != null && state.rows.isEmpty) {
        state = state.copyWith(rows: cached.rows, dayTotals: cached.dayTotals, loading: false, hasMore: false, offline: true);
      } else {
        state = state.copyWith(loading: false, error: state.rows.isEmpty, offline: state.rows.isNotEmpty);
      }
    }
  }

  Future<void> _loadTotals(ActivityQuery q, int gen) async {
    try {
      final r = await Future.wait([_src.totals(q), _src.months(q)]);
      if (gen != _gen) return;
      state = state.copyWith(totals: r[0] as Totals, months: r[1] as List<MonthSummary>);
    } catch (_) {/* the strip keeps its last numbers */}
  }

  Future<void> loadMore() async {
    if (!state.hasMore || state.loadingMore || state.loading || state.rows.isEmpty) return;
    final gen = _gen;
    final last = state.rows.last;
    state = state.copyWith(loadingMore: true);
    try {
      final p = await _src.page(state.query, beforeAt: last.occurredAt, beforeId: last.id);
      if (gen != _gen) return;
      final seen = {for (final t in state.rows) t.id};
      state = state.copyWith(rows: [...state.rows, ...p.rows.where((t) => !seen.contains(t.id))], dayTotals: {...state.dayTotals, ...p.dayTotals},
          hasMore: p.rows.length >= activityPageSize, loadingMore: false);
    } catch (_) {
      if (gen == _gen) state = state.copyWith(loadingMore: false, offline: true);
    }
  }

  bool _isDefault(ActivityQuery q) => !q.anyFilter && q.upTo == null;
}

final activityProvider = NotifierProvider<ActivityNotifier, ActivityState>(ActivityNotifier.new);

/// A month's totals (Flows, Budgets) and the same number of days of the month before, both from SQL in live mode.
/// [now] picks the month and how many days of the previous month to compare against.
final monthFlowsProvider = FutureProvider.family<MonthFlows, DateTime>((ref, now) async {
  ref.watch(ledgerRevisionProvider);
  final src = ref.watch(activitySourceProvider);
  final m = monthOf(now);
  final prevStart = DateTime(m.year, m.month - 1, 1);
  final r = await Future.wait([
    src.totals(const ActivityQuery(), from: etToUtc(m), to: etToUtc(DateTime(m.year, m.month + 1, 1))),
    src.totals(const ActivityQuery(), from: etToUtc(prevStart), to: etToUtc(addDays(prevStart, now.day))),
  ]);
  return MonthFlows.from(r[0], r[1].outCents);
});

/// Key for one month's totals under the active filters (the sticky month header).
@immutable
class MonthKey {
  const MonthKey(this.filters, this.month);
  final ActivityQuery filters;
  final DateTime month;
  @override
  bool operator ==(Object other) => other is MonthKey && other.month == month && other.filters == filters;
  @override
  int get hashCode => Object.hash(filters, month);
}

/// In, out and net for one month under the active filters; SQL in live mode. Re-queried when the ledger changes.
final monthTotalsProvider = FutureProvider.family<Totals, MonthKey>((ref, k) async {
  ref.watch(ledgerRevisionProvider);
  return ref.watch(activitySourceProvider).totals(k.filters.filtersOnly, from: etToUtc(k.month), to: etToUtc(DateTime(k.month.year, k.month.month + 1, 1)));
});

/// First page of the default view (this month, no filters), so Activity opens offline.
class ActivityCache {
  static Future<File> _file() async => File('${(await getApplicationSupportDirectory()).path}/activity_first.json');

  static Future<void> write(PageData p, String? userId) async {
    try {
      final f = await _file();
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode({'v': 1, 'u': userId, 'rows': [for (final t in p.rows) encodeTxn(t)],
          'days': {for (final e in p.dayTotals.entries) e.key.toIso8601String().substring(0, 10): e.value}}), flush: true);
      await tmp.rename(f.path);
      await Privacy.protect([f.path]);                   // file protection complete + no backups
    } catch (_) {}
  }

  static Future<PageData?> read(String? userId) async {
    try {
      final f = await _file();
      if (!await f.exists()) return null;
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      if (j['v'] != 1 || j['u'] != userId) return null;
      return PageData([for (final r in (j['rows'] as List)) decodeTxn((r as Map).cast<String, dynamic>())],
          {for (final e in (j['days'] as Map).entries) DateTime.parse(e.key as String): (e.value as num).toInt()});
    } catch (_) {
      return null;
    }
  }

  static Future<void> clear() async {
    try { final f = await _file(); if (await f.exists()) await f.delete(); } catch (_) {}
  }
}
