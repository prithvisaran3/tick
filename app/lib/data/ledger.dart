import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/models.dart';
import '../domain/natural_input.dart';
import '../domain/payday.dart';
import '../domain/safe_to_spend.dart';
import 'categorizer.dart';
import 'demo_seed.dart';
import '../services/session.dart';
import 'activity.dart';
import 'ledger_cache.dart';
import 'remote.dart';
import 'settings.dart';

final clockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Bumped after every successful server refresh, so server-computed views (Activity pages, totals) re-query.
class LedgerRevision extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}
final ledgerRevisionProvider = NotifierProvider<LedgerRevision, int>(LedgerRevision.new);

class LedgerState {
  const LedgerState({this.categories = const [], this.accounts = const [], this.txns = const [], this.recurring = const [], this.expected = const [], this.goals = const [], this.loading = false, this.offline = false, this.linksUsed = 0, this.connections = const [], this.justLanded, this.budgets = const [], this.rules = const []});
  final List<Category> categories;
  final List<Account> accounts;
  final List<Txn> txns;
  final List<Recurring> recurring;
  final List<Expected> expected;
  final List<Goal> goals;
  final bool loading;
  final bool offline;
  final int linksUsed;
  final List<Connection> connections;
  final List<Budget> budgets;
  final List<LearnedRule> rules;
  final Expected? justLanded; // money that just arrived: the Landed moment plays once

  Category? category(String? id) => categories.where((c) => c.id == id).firstOrNull;
  Category? categoryByName(String name) => categories.where((c) => c.name.toLowerCase() == name.toLowerCase()).firstOrNull;
  Account? account(String? id) => accounts.where((a) => a.id == id).firstOrNull;
  List<Txn> get needsReview => txns.where((t) => t.needsReview).toList();

  LedgerState copyWith({List<Category>? categories, List<Account>? accounts, List<Txn>? txns, List<Recurring>? recurring, List<Expected>? expected, List<Goal>? goals, bool? loading, bool? offline, int? linksUsed, List<Connection>? connections, Expected? justLanded, bool clearLanded = false, List<Budget>? budgets, List<LearnedRule>? rules}) => LedgerState(
      categories: categories ?? this.categories, accounts: accounts ?? this.accounts, txns: txns ?? this.txns, recurring: recurring ?? this.recurring,
      expected: expected ?? this.expected, goals: goals ?? this.goals, loading: loading ?? this.loading, offline: offline ?? this.offline, linksUsed: linksUsed ?? this.linksUsed, connections: connections ?? this.connections, justLanded: clearLanded ? null : (justLanded ?? this.justLanded), budgets: budgets ?? this.budgets, rules: rules ?? this.rules);
}

/// Snapshot read from disk before the first frame (see main.dart). userId null = guest data.
class CachedLedger {
  const CachedLedger(this.userId, this.state);
  final String? userId;
  final LedgerState state;
}

final initialLedgerProvider = Provider<CachedLedger?>((ref) => null);

class LedgerNotifier extends Notifier<LedgerState> {
  int _seq = 0;
  bool _refreshing = false;
  bool _refreshQueued = false;
  Timer? _persistTimer;
  Timer? _liveTimer;
  Future<void>? _retrying;

  @override
  LedgerState build() {
    // Only these inputs rebuild the ledger. (Watching all of settings used to wipe local data on every unrelated settings change.)
    final demo = ref.watch(settingsProvider.select((s) => s.demoMode));
    final remote = ref.watch(remoteProvider);
    final uid = ref.watch(userIdProvider);
    final resolving = ref.watch(sessionResolvingProvider);
    final now = ref.read(clockProvider)();
    ref.onDispose(() { _persistTimer?.cancel(); _liveTimer?.cancel(); });

    if (demo) {
      final d = buildDemo(now);
      return LedgerState(categories: d.categories, accounts: d.accounts, txns: d.txns, recurring: d.recurring, expected: d.expected, goals: d.goals, linksUsed: 5, connections: d.connections, budgets: d.budgets);
    }
    final cached = ref.read(initialLedgerProvider);
    final usable = cached != null && (cached.userId == uid || (resolving && cached.userId != null) || (uid == null && cached.userId == null)) ? cached.state : null;
    final base = usable ?? const LedgerState(categories: defaultCategories);

    listenSelf((prev, next) => _schedulePersist(next, uid));

    if (remote != null) {
      Future.microtask(refresh);
      final ch = remote.listen(_liveChanged);
      ref.onDispose(() => ch.unsubscribe());
      return base.copyWith(loading: usable == null);
    }
    if (resolving) return base.copyWith(loading: usable == null);
    return base;
  }

