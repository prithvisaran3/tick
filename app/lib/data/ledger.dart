import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/models.dart';
import '../domain/natural_input.dart';
import '../domain/payday.dart';
import '../domain/safe_to_spend.dart';
import 'categorizer.dart';
import 'demo_seed.dart';
import 'remote.dart';
import 'settings.dart';

final clockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

class LedgerState {
  const LedgerState({this.categories = const [], this.accounts = const [], this.txns = const [], this.recurring = const [], this.expected = const [], this.goals = const [], this.loading = false, this.offline = false, this.linksUsed = 0, this.connections = const [], this.justLanded});
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
  final Expected? justLanded; // money that just arrived: the Landed moment plays once

  Category? category(String? id) => categories.where((c) => c.id == id).firstOrNull;
  Category? categoryByName(String name) => categories.where((c) => c.name.toLowerCase() == name.toLowerCase()).firstOrNull;
  Account? account(String? id) => accounts.where((a) => a.id == id).firstOrNull;
  List<Txn> get needsReview => txns.where((t) => t.needsReview).toList();

  LedgerState copyWith({List<Category>? categories, List<Account>? accounts, List<Txn>? txns, List<Recurring>? recurring, List<Expected>? expected, List<Goal>? goals, bool? loading, bool? offline, int? linksUsed, List<Connection>? connections, Expected? justLanded, bool clearLanded = false}) => LedgerState(
      categories: categories ?? this.categories, accounts: accounts ?? this.accounts, txns: txns ?? this.txns, recurring: recurring ?? this.recurring,
      expected: expected ?? this.expected, goals: goals ?? this.goals, loading: loading ?? this.loading, offline: offline ?? this.offline, linksUsed: linksUsed ?? this.linksUsed, connections: connections ?? this.connections, justLanded: clearLanded ? null : (justLanded ?? this.justLanded));
}

class LedgerNotifier extends Notifier<LedgerState> {
  int _seq = 0;
  @override
  LedgerState build() {
    final s = ref.watch(settingsProvider);
    final now = ref.read(clockProvider)();
    if (s.demoMode) {
      final d = buildDemo(now);
      return LedgerState(categories: d.categories, accounts: d.accounts, txns: d.txns, recurring: d.recurring, expected: d.expected, goals: d.goals, linksUsed: 3);
    }
    final remote = ref.read(remoteProvider);
    if (remote != null) {
      Future.microtask(refresh);
      final ch = remote.listen(() => Future.microtask(refresh));
      ref.onDispose(() => ch.unsubscribe());
      return LedgerState(categories: defaultCategories, loading: true);
    }
    return const LedgerState(categories: []);
  }

  Future<void> refresh() async {
    final remote = ref.read(remoteProvider);
    if (remote == null || ref.read(settingsProvider).demoMode) return;
    try {
      final l = await remote.loadAll();
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
    } catch (_) {
      state = state.copyWith(loading: false, offline: true);
    }
  }

  void landedShown() => state = state.copyWith(clearLanded: true);

  DateTime get _now => ref.read(clockProvider)();

  /// Adds a transaction (optimistic) and persists it.
  Future<Txn> add({required int amountCents, required String merchant, DateTime? at, String? categoryId, List<String>? tags, String source = 'manual', String? note, String? accountId, double confidence = 1, bool needsReview = false}) async {
    final cat = categoryId ?? (amountCents > 0 ? 'cat-income' : categorizeLocal(merchant, rules: _rules()));
    final t = Txn(
      id: 'local-${_now.microsecondsSinceEpoch}-${_seq++}', amountCents: amountCents, occurredAt: at ?? _now, merchant: merchant, categoryId: state.category(cat) != null ? cat : state.categoryByName(_nameOf(cat))?.id ?? cat,
      accountId: accountId ?? state.accounts.where((a) => a.type == 'checking').firstOrNull?.id,
      tags: tags ?? (amountCents < 0 && looksBusiness(merchant) ? const ['business'] : const []), source: source, note: note, confidence: confidence, needsReview: needsReview);
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
    final old = state.txns.firstWhere((t) => t.id == id);
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
    final t = state.txns.firstWhere((x) => x.id == id);
    await patch(id, (t) => t.copyWith(categoryId: categoryId, needsReview: false));
    final remote = ref.read(remoteProvider);
    if (remote != null && !ref.read(settingsProvider).demoMode && !id.startsWith('local-')) {
      try { await remote.learnRule(t.merchant, categoryId); await remote.markUserEdited(id, ['category']); } catch (_) {}
    }
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
  final s = ref.watch(settingsProvider);
  final l = ref.watch(ledgerProvider);
  final now = ref.watch(clockProvider)();
  var rule = s.rule;
  if (s.demoMode) rule = buildDemo(now).rule;
  if (rule == null) return null;
  return computeSafeToSpend(today: dayOnly(now), rule: rule, accounts: l.accounts, recurring: l.recurring, goals: l.goals, expected: l.expected);
});
