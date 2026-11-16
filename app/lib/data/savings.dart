import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/dates.dart';
import '../domain/goals.dart';
import '../domain/models.dart';
import '../domain/payday.dart';
import '../services/api.dart';
import 'demo_seed.dart';
import 'ledger.dart';
import 'remote.dart';
import 'settings.dart';

String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// A balance on a day, from the nightly snapshots.
typedef BalancePoint = ({DateTime day, int cents});

Duration? _noRetry(int _, Object _) => null;

/// Daily balances for the last 90 days, by account. The trend line and "this month" read these.
final balanceHistoryProvider = FutureProvider<Map<String, List<BalancePoint>>>((ref) async {
  ref.watch(ledgerRevisionProvider);
  final now = dayOnly(ref.watch(clockProvider)());
  final l = ref.read(ledgerProvider);
  if (ref.watch(settingsProvider.select((s) => s.demoMode))) {
    // Demo: a gentle climb to today's balance, so the screen shows what it will look like.
    return {
      for (final a in l.accounts.where((a) => a.type == 'savings'))
        a.id: [for (var i = 60; i >= 0; i -= 3) (day: addDays(now, -i), cents: (a.balanceCents ?? 0) - (i ~/ 14) * 20000 - (i % 14 == 0 ? 0 : 0))],
    };
  }
  final r = ref.watch(remoteProvider);
  if (r == null) return const {};
  final rows = await r.db.from('account_balances').select('account_id,day,balance_cents').gte('day', _iso(addDays(now, -90))).order('day');
  final out = <String, List<BalancePoint>>{};
  for (final j in rows) {
    out.putIfAbsent(j['account_id'] as String, () => []).add((day: DateTime.parse(j['day'] as String), cents: (j['balance_cents'] as num).toInt()));
  }
  return out;
}, retry: _noRetry);

/// Change since the first snapshot of this month; null until there is one to compare with.
int? changeThisMonth(List<BalancePoint> points, int nowCents, DateTime today) {
  final first = points.where((p) => p.day.year == today.year && p.day.month == today.month).firstOrNull;
  final before = points.where((p) => p.day.isBefore(DateTime(today.year, today.month, 1))).lastOrNull;
  final base = before ?? first;
  return base == null ? null : nowCents - base.cents;
}

/// "Move $X to savings" on a payday: not yet, marked done (waiting for a balance), confirmed, or not seen after two days.
enum MoveState { none, done, confirmed, unconfirmed }

class GoalMoves extends AsyncNotifier<Map<String, MoveState>> {
  @override
  Future<Map<String, MoveState>> build() async {
    ref.watch(ledgerRevisionProvider);
    final r = ref.watch(remoteProvider);
    if (r == null || ref.watch(settingsProvider.select((s) => s.demoMode))) return const {};
    final rows = await r.db.from('goal_moves').select('pay_date,status').order('pay_date', ascending: false).limit(12);
    return {for (final j in rows) j['pay_date'] as String: MoveState.values.firstWhere((s) => s.name == j['status'], orElse: () => MoveState.done)};
  }

  MoveState of(DateTime payday) => state.value?[_iso(payday)] ?? MoveState.none;

  Future<void> markDone(DateTime payday, int cents) async {
    final key = _iso(payday);
    final before = state.value ?? const <String, MoveState>{};
    state = AsyncData({...before, key: MoveState.done});
    if (ref.read(remoteProvider) == null || ref.read(settingsProvider).demoMode) return;
    try {
      await ref.read(apiProvider).post('/goals/move', {'pay_date': key, 'cents': cents});
    } catch (e) {
      state = AsyncData(before);
      rethrow;
    }
  }

  Future<void> undo(DateTime payday) async {
    final key = _iso(payday);
    final before = state.value ?? const <String, MoveState>{};
    state = AsyncData({...before}..remove(key));
    if (ref.read(remoteProvider) == null || ref.read(settingsProvider).demoMode) return;
    try {
      await ref.read(apiProvider).post('/goals/move/undo', {'pay_date': key});
    } catch (e) {
      state = AsyncData(before);
      rethrow;
    }
  }
}

final goalMovesProvider = AsyncNotifierProvider<GoalMoves, Map<String, MoveState>>(GoalMoves.new);

PaydayRule? _rule(Ref ref) {
  final s = ref.watch(settingsProvider);
  return s.demoMode ? demoPaydayRule(ref.watch(clockProvider)()) : s.rule;
}

/// Every goal with where it stands today, behind first, then the nearest deadline.
final goalPlansProvider = Provider<List<GoalPlan>>((ref) {
  final l = ref.watch(ledgerProvider);
  final now = dayOnly(ref.watch(clockProvider)());
  final rule = _rule(ref);
  final plans = [for (final g in l.goals) planGoal(g, l.accounts, rule, now)];
  int rank(GoalPlan p) => p.goal.paused ? 3 : switch (p.status.state) { GoalState.behind => 0, GoalState.onTrack => 1, GoalState.done => 2 };
  plans.sort((a, b) => rank(a) != rank(b) ? rank(a).compareTo(rank(b)) : (a.goal.dueDate ?? DateTime(9999)).compareTo(b.goal.dueDate ?? DateTime(9999)));
  return plans;
});

/// The payday this pay period began on: the one a "Move to savings" belongs to.
final currentPaydayProvider = Provider<DateTime?>((ref) {
  final rule = _rule(ref);
  if (rule == null) return null;
  return payDates(rule, dayOnly(ref.watch(clockProvider)())).$1;
});

/// The payday card: how much to move, for which payday, and where that stands. Null when there is nothing to move or payday was days ago.
final paydayMoveProvider = Provider<({DateTime payday, int cents, MoveState state})?>((ref) {
  final payday = ref.watch(currentPaydayProvider);
  if (payday == null) return null;
  final now = dayOnly(ref.watch(clockProvider)());
  final l = ref.watch(ledgerProvider);
  final cents = moveThisPayday(l.goals.where((g) => g.linked).toList(), l.accounts, _rule(ref), payday);
  final state = ref.watch(goalMovesProvider).value?[_iso(payday)] ?? MoveState.none;
  if (state == MoveState.confirmed) return null;
  if (state == MoveState.none && (cents <= 0 || daysBetween(payday, now) > 3)) return null;
  if (cents <= 0 && state == MoveState.none) return null;
  return (payday: payday, cents: cents, state: state);
});
