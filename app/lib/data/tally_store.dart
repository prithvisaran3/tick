import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/tally.dart';
import 'ledger.dart' show clockProvider;
import 'remote.dart';
import 'settings.dart';

class TallyState {
  const TallyState({this.people = const [], this.groups = const [], this.expenses = const [], this.settlements = const [], this.loading = false, this.offline = false});
  final List<TallyPerson> people;
  final List<TallyGroup> groups;
  final List<TallyExpense> expenses;
  final List<TallySettlement> settlements;
  final bool loading;
  final bool offline;

  TallyState copyWith({List<TallyPerson>? people, List<TallyGroup>? groups, List<TallyExpense>? expenses, List<TallySettlement>? settlements, bool? loading, bool? offline}) =>
      TallyState(people: people ?? this.people, groups: groups ?? this.groups, expenses: expenses ?? this.expenses, settlements: settlements ?? this.settlements,
          loading: loading ?? this.loading, offline: offline ?? this.offline);

  TallyPerson? person(String id) {
    for (final p in people) { if (p.id == id) return p; }
    return null;
  }
  String nameOf(String id) => id == me ? 'You' : (person(id)?.first ?? 'Someone');
  List<TallyExpense> expensesOf(String gid) => [for (final e in expenses) if (e.groupId == gid) e]..sort((a, b) => b.spentOn.compareTo(a.spentOn));
  List<TallySettlement> settlementsOf(String gid) => [for (final s in settlements) if (s.groupId == gid) s]..sort((a, b) => b.on.compareTo(a.on));
  Map<String, int> balancesOf(String gid) => balances(expensesOf(gid), settlementsOf(gid));
  ({int owedToMe, int iOwe}) get totals => summary(groups, expenses, settlements);
  bool get allSquare => isAllSquare(groups, expenses, settlements);
  int pendingCount(String gid) => settlements.where((s) => s.groupId == gid && s.status == 'pending').length;
}

String? _id(Object? v) => v as String?;

class TallyNotifier extends Notifier<TallyState> {
  int _n = 0;
  @override
  TallyState build() {
    final demo = ref.watch(settingsProvider.select((s) => s.demoMode));
    final remote = ref.watch(remoteProvider);
    if (!demo && remote != null) {
      Future.microtask(refresh);
      return const TallyState(loading: true);
    }
    return demo ? demoTally(ref.read(clockProvider)()) : const TallyState();
  }

  Remote? get _remote => ref.read(settingsProvider).demoMode ? null : ref.read(remoteProvider);
  String _local() => 'local-${++_n}';

  Future<void> refresh() async {
    final r = _remote;
    if (r == null) return;
    try {
      final db = r.db;
      final res = await Future.wait([
        db.from('people').select().filter('archived_at', 'is', null),
        db.from('tally_groups').select().filter('archived_at', 'is', null),
        db.from('tally_members').select(),
        db.from('tally_expenses').select().filter('deleted_at', 'is', null).order('spent_on', ascending: false).limit(1000),
        db.from('tally_shares').select(),
        db.from('tally_settlements').select().filter('deleted_at', 'is', null),
      ]);
      final members = <String, List<String>>{};
      for (final m in res[2]) { (members[m['group_id'] as String] ??= []).add(m['person_id'] as String); }
      final shares = <String, Map<String, int>>{};
      final weights = <String, Map<String, num>>{};
      for (final s in res[4]) { (shares[s['expense_id'] as String] ??= {})[_id(s['person_id']) ?? me] = (s['owed_cents'] as num).toInt(); if (s['weight'] != null) { (weights[s['expense_id'] as String] ??= {})[_id(s['person_id']) ?? me] = s['weight'] as num; } }
      state = TallyState(
        people: [for (final j in res[0]) TallyPerson(id: j['id'] as String, name: j['name'] as String, colorKey: (j['color_key'] as String?) ?? 'shop', phone: j['phone'] as String?)],
        groups: [for (final j in res[1]) TallyGroup(id: j['id'] as String, name: j['name'] as String, emoji: j['emoji'] as String?, direct: j['kind'] == 'direct', colorKey: (j['color_key'] as String?) ?? 'shop', memberIds: members[j['id']] ?? const [])],
        expenses: [
          for (final j in res[3])
            TallyExpense(id: j['id'] as String, groupId: j['group_id'] as String, description: j['description'] as String, amountCents: (j['amount_cents'] as num).toInt(),
                paidBy: _id(j['paid_by']) ?? me, shares: shares[j['id']] ?? const {}, spentOn: DateTime.parse(j['spent_on'] as String),
                splitType: SplitType.values.firstWhere((t) => t.name == j['split_type'], orElse: () => SplitType.equal), transactionId: _id(j['transaction_id']), note: _id(j['note']), weights: weights[j['id']] ?? const {}),
        ],
        settlements: [
          for (final j in res[5])
            TallySettlement(id: j['id'] as String, groupId: j['group_id'] as String, from: _id(j['from_person']) ?? me, to: _id(j['to_person']) ?? me, amountCents: (j['amount_cents'] as num).toInt(),
                on: DateTime.parse(j['settled_on'] as String), method: j['method'] as String, status: j['status'] as String, transactionId: _id(j['transaction_id'])),
        ],
      );
    } catch (_) {
      state = state.copyWith(loading: false, offline: true);
    }
  }

