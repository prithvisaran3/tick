import 'dates.dart';
import 'goals.dart';
import 'models.dart';
import 'payday.dart';

/// A one-off I know is coming: "Birthday gift, $500, Nov 22".
class PlannedExpense {
  const PlannedExpense({required this.id, required this.name, required this.amountCents, required this.due, this.status = 'planned', this.matchedTxn, this.rejected = const [],
      this.goalId, this.resolution, this.shortfallCents = 0});
  final String id;
  final String name;
  final int amountCents;
  final DateTime due;
  final String status;          // planned | matched | dismissed
  final String? matchedTxn;
  final List<String> rejected;  // transactions I said weren't this
  final String? goalId;
  final String? resolution;     // catch_up | move_deadline: what I chose when it left a goal short
  final int shortfallCents;
  bool get open => status == 'planned';
  PlannedExpense copyWith({String? status, String? matchedTxn, List<String>? rejected, String? goalId, String? resolution, int? shortfallCents}) => PlannedExpense(id: id, name: name, amountCents: amountCents, due: due,
      status: status ?? this.status, matchedTxn: matchedTxn ?? this.matchedTxn, rejected: rejected ?? this.rejected, goalId: goalId ?? this.goalId, resolution: resolution ?? this.resolution, shortfallCents: shortfallCents ?? this.shortfallCents);
  factory PlannedExpense.fromJson(Map<String, dynamic> j) => PlannedExpense(id: j['id'] as String, name: j['name'] as String, amountCents: (j['amount_cents'] as num).toInt(), due: DateTime.parse(j['due'] as String),
      status: (j['status'] ?? 'planned') as String, matchedTxn: j['matched_txn'] as String?, rejected: [for (final r in (j['rejected_txns'] as List? ?? const [])) '$r'], goalId: j['goal_id'] as String?,
      resolution: j['resolution'] as String?, shortfallCents: (j['shortfall_cents'] as num?)?.toInt() ?? 0);
}

const plannedGraceDays = 7;     // still counted this long after its date, in case the purchase is late

/// Counts against this pay period: not bought yet, dated before the next payday, and not long past.
bool countsThisPeriod(PlannedExpense p, DateTime today, DateTime payday) =>
    p.open && dayOnly(p.due).isBefore(dayOnly(payday)) && !dayOnly(p.due).isBefore(addDays(dayOnly(today), -plannedGraceDays));

/// What goals give up this period because of one-offs I already made a choice about. It stays for the whole period, matched or not,
/// so the money isn't asked for twice.
int goalRelief(List<PlannedExpense> planned, DateTime periodStart, DateTime payday) => planned
    .where((p) => p.resolution != null && p.status != 'dismissed' && !dayOnly(p.due).isBefore(addDays(dayOnly(periodStart), -plannedGraceDays)) && dayOnly(p.due).isBefore(dayOnly(payday)))
    .fold<int>(0, (s, p) => s + p.shortfallCents);

/// A one-off leaves a goal short this paycheck. Two ways out; nothing changes until one is picked.
class TradeOff {
  const TradeOff({required this.expense, required this.goal, required this.shortfallCents, required this.addPerLaterCents, required this.laterPaychecks, this.newDeadline});
  final PlannedExpense expense;
  final Goal goal;
  /// How much less the goal gets this paycheck.
  final int shortfallCents;
  /// "Add $Y to later paychecks": the shortfall spread over the paychecks left after this one.
  final int addPerLaterCents;
  final int laterPaychecks;
  /// "Move deadline to": the payday the goal lands on if every paycheck keeps its current amount. Null when there's no rule or no deadline.
  final DateTime? newDeadline;
}

/// [freeCents]: Safe to spend with every goal move and one-off already taken out. Below zero means the plan doesn't fit, and the gap comes
/// out of this paycheck's goal move (never more than that move).
TradeOff? tradeOff({required int freeCents, required List<GoalPlan> plans, required List<PlannedExpense> planned, required PaydayRule? rule, required DateTime today, required DateTime payday}) {
  if (freeCents >= 0) return null;
  final open = planned.where((p) => p.resolution == null && countsThisPeriod(p, today, payday)).toList()..sort((a, b) => b.amountCents.compareTo(a.amountCents));
  final plan = plans.where((p) => p.goal.linked && !p.goal.paused && p.status.state != GoalState.done && p.status.perPaycheckCents > 0).firstOrNull;
  if (open.isEmpty || plan == null) return null;
  final per = plan.status.perPaycheckCents;
  final short = -freeCents < per ? -freeCents : per;
  final later = plan.status.paychecksLeft - 1 < 1 ? 1 : plan.status.paychecksLeft - 1;
  DateTime? moved;
  if (rule != null && plan.goal.dueDate != null) {
    final extra = (short + per - 1) ~/ per;
    final after = paydaysBetween(rule, plan.goal.dueDate!, addDays(plan.goal.dueDate!, 400));
    if (after.length >= extra) moved = after[extra - 1];
  }
  return TradeOff(expense: open.first, goal: plan.goal, shortfallCents: short, addPerLaterCents: (short + later - 1) ~/ later, laterPaychecks: later, newDeadline: moved);
}

/// The real purchase a planned one-off most likely became: money out, close in amount (20% or $20) and within a week of its date.
/// Each transaction is offered for one plan only. Nothing is linked until I say yes.
List<(PlannedExpense, Txn)> plannedMatches(List<PlannedExpense> planned, List<Txn> txns) {
  final out = <(PlannedExpense, Txn)>[];
  final used = <String>{};
  for (final p in planned.where((p) => p.open).toList()..sort((a, b) => a.due.compareTo(b.due))) {
    final slack = p.amountCents ~/ 5 < 2000 ? 2000 : p.amountCents ~/ 5;
    Txn? best;
    var bestScore = 1 << 62;
    for (final t in txns) {
      if (t.amountCents >= 0 || t.isTransfer || used.contains(t.id) || p.rejected.contains(t.id)) continue;
      final off = (-t.amountCents - p.amountCents).abs();
      final days = daysBetween(dayOnly(p.due), dayOnly(t.occurredAt)).abs();
      if (off > slack || days > 7) continue;
      final score = off + days * 500;
      if (score < bestScore) { best = t; bestScore = score; }
    }
    if (best != null) { used.add(best.id); out.add((p, best)); }
  }
  return out;
}
