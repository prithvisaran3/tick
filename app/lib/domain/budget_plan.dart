import 'models.dart';
import 'money.dart';
import 'payday.dart';
import 'safe_to_spend.dart';
import 'dates.dart';

enum PaceState { calm, warm, hot, over }

class BudgetPace {
  const BudgetPace({required this.spentCents, required this.capCents, required this.projectedCents, required this.paceFraction, required this.state, this.early = false});
  final int spentCents;
  final int capCents;
  final int projectedCents;
  final double paceFraction; // where the pace marker sits on the bar: fraction of the month elapsed
  final PaceState state;
  final bool early; // too early in the month for a projection to mean anything
  double get fill => capCents == 0 ? 0 : (spentCents / capCents).clamp(0.0, 1.3);
  String get line => switch (state) {
        PaceState.over => 'Over by ${formatDollars(spentCents - capCents)}.',
        PaceState.hot => 'Running hot: on pace for ${formatDollars(projectedCents)} vs your ${formatDollars(capCents)}.',
        PaceState.warm => 'Close: on pace for ${formatDollars(projectedCents)} of ${formatDollars(capCents)}.',
        PaceState.calm => early ? '${formatDollars(capCents - spentCents)} left this month.' : '${formatDollars(capCents - spentCents)} left. On pace for ${formatDollars(projectedCents)}.',
      };
}

/// Pace line for a monthly cap. Pure; unit-tested.
BudgetPace budgetPace({required int spentCents, required int capCents, required DateTime now}) {
  final total = DateTime(now.year, now.month + 1, 0).day;
  final day = now.day.clamp(1, total);
  final projected = (spentCents / day * total).round();
  final early = day < 7;
  final state = spentCents > capCents
      ? PaceState.over
      : early
          ? PaceState.calm
          : projected > capCents * 1.1
          ? PaceState.hot
          : projected > capCents * 0.9 && day >= 5
              ? PaceState.warm
              : PaceState.calm;
  return BudgetPace(spentCents: spentCents, capCents: capCents, projectedCents: projected, paceFraction: day / total, state: state, early: early);
}


double goalProgress(Goal g) => g.targetCents == 0 ? 0 : (g.savedCents / g.targetCents).clamp(0.0, 1.0);

class PaydayPlan {
  const PaydayPlan({required this.paycheckCents, required this.moves, required this.billsCents, required this.safeAfterCents, required this.nextPayday});
  final int paycheckCents;
  final List<Goal> moves; // goals that still need money this payday
  final int billsCents;   // bills before the FOLLOWING payday
  final int safeAfterCents;
  final DateTime nextPayday;
  int get moveCents => moves.fold(0, (s, g) => s + g.perPaydayCents);
  String get headline => moveCents > 0
      ? 'Payday. Move ${formatDollars(moveCents)} to savings and you still have ${formatDollars(safeAfterCents)} safe.'
      : 'Payday. ${formatDollars(safeAfterCents)} safe to spend until ${_dayName(nextPayday)}.';
}

String _dayName(DateTime d) => const ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'][d.weekday - 1];

/// The plan for a payday: cash (including the paycheck if it has not landed yet), minus bills before the next payday, minus what you move to savings.
PaydayPlan buildPaydayPlan({
  required DateTime today,
  required PaydayRule rule,
  required List<Account> accounts,
  required List<Recurring> recurring,
  required List<Goal> goals,
  required bool paycheckLanded,
}) {
  final t = dayOnly(today);
  final next = nextPayday(rule, addDays(t, 1));
  final cash = accounts.where((a) => a.includeInSafe && a.isCash && a.type != 'savings').fold<int>(0, (s, a) => s + (a.availableCents ?? a.balanceCents ?? 0));
  final debts = debtsDueBy(accounts: accounts, recurring: recurring, today: t, payday: next);
  final owed = debts.cardsDue + debts.loansDue;
  final paycheck = rule.amountCents;
  var bills = 0;
  for (final r in recurring) {
    bills += r.expectedCents * occurrencesBetween(r.cadence, r.nextDate, t, next).length;
  }
  final moves = goals.where((g) => g.savedCents < g.targetCents && g.perPaydayCents > 0).toList();
  final move = moves.fold<int>(0, (s, g) => s + g.perPaydayCents);
  final safe = cash - owed + (paycheckLanded ? 0 : paycheck) - bills - move;
  return PaydayPlan(paycheckCents: paycheck, moves: moves, billsCents: bills, safeAfterCents: safe, nextPayday: next);
}

/// True on payday or the day before: the Payday plan card shows on Today.
bool isPaydayWindow(PaydayRule rule, DateTime today) {
  final t = dayOnly(today);
  final next = nextPayday(rule, t);
  return daysBetween(t, next) <= 1;
}
