import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:tick/domain/goals.dart';
import 'package:tick/domain/models.dart';

void main() {
  test('the shared vectors (same file Python runs)', () {
    final cases = (jsonDecode(File('../api/tests/data/goal_status.json').readAsStringSync())['cases'] as List).cast<Map<String, dynamic>>();
    const names = {GoalState.done: 'done', GoalState.onTrack: 'on_track', GoalState.behind: 'behind'};
    for (final c in cases) {
      final s = goalStatus(mode: c['mode'] as String, targetCents: c['target'] as int, startCents: c['start_cents'] as int, linkedCents: c['linked'] as int,
          deadline: c['deadline'] == null ? null : DateTime.parse(c['deadline'] as String), today: DateTime.parse(c['today'] as String), paydays: [for (final p in c['paydays'] as List) DateTime.parse(p as String)]);
      final w = (c['want'] as Map).cast<String, dynamic>();
      expect({'status': names[s.state], 'saved': s.savedCents, 'remaining': s.remainingCents, 'paychecks_left': s.paychecksLeft, 'per_paycheck': s.perPaycheckCents, 'behind_by': s.behindByCents}, w, reason: c['name'] as String);
    }
  });

  test('\$9,000 in 3 months on a biweekly schedule: the paydays come from the pay rule', () {
    final rule = PaydayRule(frequency: PayFrequency.biweekly, anchor: DateTime(2026, 11, 27), amountCents: 247707);
    final days = paydaysBetween(rule, DateTime(2026, 11, 15), DateTime(2027, 2, 15));
    expect(days.length, 6);
    expect(days.first, DateTime(2026, 11, 27));
    expect(days.last, DateTime(2027, 2, 5));
    const sav = Account(id: 'sav', name: 'SoFi', type: 'savings', balanceCents: 500000);
    final g = Goal(id: 'g', name: 'Move', targetCents: 900000, savedCents: 0, perPaydayCents: 0, mode: 'save_more', startCents: 500000, startDate: DateTime(2026, 11, 15), dueDate: DateTime(2027, 2, 15), accountIds: const ['sav']);
    final p = planGoal(g, [sav], rule, DateTime(2026, 11, 15));
    expect((p.status.state, p.status.paychecksLeft, p.status.perPaycheckCents), (GoalState.onTrack, 6, 150000));
    expect(moveThisPayday([g], [sav], rule, DateTime(2026, 11, 27)), 150000);
    // Safe to spend sees the worked-out amount, and nothing more once this payday's move is made
    expect(plannedGoals([g], [sav], rule, DateTime(2026, 11, 27)).single.perPaydayCents, 150000);
    expect(plannedGoals([g], [sav], rule, DateTime(2026, 11, 27), movedThisPeriod: true).single.perPaydayCents, 0);
  });

  test('a goal with no account keeps what was typed', () {
    const g = Goal(id: 'g', name: 'Old', targetCents: 100000, savedCents: 25000, perPaydayCents: 5000);
    final p = planGoal(g, const [], null, DateTime(2026, 11, 15));
    expect((p.status.savedCents, p.status.perPaycheckCents, p.status.state), (25000, 5000, GoalState.onTrack));
    expect(plannedGoals([g], const [], null, DateTime(2026, 11, 15)).single.perPaydayCents, 5000);
  });
}
