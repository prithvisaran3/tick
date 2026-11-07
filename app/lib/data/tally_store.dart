import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/tally.dart';
import '../services/api.dart';
import 'ledger.dart' show clockProvider;
import 'remote.dart';
import 'settings.dart';
import '../domain/dates.dart';

class TallyInvite {
  const TallyInvite({required this.id, required this.groupId, required this.groupName, required this.inviterName, required this.at});
  final String id;
  final String groupId;
  final String groupName;
  final String inviterName;
  final DateTime at;
}

class TallyReminder {
  const TallyReminder({required this.id, required this.groupId, required this.toMember, required this.fromName, required this.groupName, required this.amountCents, required this.tone, required this.at, this.toMe = false, this.read = true});
  final String id;
  final String groupId;
  final String toMember;
  final String fromName;
  final String groupName;
  final int amountCents;
  final String tone;
  final DateTime at;
  final bool toMe;
  final bool read;
}

class TallyActivity {
  const TallyActivity({required this.action, required this.at, this.actor, this.label, this.oldCents, this.newCents});
  final String action;
  final DateTime at;
  final String? actor;
  final String? label;
  final int? oldCents;
  final int? newCents;
}

class TallyState {
  const TallyState({this.reminders = const [], this.bills = const [], this.people = const [], this.contacts = const [], this.groups = const [], this.expenses = const [], this.settlements = const [], this.invites = const [],
      this.myMember = const {}, this.myUserId, this.loading = false, this.offline = false, this.error});
  /// Why the last load failed, in words for a person. Null when it worked.
  final String? error;
  /// Everyone with a name in my groups, by member id, plus (locally) my friends.
  final List<TallyPerson> people;
  /// My own address book: who I can put in a new group as a guest. Ids are person ids.
  final List<TallyPerson> contacts;
  final List<TallyGroup> groups;
  final List<TallyExpense> expenses;
  final List<TallySettlement> settlements;
  final List<TallyInvite> invites;
  final List<TallyReminder> reminders;
  final List<TallyBill> bills;
  /// group id -> my member id in it (live only).
  final Map<String, String> myMember;
  final String? myUserId;
  final bool loading;
  final bool offline;

  TallyState copyWith({List<TallyPerson>? people, List<TallyPerson>? contacts, List<TallyGroup>? groups, List<TallyExpense>? expenses, List<TallySettlement>? settlements, List<TallyInvite>? invites, List<TallyReminder>? reminders, List<TallyBill>? bills, bool? loading, bool? offline, String? error}) =>
      TallyState(people: people ?? this.people, contacts: contacts ?? this.contacts, groups: groups ?? this.groups, expenses: expenses ?? this.expenses, settlements: settlements ?? this.settlements,
          invites: invites ?? this.invites, reminders: reminders ?? this.reminders, bills: bills ?? this.bills, myMember: myMember, myUserId: myUserId, loading: loading ?? this.loading, offline: offline ?? this.offline, error: error ?? this.error);

  List<TallyReminder> get inbox => [for (final r in reminders) if (r.toMe) r];
  int get inboxBadge => invites.length + inbox.where((r) => !r.read).length;
  DateTime? lastReminder(String gid, String member) {
    DateTime? best;
    for (final r in reminders) { if (r.groupId == gid && r.toMember == member && (best == null || r.at.isAfter(best))) best = r.at; }
    return best;
  }

  List<TallyBill> billsOf(String gid) => [for (final b in bills) if (b.groupId == gid) b];
  /// The same human in several groups: a Tick account, else my address book entry, else the name.
  String identityOf(String member) { final p = person(member); return p?.userId ?? p?.personId ?? (p?.name ?? member).toLowerCase(); }
  List<PlanItem> get plan => settlePlan(groups, expenses, settlements, identity: identityOf, name: nameOf);

