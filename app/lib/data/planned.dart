import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/goals.dart';
import '../domain/models.dart';
import '../domain/payday.dart';
import '../domain/planned.dart';
import '../domain/safe_to_spend.dart';
import 'demo_seed.dart';
import 'ledger.dart';
import 'remote.dart';
import 'savings.dart';
import 'settings.dart';

String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Planned one-offs. Mine alone (RLS), written straight to the table; demo and signed-out keep them in memory.
class Planned extends AsyncNotifier<List<PlannedExpense>> {
  bool get _live => ref.read(remoteProvider) != null && !ref.read(settingsProvider).demoMode;

  @override
  Future<List<PlannedExpense>> build() async {
    final r = ref.watch(remoteProvider);
    if (r == null || ref.watch(settingsProvider.select((s) => s.demoMode))) return const [];
    final rows = await r.db.from('planned_expenses').select().neq('status', 'dismissed').order('due').limit(100);
    return [for (final j in rows) PlannedExpense.fromJson(j)];
  }

  List<PlannedExpense> get _now => state.value ?? const [];

  Future<void> add(String name, int cents, DateTime due) async {
    if (_live) {
      final j = await ref.read(remoteProvider)!.db.from('planned_expenses').insert({'name': name, 'amount_cents': cents, 'due': _iso(due)}).select().single();
      state = AsyncData([..._now, PlannedExpense.fromJson(j)]);
    } else {
      state = AsyncData([..._now, PlannedExpense(id: 'local-p-${DateTime.now().microsecondsSinceEpoch}', name: name, amountCents: cents, due: due)]);
    }
  }

  Future<void> _patch(PlannedExpense next, Map<String, dynamic> row) async {
    final before = _now;
    state = AsyncData([for (final p in before) p.id == next.id ? next : p]);
    if (!_live || next.id.startsWith('local-')) return;
    try {
      await ref.read(remoteProvider)!.db.from('planned_expenses').update(row).eq('id', next.id);
    } catch (e) {
      state = AsyncData(before);
      rethrow;
    }
  }

  Future<void> remove(PlannedExpense p) => _patch(p.copyWith(status: 'dismissed'), {'status': 'dismissed'});
  Future<void> restore(PlannedExpense p) => _patch(p, {'status': p.status});
  /// Yes on the card: this purchase was it. It drops off the plan.
  Future<void> matched(PlannedExpense p, String txnId) => _patch(p.copyWith(status: 'matched', matchedTxn: txnId), {'status': 'matched', 'matched_txn': txnId});
  /// No on the card: never offer that purchase for this plan again.
  Future<void> notThis(PlannedExpense p, String txnId) => _patch(p.copyWith(rejected: [...p.rejected, txnId]), {'rejected_txns': [...p.rejected, txnId]});

  /// The trade-off, decided. Later paychecks carry it, or the goal's deadline moves; either way this paycheck's move shrinks by the shortfall.
  Future<void> resolve(TradeOff t, {required bool moveDeadline}) async {
    await _patch(t.expense.copyWith(goalId: t.goal.id, resolution: moveDeadline ? 'move_deadline' : 'catch_up', shortfallCents: t.shortfallCents),
        {'goal_id': t.goal.id.startsWith('local-') || !RegExp(r'^[0-9a-f-]{36}$').hasMatch(t.goal.id) ? null : t.goal.id, 'resolution': moveDeadline ? 'move_deadline' : 'catch_up', 'shortfall_cents': t.shortfallCents});
    if (moveDeadline && t.newDeadline != null) await ref.read(ledgerProvider.notifier).saveGoal(t.goal.copyWith(dueDate: t.newDeadline));
  }
}

final plannedProvider = AsyncNotifierProvider<Planned, List<PlannedExpense>>(Planned.new);

/// Safe to spend for this pay period with everything in it: goal moves from balances (less what one-offs I chose to absorb), and one-offs
/// I planned. [safeToSpendProvider] reads this; kept apart so the trade-off can read the same inputs.
SafeToSpend? computeSafeFor(Ref ref, {bool withRelief = true}) {
  final demo = ref.watch(settingsProvider.select((s) => s.demoMode));
  var rule = ref.watch(settingsProvider.select((s) => s.rule));
  final l = ref.watch(ledgerProvider);
  final now = dayOnly(ref.watch(clockProvider)());
  if (demo) rule = demoPaydayRule(now);
  if (rule == null) return null;
  final planned = ref.watch(plannedProvider).value ?? const <PlannedExpense>[];
  final (start, payday) = payDates(rule, now);
  final moved = ref.watch(goalMovesProvider).value?[_iso(start)];
  final relief = withRelief ? goalRelief(planned, start, payday) : 0;
  final goals = plannedGoals(l.goals, l.accounts, rule, now, movedThisPeriod: moved != null && moved != MoveState.none, reliefCents: relief);
  return computeSafeToSpend(today: now, rule: rule, accounts: l.accounts, recurring: l.recurring, goals: goals, expected: l.expected, period: demo ? null : ref.watch(payPeriodProvider).value, planned: planned);
}

/// A one-off that leaves a goal short this paycheck, waiting for my choice. Null when the plan fits.
final tradeOffProvider = Provider<TradeOff?>((ref) {
  final sts = computeSafeFor(ref);
  if (sts == null) return null;
  final s = ref.watch(settingsProvider);
  final now = dayOnly(ref.watch(clockProvider)());
  return tradeOff(freeCents: sts.cents, plans: ref.watch(goalPlansProvider), planned: ref.watch(plannedProvider).value ?? const [], rule: s.demoMode ? demoPaydayRule(now) : s.rule, today: now, payday: sts.nextPayday);
});

/// Planned one-offs with the purchase each most likely became, for the Yes/No card.
final plannedMatchesProvider = Provider<List<(PlannedExpense, Txn)>>((ref) =>
    plannedMatches(ref.watch(plannedProvider).value ?? const [], ref.watch(ledgerProvider.select((l) => l.txns))));
