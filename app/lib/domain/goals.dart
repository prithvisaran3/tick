import 'dates.dart';
import 'models.dart';
import 'payday.dart';

enum GoalState { done, onTrack, behind }

/// Where a goal stands, from real balances. The same arithmetic as Python `goal_status` (vectors: api/tests/data/goal_status.json).
class GoalStatus {
  const GoalStatus({required this.state, required this.savedCents, required this.remainingCents, required this.paychecksLeft, required this.perPaycheckCents, required this.behindByCents, required this.amountCents});
  final GoalState state;
  final int savedCents;
  final int remainingCents;
  final int paychecksLeft;
  /// What each paycheck from now has to carry to get there on time.
  final int perPaycheckCents;
  /// How far behind the even pace it is today. Folded into [perPaycheckCents] already.
  final int behindByCents;
  /// The whole distance: target for "save more", target minus the starting balance for "reach a balance".
  final int amountCents;
  double get progress => amountCents == 0 ? 1 : (savedCents / amountCents).clamp(0.0, 1.0);
}

const _tolerance = 100;      // a dollar of interest or rounding isn't "behind"

/// [paydays]: every payday after the goal's start up to its deadline. A payday that is today still counts as one to use.
GoalStatus goalStatus({required String mode, required int targetCents, required int startCents, required int linkedCents, required DateTime? deadline, required DateTime today, required List<DateTime> paydays}) {
  final amount = mode == 'balance' ? (targetCents - startCents < 0 ? 0 : targetCents - startCents) : (targetCents < 0 ? 0 : targetCents);
  final grown = linkedCents - startCents;
  final saved = grown < 0 ? 0 : (grown > amount ? amount : grown);
  final remaining = amount - saved;
  final t = dayOnly(today);
  final days = [for (final p in paydays) dayOnly(p)]..sort();
  final left = deadline == null ? 0 : days.where((p) => !p.isBefore(t)).length;
  GoalStatus out(GoalState s, int per, int behind) => GoalStatus(state: s, savedCents: saved, remainingCents: remaining, paychecksLeft: left, perPaycheckCents: per, behindByCents: behind, amountCents: amount);
  if (remaining == 0) return out(GoalState.done, 0, 0);
  if (deadline == null) return out(GoalState.onTrack, 0, 0);
  if (left == 0) return out(GoalState.behind, remaining, remaining);
  final planned = days.isEmpty ? amount : (amount + days.length - 1) ~/ days.length;
  final elapsed = days.where((p) => p.isBefore(t)).length;
  final due = planned * elapsed > amount ? amount : planned * elapsed;
  var behind = due - saved < 0 ? 0 : due - saved;
  if (behind <= _tolerance) behind = 0;
  return out(behind > 0 ? GoalState.behind : GoalState.onTrack, (remaining + left - 1) ~/ left, behind);
}

/// Every payday after [after], up to and including [to].
List<DateTime> paydaysBetween(PaydayRule rule, DateTime after, DateTime to) {
  final out = <DateTime>[];
  var d = nextPayday(rule, addDays(dayOnly(after), 1));
  final end = dayOnly(to);
  while (!d.isAfter(end) && out.length < 400) {
    out.add(d);
    d = nextPayday(rule, addDays(d, 1));
  }
  return out;
}

/// A goal with where it stands.
class GoalPlan {
  const GoalPlan(this.goal, this.status);
  final Goal goal;
  final GoalStatus status;
}

/// The balance a goal is measured against: its linked accounts' balances now.
int linkedBalance(Goal g, List<Account> accounts) => accounts.where((a) => g.accountIds.contains(a.id)).fold<int>(0, (s, a) => s + (a.balanceCents ?? 0));

GoalPlan planGoal(Goal g, List<Account> accounts, PaydayRule? rule, DateTime today) {
  if (!g.linked) {
    // An older goal with no account: what was typed is all Tick knows.
    final remaining = g.targetCents - g.savedCents < 0 ? 0 : g.targetCents - g.savedCents;
    return GoalPlan(g, GoalStatus(state: remaining == 0 ? GoalState.done : GoalState.onTrack, savedCents: g.savedCents, remainingCents: remaining, paychecksLeft: 0,
        perPaycheckCents: remaining == 0 ? 0 : g.perPaydayCents, behindByCents: 0, amountCents: g.targetCents));
  }
  final start = g.startDate ?? today;
  final paydays = rule == null || g.dueDate == null ? const <DateTime>[] : paydaysBetween(rule, start, g.dueDate!);
  return GoalPlan(g, goalStatus(mode: g.mode, targetCents: g.targetCents, startCents: g.startCents, linkedCents: linkedBalance(g, accounts), deadline: g.dueDate, today: today, paydays: paydays));
}

/// Goals as Safe to spend and the payday plan need them: saved and per-paycheck worked out from balances.
/// [movedThisPeriod]: the payday move is already made (or marked made), so nothing more is set aside until the next payday.
List<Goal> plannedGoals(List<Goal> goals, List<Account> accounts, PaydayRule? rule, DateTime today, {bool movedThisPeriod = false}) => [
      for (final g in goals)
        if (!g.linked) g
        else () {
          final s = planGoal(g, accounts, rule, today).status;
          return g.copyWith(savedCents: g.mode == 'balance' ? g.startCents + s.savedCents : s.savedCents, perPaydayCents: movedThisPeriod || g.paused ? 0 : s.perPaycheckCents);
        }(),
    ];

/// The one number for the payday card: what to move to savings this payday across every active goal.
int moveThisPayday(List<Goal> goals, List<Account> accounts, PaydayRule? rule, DateTime today) =>
    [for (final g in goals) if (!g.paused) planGoal(g, accounts, rule, today).status].fold<int>(0, (s, x) => s + (x.state == GoalState.done ? 0 : x.perPaycheckCents));
