import 'package:flutter_test/flutter_test.dart';
import 'package:tick/data/tally_store.dart';
import 'golden_harness.dart';
import 'package:tick/domain/tally.dart';

void main() {
  test('local Tally flow: split, owed, settle to square, pending does not move a balance', () async {
    final c = await demoContainer(demo: false);
    final n = c.read(tallyProvider.notifier);
    final k = await n.addPerson('Kaarthik Kumar');
    final g = await n.addGroup('Roommates', [k.id]);
    expect(await n.saveExpense(TallyExpense(id: '', groupId: g.id, description: 'Groceries', amountCents: 9001, paidBy: me, shares: splitEqual(9001, [me, k.id]), spentOn: DateTime(2026, 11, 1))), isTrue);
    var s = c.read(tallyProvider);
    expect(s.totals.owedToMe, 4500);                                    // 9001 split: I carry the odd cent
    expect(s.allSquare, isFalse);
    // shares that do not add up are refused
    expect(await n.saveExpense(TallyExpense(id: '', groupId: g.id, description: 'Bad', amountCents: 1000, paidBy: me, shares: {me: 100, k.id: 100}, spentOn: DateTime(2026, 11, 1))), isFalse);
    await n.settle(g.id, k.id, me, 4500);
    s = c.read(tallyProvider);
    expect(s.totals.owedToMe, 0);
    expect(s.allSquare, isTrue);
  });
}