  /// A friend, created on the spot. Returns the person (with a real id when live).
  Future<TallyPerson> addPerson(String name) async {
    var p = TallyPerson(id: _local(), name: name.trim());
    final r = _remote;
    if (r != null) {
      try {
        final j = await r.db.from('people').insert({'name': p.name}).select().single();
        p = TallyPerson(id: j['id'] as String, name: p.name);
      } catch (_) { state = state.copyWith(offline: true); }
    }
    state = state.copyWith(people: [...state.people, p]);
    return p;
  }

  Future<TallyGroup> addGroup(String name, List<String> memberIds, {String? emoji, bool direct = false}) async {
    var g = TallyGroup(id: _local(), name: name.trim(), memberIds: memberIds, emoji: emoji, direct: direct);
    final r = _remote;
    if (r != null && memberIds.any((m) => m.startsWith('local-'))) {
      state = state.copyWith(offline: true);   // a friend that never reached the server can't join a server group; keep it on this phone
    } else if (r != null) {
      try {
        final j = await r.db.from('tally_groups').insert({'name': g.name, 'emoji': emoji, 'kind': direct ? 'direct' : 'group'}).select().single();
        final gid = j['id'] as String;
        if (memberIds.isNotEmpty) await r.db.from('tally_members').insert([for (final m in memberIds) {'group_id': gid, 'person_id': m}]);
        g = TallyGroup(id: gid, name: g.name, memberIds: memberIds, emoji: emoji, direct: direct);
      } catch (_) { state = state.copyWith(offline: true); }
    }
    state = state.copyWith(groups: [...state.groups, g]);
    return g;
  }

  /// Saves an expense. The shares must already add up to the amount (the sheet and [splitEqual] etc. guarantee it; the server checks again).
  Future<bool> saveExpense(TallyExpense e) async {
    if (e.shares.values.fold<int>(0, (a, b) => a + b) != e.amountCents || e.amountCents <= 0) return false;
    var saved = e;
    final r = _remote;
    if (r != null) {
      try {
        final id = await r.db.rpc('tally_save_expense', params: {'p': {
          'id': e.id.startsWith('local-') ? null : e.id, 'group_id': e.groupId, 'description': e.description, 'amount_cents': e.amountCents,
          'paid_by': e.paidBy == me ? null : e.paidBy, 'split_type': e.splitType.name, 'spent_on': e.spentOn.toIso8601String().substring(0, 10),
          'note': e.note, 'transaction_id': e.transactionId,
          'shares': [for (final s in e.shares.entries) {'person_id': s.key == me ? null : s.key, 'owed_cents': s.value, 'weight': e.weights[s.key]}],
        }});
        saved = TallyExpense(id: id as String, groupId: e.groupId, description: e.description, amountCents: e.amountCents, paidBy: e.paidBy, shares: e.shares, spentOn: e.spentOn,
            splitType: e.splitType, transactionId: e.transactionId, note: e.note, weights: e.weights);
      } catch (_) { state = state.copyWith(offline: true); return false; }
    } else if (e.id.isEmpty) {
      saved = TallyExpense(id: _local(), groupId: e.groupId, description: e.description, amountCents: e.amountCents, paidBy: e.paidBy, shares: e.shares, spentOn: e.spentOn,
          splitType: e.splitType, transactionId: e.transactionId, note: e.note, weights: e.weights);
    }
    state = state.copyWith(expenses: [...state.expenses.where((x) => x.id != saved.id), saved]);
    return true;
  }