  /// An expense or settlement can be changed by whoever added it, or the group's owner.
  bool canEdit(TallyGroup g, String? createdBy) => g.isOwner || createdBy == null || createdBy == myUserId;

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
  /// Why the last save failed, for the sheet that asked.
  String? lastError;
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
      final uid = db.auth.currentUser?.id;
      final res = await Future.wait([
        db.from('people').select().filter('archived_at', 'is', null),
        db.from('tally_groups').select().filter('deleted_at', 'is', null),
        db.from('tally_members').select('id,group_id,member_user_id,person_id,name,color_key,role,status'),
        db.from('tally_expenses').select().filter('deleted_at', 'is', null).order('spent_on', ascending: false).limit(1000),
        db.from('tally_shares').select('expense_id,member_id,owed_cents,weight'),
        db.from('tally_settlements').select().filter('deleted_at', 'is', null),
        db.from('tally_invites').select().eq('status', 'pending').eq('invitee', uid ?? ''),
        db.from('tally_reminders').select().order('created_at', ascending: false).limit(200),
        db.from('tally_recurring').select().eq('active', true),
      ]);
      final mine = <String, String>{};           // group -> my member id
      final members = <String, List<String>>{};
      for (final m in res[2]) {
        if (m['member_user_id'] == uid && m['status'] == 'active') { mine[m['group_id'] as String] = m['id'] as String; continue; }
        if (m['status'] == 'active') (members[m['group_id'] as String] ??= []).add(m['id'] as String);
      }
      final myIds = mine.values.toSet();
      String who(Object? id) => myIds.contains(id) ? me : id as String;
      final shares = <String, Map<String, int>>{};
      final weights = <String, Map<String, num>>{};
      for (final s in res[4]) {
        final k = who(s['member_id']);
        (shares[s['expense_id'] as String] ??= {})[k] = (s['owed_cents'] as num).toInt();
        if (s['weight'] != null) (weights[s['expense_id'] as String] ??= {})[k] = s['weight'] as num;
      }
      state = TallyState(
        myMember: mine, myUserId: uid,
        contacts: [for (final j in res[0]) TallyPerson(id: j['id'] as String, name: j['name'] as String, colorKey: (j['color_key'] as String?) ?? 'shop', phone: j['phone'] as String?)],
        people: [for (final j in res[2]) TallyPerson(id: j['id'] as String, name: j['name'] as String, colorKey: (j['color_key'] as String?) ?? 'shop', userId: j['member_user_id'] as String?, status: j['status'] as String,
            phone: [for (final c in res[0]) if (c['id'] == j['person_id']) c['phone'] as String?].firstOrNull, personId: j['person_id'] as String?)],
        groups: [for (final j in res[1]) TallyGroup(id: j['id'] as String, name: j['name'] as String, emoji: j['emoji'] as String?, direct: j['kind'] == 'direct', colorKey: (j['color_key'] as String?) ?? 'shop',
            memberIds: members[j['id']] ?? const [], isOwner: j['user_id'] == uid, archived: j['archived_at'] != null)],
        expenses: [
          for (final j in res[3])
            TallyExpense(id: j['id'] as String, groupId: j['group_id'] as String, description: j['description'] as String, amountCents: (j['amount_cents'] as num).toInt(),
                paidBy: who(j['paid_by_member']), shares: shares[j['id']] ?? const {}, spentOn: DateTime.parse(j['spent_on'] as String),
                splitType: SplitType.values.firstWhere((t) => t.name == j['split_type'], orElse: () => SplitType.equal), transactionId: _id(j['transaction_id']), note: _id(j['note']), weights: weights[j['id']] ?? const {},
                createdBy: _id(j['created_by']), category: _id(j['category']), receiptPath: _id(j['receipt_path'])),
        ],
        settlements: [
          for (final j in res[5])
            TallySettlement(id: j['id'] as String, groupId: j['group_id'] as String, from: who(j['from_member']), to: who(j['to_member']), amountCents: (j['amount_cents'] as num).toInt(),
                on: DateTime.parse(j['settled_on'] as String), method: j['method'] as String, status: j['status'] as String, transactionId: _id(j['transaction_id']), createdBy: _id(j['created_by'])),
        ],
        invites: [for (final j in res[6]) TallyInvite(id: j['id'] as String, groupId: j['group_id'] as String, groupName: j['group_name'] as String, inviterName: j['inviter_name'] as String, at: DateTime.parse(j['created_at'] as String))],
        reminders: [for (final j in res[7]) TallyReminder(id: j['id'] as String, groupId: j['group_id'] as String, toMember: j['to_member'] as String, fromName: j['from_name'] as String, groupName: j['group_name'] as String,
            amountCents: (j['amount_cents'] as num).toInt(), tone: j['tone'] as String, at: DateTime.parse(j['created_at'] as String).toLocal(), toMe: j['to_user'] == uid, read: j['read_at'] != null)],
        bills: [for (final j in res[8]) TallyBill(id: j['id'] as String, groupId: j['group_id'] as String, description: j['description'] as String, amountCents: (j['amount_cents'] as num).toInt(), cadence: j['cadence'] as String,
            nextOn: DateTime.parse(j['next_on'] as String), createdBy: _id(j['created_by']))],
      );
    } catch (e) {
      state = state.copyWith(loading: false, offline: true, error: describeError(e, action: 'load your tallies'));
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
    state = state.copyWith(people: [...state.people, p], contacts: [...state.contacts, p]);
    return p;
  }

  /// [memberIds]: people from my book, who join as guests. [invite]: Tick users, who get an invite to accept.
  Future<TallyGroup> addGroup(String name, List<String> memberIds, {String? emoji, bool direct = false, List<String> invite = const [], String colorKey = 'shop'}) async {
    var g = TallyGroup(id: _local(), name: name.trim(), memberIds: memberIds, emoji: emoji, direct: direct, colorKey: colorKey);
    final r = _remote;
    if (r != null && memberIds.any((m) => m.startsWith('local-'))) {
      state = state.copyWith(offline: true);   // a friend that never reached the server can't join a server group; keep it on this phone
    } else if (r != null) {
      try {
        final gid = await r.db.rpc('tally_create_group', params: {'p': {'name': g.name, 'emoji': emoji, 'color_key': colorKey, 'kind': direct ? 'direct' : 'group',
          'guests': [for (final m in memberIds) {'person_id': m}], 'invite': invite}}) as String;
        await refresh();
        return state.groups.firstWhere((x) => x.id == gid);
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
          'note': e.note, 'transaction_id': e.transactionId, 'category': e.category, 'receipt_path': e.receiptPath,
          'shares': [for (final s in e.shares.entries) {'member_id': s.key == me ? null : s.key, 'owed_cents': s.value, 'weight': e.weights[s.key]}],
        }});
        saved = TallyExpense(id: id as String, groupId: e.groupId, description: e.description, amountCents: e.amountCents, paidBy: e.paidBy, shares: e.shares, spentOn: e.spentOn,
            splitType: e.splitType, transactionId: e.transactionId, note: e.note, weights: e.weights, createdBy: e.createdBy ?? state.myUserId, category: e.category, receiptPath: e.receiptPath);
      } catch (x) { lastError = describeError(x, action: 'save that'); state = state.copyWith(offline: true); return false; }
    } else if (e.id.isEmpty) {
      saved = TallyExpense(id: _local(), groupId: e.groupId, description: e.description, amountCents: e.amountCents, paidBy: e.paidBy, shares: e.shares, spentOn: e.spentOn,
          splitType: e.splitType, transactionId: e.transactionId, note: e.note, weights: e.weights, category: e.category, receiptPath: e.receiptPath);
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

  /// Undo for [deleteExpense]: the shares never left, so the row just comes back.
  Future<void> restoreExpense(TallyExpense e) async {
    final r = _remote;
    if (r != null && !e.id.startsWith('local-')) {
      try { await r.db.from('tally_expenses').update({'deleted_at': null}).eq('id', e.id); } catch (_) { state = state.copyWith(offline: true); return; }
    }
    state = state.copyWith(expenses: [...state.expenses.where((x) => x.id != e.id), e]);
  }

  Future<void> deleteSettlement(String id) async {
    final r = _remote;
    if (r != null && !id.startsWith('local-')) await r.db.from('tally_settlements').update({'deleted_at': DateTime.now().toUtc().toIso8601String()}).eq('id', id);
    state = state.copyWith(settlements: [for (final s in state.settlements) if (s.id != id) s]);
  }

  Future<void> editSettlement(TallySettlement s, int cents) async {
    if (_remote != null) { await _rpc('tally_edit_settlement', {'p_id': s.id, 'p_cents': cents, 'p_method': s.method}); return; }
    state = state.copyWith(settlements: [for (final x in state.settlements) if (x.id == s.id) TallySettlement(id: s.id, groupId: s.groupId, from: s.from, to: s.to, amountCents: cents, on: s.on, method: s.method, status: s.status, transactionId: s.transactionId, createdBy: s.createdBy) else x]);
  }

  Future<void> restoreSettlement(TallySettlement s) async {
    final r = _remote;
    if (r != null && !s.id.startsWith('local-')) await r.db.from('tally_settlements').update({'deleted_at': null}).eq('id', s.id);
    state = state.copyWith(settlements: [...state.settlements.where((x) => x.id != s.id), s]);
  }

  /// Records that [from] paid [to]. Tick never moves money: this only notes that it happened.
  Future<bool> settle(String groupId, String from, String to, int cents, {String method = 'zelle', String? transactionId}) async {
    if (cents <= 0) return false;
    var s = TallySettlement(id: _local(), groupId: groupId, from: from, to: to, amountCents: cents, on: ref.read(clockProvider)(), method: method, transactionId: transactionId);
    final r = _remote;
    if (r != null) {
      try {
        final mine = state.myMember[groupId];
        final j = await r.db.from('tally_settlements').insert({
          'group_id': groupId, 'from_member': from == me ? mine : from, 'to_member': to == me ? mine : to, 'amount_cents': cents, 'method': method, 'transaction_id': transactionId,
          'created_by': state.myUserId,
        }).select().single();
        s = TallySettlement(id: j['id'] as String, groupId: groupId, from: from, to: to, amountCents: cents, on: s.on, method: method, transactionId: transactionId);
      } catch (x) { lastError = describeError(x, action: 'record that'); state = state.copyWith(offline: true); return false; }
    }
    state = state.copyWith(settlements: [...state.settlements, s]);
    return true;
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

  // ---------- sharing ----------
  Future<void> _rpc(String fn, Map<String, dynamic> params) async {
    final r = _remote;
    if (r == null) return;
    await r.db.rpc(fn, params: params);
    await refresh();
  }

  /// Exact handle, email or phone, or a handle prefix from 3 letters. Never a list of everyone.
  Future<List<FoundPerson>> search(String q) async {
    if (_remote == null || q.trim().isEmpty) return const [];
    final j = await ref.read(apiProvider).get('/people/search?q=${Uri.encodeQueryComponent(q.trim())}');
    return [for (final p in (j['people'] as List? ?? const [])) FoundPerson(userId: p['user_id'] as String, name: (p['display_name'] ?? p['handle'] ?? 'Tick user') as String, handle: p['handle'] as String?, avatarUrl: p['avatar_url'] as String?)];
  }

  Future<void> inviteUser(String groupId, String userId, {String? guestMember}) => _rpc('tally_invite_user', {'p_group': groupId, 'p_user': userId, 'p_guest': guestMember});
  Future<void> respondToInvite(String id, {required bool accept}) => _rpc('tally_invite_respond', {'p_invite': id, 'p_accept': accept});

  /// A guest in a group. Returns the member id; locally a guest is just a person.
  Future<String> addGuest(String groupId, String name, {String? personId, String? phone, String? email}) async {
    final r = _remote;
    if (r == null) {
      final p = TallyPerson(id: _local(), name: name.trim(), phone: phone);
      state = state.copyWith(people: [...state.people, p], contacts: [...state.contacts, p],
          groups: [for (final g in state.groups) if (g.id == groupId) _withMembers(g, [...g.memberIds, p.id]) else g]);
      return p.id;
    }
    final id = await r.db.rpc('tally_add_guest', params: {'p_group': groupId, 'p_name': name.trim(), 'p_person': personId, 'p_phone': phone, 'p_email': email}) as String;
    await refresh();
    return id;
  }

  // ---------- the group itself (owner only on the server) ----------
  TallyGroup _with(TallyGroup g, {String? name, bool? archived}) => TallyGroup(id: g.id, name: name ?? g.name, memberIds: g.memberIds, emoji: g.emoji, direct: g.direct, colorKey: g.colorKey, isOwner: g.isOwner, archived: archived ?? g.archived);
  Future<void> _patchGroup(String id, Map<String, dynamic> patch) async { await _remote?.db.from('tally_groups').update(patch).eq('id', id); }

  Future<void> renameGroup(String id, String name) async {
    await _patchGroup(id, {'name': name.trim()});
    state = state.copyWith(groups: [for (final g in state.groups) g.id == id ? _with(g, name: name.trim()) : g]);
  }
  Future<void> archiveGroup(String id, {required bool archived}) async {
    await _patchGroup(id, {'archived_at': archived ? DateTime.now().toUtc().toIso8601String() : null});
    state = state.copyWith(groups: [for (final g in state.groups) g.id == id ? _with(g, archived: archived) : g]);
  }
  Future<void> deleteGroup(String id) async {
    await _patchGroup(id, {'deleted_at': DateTime.now().toUtc().toIso8601String()});
    state = state.copyWith(groups: [for (final g in state.groups) if (g.id != id) g]);
  }
  Future<void> restoreGroup(TallyGroup g) async {
    await _patchGroup(g.id, {'deleted_at': null});
    state = state.copyWith(groups: [...state.groups.where((x) => x.id != g.id), g]);
  }

  /// Throws [TallyBlocked] with what is outstanding when the balance isn't zero.
  Future<void> removeMember(String groupId, String memberId) async {
    final net = state.balancesOf(groupId)[memberId] ?? 0;
    if (net != 0) throw TallyBlocked(net);
    if (_remote == null) {
      state = state.copyWith(groups: [for (final g in state.groups) if (g.id == groupId) _withMembers(g, [...g.memberIds]..remove(memberId)) else g]);
      return;
    }
    await _rpc('tally_remove_member', {'p_member': memberId});
  }
  Future<void> leaveGroup(String groupId) async {
    final net = state.balancesOf(groupId)[me] ?? 0;
    if (net != 0) throw TallyBlocked(net);
    if (_remote == null) { state = state.copyWith(groups: [for (final g in state.groups) if (g.id != groupId) g]); return; }
    await _rpc('tally_leave_group', {'p_group': groupId});
  }

  /// Repeats [e] on a schedule, from the next date after it.
  Future<void> addBill(TallyExpense e, String cadence) async {
    final next = nextBillDate(e.spentOn, cadence);
    final r = _remote;
    if (r == null) {
      state = state.copyWith(bills: [...state.bills, TallyBill(id: _local(), groupId: e.groupId, description: e.description, amountCents: e.amountCents, cadence: cadence, nextOn: next)]);
      return;
    }
    await _rpc('tally_save_recurring', {'p': {'group_id': e.groupId, 'description': e.description, 'amount_cents': e.amountCents, 'paid_by': e.paidBy == me ? null : e.paidBy, 'split_type': e.splitType.name,
      'category': e.category, 'cadence': cadence, 'next_on': next.toIso8601String().substring(0, 10), 'match_text': e.description,
      'shares': [for (final s in e.shares.entries) {'member_id': s.key == me ? null : s.key, 'owed_cents': s.value}]}});
  }
  Future<void> stopBill(String id) async {
    if (_remote != null) { await _rpc('tally_stop_recurring', {'p_id': id}); return; }
    state = state.copyWith(bills: [for (final b in state.bills) if (b.id != id) b]);
  }

  /// One person's plan item: every group's balance with them is recorded as settled.
  Future<void> settlePlanItem(PlanItem p, {String method = 'other'}) async {
    for (final (gid, t) in p.legs) { await settle(gid, t.from, t.to, t.cents, method: method); }
  }

  /// A receipt's line items from the photo. Empty on any failure, and the app falls back to the ordinary split.
  Future<({String? merchant, List<ReceiptItem> items, int extraCents})> readReceipt(List<int> bytes) async {
    try {
      final j = await ref.read(apiProvider).postFile('/tally/receipts/items', 'file', bytes, 'receipt.jpg');
      return (merchant: j['merchant'] as String?, extraCents: ((j['tax_cents'] as num?)?.toInt() ?? 0) + ((j['tip_cents'] as num?)?.toInt() ?? 0),
          items: [for (final i in (j['items'] as List? ?? const [])) ReceiptItem(i['name'] as String, (i['cents'] as num).toInt())]);
    } catch (_) {
      return (merchant: null, extraCents: 0, items: const <ReceiptItem>[]);
    }
  }

  /// Records a reminder. Guests also get a message the sender sends themselves.
  Future<void> remind(String groupId, String memberId, ReminderTone tone) async {
    if (_remote == null) {
      final g = state.groups.firstWhere((x) => x.id == groupId);
      state = state.copyWith(reminders: [TallyReminder(id: _local(), groupId: groupId, toMember: memberId, fromName: 'You', groupName: g.name, amountCents: -(state.balancesOf(groupId)[memberId] ?? 0), tone: tone.name, at: ref.read(clockProvider)()), ...state.reminders]);
      return;
    }
    await _rpc('tally_remind', {'p_member': memberId, 'p_tone': tone.name});
  }

  Future<void> markInboxSeen() async {
    if (state.inbox.every((r) => r.read)) return;
    await _rpc('tally_reminders_seen', {});
  }

  Future<List<TallyActivity>> activity(String groupId) async {
    final r = _remote;
    if (r == null) return const [];
    final rows = await r.db.from('tally_activity').select().eq('group_id', groupId).order('created_at', ascending: false).limit(100);
    return [for (final j in rows) TallyActivity(action: j['action'] as String, at: DateTime.parse(j['created_at'] as String).toLocal(), actor: j['actor_name'] as String?, label: j['label'] as String?,
        oldCents: (j['old_cents'] as num?)?.toInt(), newCents: (j['new_cents'] as num?)?.toInt())];
  }

  TallyGroup _withMembers(TallyGroup g, List<String> ids) => TallyGroup(id: g.id, name: g.name, memberIds: ids, emoji: g.emoji, direct: g.direct, colorKey: g.colorKey, isOwner: g.isOwner, archived: g.archived);
}

/// Leaving or removing someone with a balance is refused; the app shows what is outstanding and offers to settle.
class TallyBlocked implements Exception {
  const TallyBlocked(this.netCents);
  final int netCents;
}

/// Someone found by search: a name, a handle and an avatar. Never an email or a phone number.
class FoundPerson {
  const FoundPerson({required this.userId, required this.name, this.handle, this.avatarUrl});
  final String userId;
  final String name;
  final String? handle;
  final String? avatarUrl;
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
  return TallyState(people: people, contacts: people, groups: groups, expenses: [
    TallyExpense(id: 'x1', groupId: 'g-room', description: 'Groceries', amountCents: 9000, paidBy: me, shares: splitEqual(9000, [me, 'p-k', 'p-j']), spentOn: addDays(d, -3)),
    TallyExpense(id: 'x2', groupId: 'g-room', description: 'Internet', amountCents: 6000, paidBy: 'p-k', shares: splitEqual(6000, [me, 'p-k', 'p-j']), spentOn: addDays(d, -6)),
    TallyExpense(id: 'x3', groupId: 'g-alex', description: 'Concert tickets', amountCents: 14000, paidBy: 'p-a', shares: splitEqual(14000, [me, 'p-a']), spentOn: addDays(d, -9)),
  ], settlements: const []);
}