  void _schedulePersist(LedgerState s, String? uid) {
    if (s.loading || ref.read(settingsProvider).demoMode) return;
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 900), () => LedgerCache.write(s, userId: uid));
  }

  /// Realtime pushes can arrive in bursts (a sync inserts hundreds of rows): coalesce into one refresh.
  void _liveChanged() {
    _liveTimer?.cancel();
    _liveTimer = Timer(const Duration(milliseconds: 1500), refresh);
  }

  Future<void> refresh() async {
    final remote = ref.read(remoteProvider);
    if (remote == null || ref.read(settingsProvider).demoMode) return;
    if (_refreshing) { _refreshQueued = true; return; }                  // single flight, never a refresh storm
    _refreshing = true;
    try {
      final loaded = await remote.loadAll();
      // Keep purchases that were saved locally while offline and push them up again.
      final localOnly = state.txns.where((t) => t.id.startsWith('local-')).toList();
      var l = loaded;
      if (localOnly.isNotEmpty) l = loaded.copyWith(txns: [...localOnly, ...loaded.txns]..sort((a, b) => b.occurredAt.compareTo(a.occurredAt)));
      Expected? landed;
      try {
        final prefs = ref.read(sharedPrefsProvider);
        final seen = (prefs?.getStringList('tick.seenLanded') ?? <String>[]).toSet();
        final fresh = (await remote.recentLanded()).where((e) => !seen.contains(e.id)).toList();
        if (fresh.isNotEmpty) {
          landed = fresh.first;
          await prefs?.setStringList('tick.seenLanded', [...seen, ...fresh.map((e) => e.id)].take(50).toList());
        }
      } catch (_) {}
      state = l.copyWith(loading: false, offline: false, justLanded: landed);
      ref.read(ledgerRevisionProvider.notifier).bump();
      if (localOnly.isNotEmpty) _retrying ??= _pushLocal(localOnly).whenComplete(() => _retrying = null);
    } catch (_) {
      state = state.copyWith(loading: false, offline: true);
    } finally {
      _refreshing = false;
      if (_refreshQueued) { _refreshQueued = false; Future.microtask(refresh); }
    }
  }

  /// After signing in on a fresh install: pick up the payday rule saved earlier. Returns true if the person is already set up.
  Future<bool> restoreSetup() async {
    // The auth stream delivers the new session a moment after sign-in returns; wait briefly for the provider to catch up.
    for (var i = 0; i < 25 && ref.read(remoteProvider) == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final remote = ref.read(remoteProvider);
    if (remote == null) return false;
    try {
      final rule = await remote.loadPaydayRule();
      if (rule == null) return false;
      ref.read(settingsProvider.notifier).update((s) => s.copyWith(rule: rule, onboardingDone: true));
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _pushLocal(List<Txn> pending) async {
    final remote = ref.read(remoteProvider);
    if (remote == null) return;
    for (final t in pending) {
      try {
        final saved = await remote.insertTxn(t);
        state = state.copyWith(txns: [for (final x in state.txns) x.id == t.id ? saved : x]);
      } catch (_) {
        return;                                                          // still offline: keep them, try again next refresh
      }
    }
  }

  /// Sign-out and "delete all data": forget everything held on this device.
  Future<void> wipeLocal() async {
    await LedgerCache.clear();
    await ActivityCache.clear();
    state = const LedgerState(categories: defaultCategories);
  }

  void landedShown() => state = state.copyWith(clearLanded: true);

  DateTime get _now => ref.read(clockProvider)();

  /// Adds a transaction (optimistic) and persists it.
  Future<Txn> add({required int amountCents, required String merchant, DateTime? at, String? categoryId, List<String>? tags, String source = 'manual', String? note, String? accountId, double confidence = 1, bool needsReview = false, String? flow}) async {
    final cat = categoryId ?? (amountCents > 0 ? 'cat-income' : categorizeLocal(merchant, rules: _rules()));
    final t = Txn(
      id: 'local-${_now.microsecondsSinceEpoch}-${_seq++}', amountCents: amountCents, occurredAt: at ?? _now, merchant: merchant, categoryId: state.category(cat) != null ? cat : state.categoryByName(_nameOf(cat))?.id ?? cat,
      accountId: accountId ?? state.accounts.where((a) => a.type == 'checking').firstOrNull?.id,
      tags: tags ?? (amountCents < 0 && looksBusiness(merchant) ? const ['business'] : const []), source: source, note: note, confidence: confidence, needsReview: needsReview, flow: flow);
    state = state.copyWith(txns: [t, ...state.txns]..sort((a, b) => b.occurredAt.compareTo(a.occurredAt)));
    final remote = ref.read(remoteProvider);
    if (remote != null && !ref.read(settingsProvider).demoMode) {
      try {
        final saved = await remote.insertTxn(t);
        state = state.copyWith(txns: [for (final x in state.txns) x.id == t.id ? saved : x]);
        return saved;
      } catch (_) {
        state = state.copyWith(offline: true);
      }
    }
    return t;
  }

  String _nameOf(String catId) => defaultCategories.where((c) => c.id == catId).firstOrNull?.name ?? 'Other';
  Map<String, String> _rules() => const {};

  Future<void> patch(String id, Txn Function(Txn) f) async {
    final old = state.txns.where((t) => t.id == id).firstOrNull;
    if (old == null) return;                                         // it was removed by a refresh while the sheet was open
    final n = f(old);
    state = state.copyWith(txns: [for (final t in state.txns) t.id == id ? n : t]);
    final remote = ref.read(remoteProvider);
    if (remote != null && !ref.read(settingsProvider).demoMode && !id.startsWith('local-')) {
      try { await remote.updateTxn(n); } catch (_) { state = state.copyWith(offline: true); }
    }
  }

  Future<void> markLooksRight(String id) => patch(id, (t) => t.copyWith(needsReview: false, confidence: 1.0));
  Future<void> toggleBusiness(String id) => patch(id, (t) => t.copyWith(tags: t.isBusiness ? t.tags.where((x) => x != 'business').toList() : [...t.tags, 'business'], needsReview: false));
  Future<void> recategorize(String id, String categoryId) async {
    final t = state.txns.where((x) => x.id == id).firstOrNull;
    if (t == null) return;
    await patch(id, (t) => t.copyWith(categoryId: categoryId, needsReview: false));
    final remote = ref.read(remoteProvider);
    if (remote != null && !ref.read(settingsProvider).demoMode && !id.startsWith('local-')) {
      try { await remote.learnRule(t.merchant, categoryId); await remote.markUserEdited(id, ['category']); } catch (_) {}
    }
  }

  bool get _live => ref.read(remoteProvider) != null && !ref.read(settingsProvider).demoMode;

  /// Safe to spend needs to know what is in your account. Without a linked bank you type it once (and can change it any time).
  Future<void> setManualBalance(int cents) async {
    final existing = state.accounts.where((a) => a.manual).firstOrNull;
    final local = Account(id: existing?.id ?? 'local-acc-manual', name: 'Checking', type: 'checking', balanceCents: cents, availableCents: cents, manual: true);
    state = state.copyWith(accounts: [for (final a in state.accounts) if (!a.manual) a, local]);
    if (_live) {
      try {
        final saved = await ref.read(remoteProvider)!.upsertManualAccount(local, cents);
        state = state.copyWith(accounts: [for (final a in state.accounts) a.manual ? saved : a]);
      } catch (_) { state = state.copyWith(offline: true); }
    }
  }

  Future<void> saveBudget(String categoryId, int capCents) async {
    final existing = state.budgets.where((b) => b.categoryId == categoryId).firstOrNull;
    final local = Budget(id: existing?.id ?? 'local-b-${_now.microsecondsSinceEpoch}', categoryId: categoryId, capCents: capCents);
    state = state.copyWith(budgets: [for (final b in state.budgets) if (b.categoryId != categoryId) b, local]);
    if (_live) { try { final saved = await ref.read(remoteProvider)!.upsertBudget(categoryId, capCents); state = state.copyWith(budgets: [for (final b in state.budgets) b.categoryId == categoryId ? saved : b]); } catch (_) { state = state.copyWith(offline: true); } }
  }

  Future<void> deleteBudget(String id) async {
    state = state.copyWith(budgets: state.budgets.where((b) => b.id != id).toList());
    if (_live && !id.startsWith('local-')) { try { await ref.read(remoteProvider)!.deleteBudget(id); } catch (_) {} }
  }

  Future<void> saveGoal(Goal g) async {
    final isNew = !state.goals.any((x) => x.id == g.id);
    state = state.copyWith(goals: isNew ? [...state.goals, g] : [for (final x in state.goals) x.id == g.id ? g : x]);
    if (_live) {
      try {
        final saved = await ref.read(remoteProvider)!.upsertGoal(g);
        state = state.copyWith(goals: [for (final x in state.goals) x.id == g.id ? saved : x]);
      } catch (_) { state = state.copyWith(offline: true); }
    }
  }

  Future<void> deleteGoal(String id) async {
    state = state.copyWith(goals: state.goals.where((g) => g.id != id).toList());
    if (_live && !id.startsWith('local-')) { try { await ref.read(remoteProvider)!.deleteGoal(id); } catch (_) {} }
  }

  Future<void> addCategory(String name, String colorKey) async {
    final c = Category(id: 'local-c-${_now.microsecondsSinceEpoch}', name: name, colorKey: colorKey);
    state = state.copyWith(categories: [...state.categories, c]);
    if (_live) { try { final saved = await ref.read(remoteProvider)!.insertCategory(name, colorKey); state = state.copyWith(categories: [for (final x in state.categories) x.id == c.id ? saved : x]); } catch (_) {} }
  }

  Future<void> renameCategory(String id, String name) async {
    state = state.copyWith(categories: [for (final c in state.categories) c.id == id ? Category(id: c.id, name: name, colorKey: c.colorKey, icon: c.icon, kind: c.kind) : c]);
    if (_live && !id.startsWith('local-')) { try { await ref.read(remoteProvider)!.renameCategory(id, name); } catch (_) {} }
  }

  Future<void> deleteRule(String id) async {
    state = state.copyWith(rules: state.rules.where((r) => r.id != id).toList());
    if (_live && !id.startsWith('local-')) { try { await ref.read(remoteProvider)!.deleteRule(id); } catch (_) {} }
  }

  /// Payday plan: move money to savings. Adds to each goal, records one Transfer so the ledger stays honest, and notes the payday.
  Future<void> movePaydayToSavings(List<Goal> moves) async {
    final total = moves.fold<int>(0, (s, g) => s + g.perPaydayCents);
    if (total <= 0) return;
    for (final g in moves) {
      await saveGoal(Goal(id: g.id, name: g.name, targetCents: g.targetCents, savedCents: g.savedCents + g.perPaydayCents, perPaydayCents: g.perPaydayCents));
    }
    await add(amountCents: -total, merchant: 'Move to savings', categoryId: 'cat-transfer', source: 'manual', tags: const [], flow: 'transfer');
    if (_live) { try { await ref.read(remoteProvider)!.recordPayday(total); } catch (_) {} }
  }

  Future<void> addRecurring(Recurring r) async {
    state = state.copyWith(recurring: [...state.recurring, r]);
    final remote = ref.read(remoteProvider);
    if (remote != null && !ref.read(settingsProvider).demoMode) { try { await remote.insertRecurring(r); } catch (_) {} }
  }
}

final ledgerProvider = NotifierProvider<LedgerNotifier, LedgerState>(LedgerNotifier.new);

/// Safe to spend until the next payday, or null if no payday rule is known yet.
final safeToSpendProvider = Provider<SafeToSpend?>((ref) {
  final demo = ref.watch(settingsProvider.select((s) => s.demoMode));
  var rule = ref.watch(settingsProvider.select((s) => s.rule));
  final l = ref.watch(ledgerProvider);
  final now = ref.watch(clockProvider)();
  if (demo) rule = demoPaydayRule(now);
  if (rule == null) return null;
  return computeSafeToSpend(today: dayOnly(now), rule: rule, accounts: l.accounts, recurring: l.recurring, goals: l.goals, expected: l.expected);
});