  Future<void> deleteExpense(String id) async {
    final r = _remote;
    if (r != null && !id.startsWith('local-')) {
      try { await r.db.from('tally_expenses').update({'deleted_at': DateTime.now().toUtc().toIso8601String()}).eq('id', id); } catch (_) { state = state.copyWith(offline: true); return; }
    }
    state = state.copyWith(expenses: [for (final e in state.expenses) if (e.id != id) e]);
  }

  /// Records that [from] paid [to]. Tick never moves money: this only notes that it happened.
  Future<void> settle(String groupId, String from, String to, int cents, {String method = 'zelle', String? transactionId}) async {
    if (cents <= 0) return;
    var s = TallySettlement(id: _local(), groupId: groupId, from: from, to: to, amountCents: cents, on: DateTime.now(), method: method, transactionId: transactionId);
    final r = _remote;
    if (r != null) {
      try {
        final j = await r.db.from('tally_settlements').insert({
          'group_id': groupId, 'from_person': from == me ? null : from, 'to_person': to == me ? null : to, 'amount_cents': cents, 'method': method, 'transaction_id': transactionId,
        }).select().single();
        s = TallySettlement(id: j['id'] as String, groupId: groupId, from: from, to: to, amountCents: cents, on: s.on, method: method, transactionId: transactionId);
      } catch (_) { state = state.copyWith(offline: true); return; }
    }
    state = state.copyWith(settlements: [...state.settlements, s]);
  }

  /// A pending "I paid" from a friend's share page: confirm it (it starts counting) or reject it.
  Future<void> resolvePending(String id, {required bool confirm}) async {
    final r = _remote;
    if (r != null) {
      try { await r.db.from('tally_settlements').update({'status': confirm ? 'confirmed' : 'rejected'}).eq('id', id); } catch (_) { state = state.copyWith(offline: true); return; }
    }
    state = state.copyWith(settlements: [
      for (final s in state.settlements)
        if (s.id != id) s else if (confirm) TallySettlement(id: s.id, groupId: s.groupId, from: s.from, to: s.to, amountCents: s.amountCents, on: s.on, method: s.method, transactionId: s.transactionId),
    ]);
  }
}

final tallyProvider = NotifierProvider<TallyNotifier, TallyState>(TallyNotifier.new);

/// Sample Tally for demo mode and the signed-out guest ledger.
TallyState demoTally(DateTime now) {
  final d = DateTime(now.year, now.month, now.day);
  const people = [TallyPerson(id: 'p-k', name: 'Kaarthik Kumar', colorKey: 'food'), TallyPerson(id: 'p-j', name: 'Jo Rivera', colorKey: 'shop'), TallyPerson(id: 'p-a', name: 'Alex Chen', colorKey: 'biz')];
  const groups = [
    TallyGroup(id: 'g-room', name: 'Roommates', emoji: '🏠', memberIds: ['p-k', 'p-j']),
    TallyGroup(id: 'g-alex', name: 'Alex', direct: true, memberIds: ['p-a'], colorKey: 'biz'),
  ];
  return TallyState(people: people, groups: groups, expenses: [
    TallyExpense(id: 'x1', groupId: 'g-room', description: 'Groceries', amountCents: 9000, paidBy: me, shares: splitEqual(9000, [me, 'p-k', 'p-j']), spentOn: d.subtract(const Duration(days: 3))),
    TallyExpense(id: 'x2', groupId: 'g-room', description: 'Internet', amountCents: 6000, paidBy: 'p-k', shares: splitEqual(6000, [me, 'p-k', 'p-j']), spentOn: d.subtract(const Duration(days: 6))),
    TallyExpense(id: 'x3', groupId: 'g-alex', description: 'Concert tickets', amountCents: 14000, paidBy: 'p-a', shares: splitEqual(14000, [me, 'p-a']), spentOn: d.subtract(const Duration(days: 9))),
  ], settlements: const []);
}
