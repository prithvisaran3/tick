import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tick/domain/models.dart';
import 'package:tick/domain/receipt.dart';
import 'package:tick/features/tally_expense_sheet.dart';
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

  testWidgets('a Tally field keeps focus (and so the keyboard) while the sheet rebuilds on every keystroke', (tester) async {
    await loadFonts();
    final c = await demoContainer(demo: false);
    addTearDown(c.dispose);
    final ctl = TextEditingController();
    late StateSetter set;
    await tester.pumpWidget(frame(c, StatefulBuilder(builder: (_, s) { set = s; return Column(children: [TallyField(controller: ctl, hint: 'x', onChanged: (_) => set(() {}))]); }), dark: true));
    await tester.tap(find.byType(EditableText));
    await tester.pump();
    tester.testTextInput.enterText('4');
    await tester.pump();
    tester.testTextInput.enterText('42');
    await tester.pump();
    expect(tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus, isTrue);
  });

  test('Morning Receipt counts only real spending, not card payments or transfers', () {
    final now = DateTime(2026, 11, 5, 9);
    final y = DateTime(2026, 11, 4, 12);
    final r = buildReceipt([
      Txn(id: '1', amountCents: -600, occurredAt: y, merchant: 'Coffee'),
      Txn(id: '2', amountCents: -120000, occurredAt: y, merchant: 'Card autopay', flow: 'transfer'),
    ], now);
    expect(r.totalCents, 600);
  });

  test('leaving or removing with a balance is blocked, with the amount; undo restores a delete', () async {
    final c = await demoContainer(demo: false);
    addTearDown(c.dispose);
    final n = c.read(tallyProvider.notifier);
    final k = await n.addPerson('Kaarthik');
    final g = await n.addGroup('Flat', [k.id]);
    await n.saveExpense(TallyExpense(id: '', groupId: g.id, description: 'Rent', amountCents: 1000, paidBy: me, shares: {me: 500, k.id: 500}, spentOn: DateTime(2026, 11, 1)));
    await expectLater(n.removeMember(g.id, k.id), throwsA(isA<TallyBlocked>().having((b) => b.netCents, 'net', -500)));
    await expectLater(n.leaveGroup(g.id), throwsA(isA<TallyBlocked>().having((b) => b.netCents, 'net', 500)));
    final e = c.read(tallyProvider).expensesOf(g.id).single;
    await n.deleteExpense(e.id);
    expect(c.read(tallyProvider).balancesOf(g.id), isEmpty);
    await n.restoreExpense(e);
    expect(c.read(tallyProvider).balancesOf(g.id)[k.id], -500);
    await n.settle(g.id, k.id, me, 500);
    await n.removeMember(g.id, k.id);
    expect(c.read(tallyProvider).groups.single.memberIds, isEmpty);
  });

  test('a reminder is spaced and shows who it was for', () async {
    final c = await demoContainer(demo: false);
    addTearDown(c.dispose);
    final n = c.read(tallyProvider.notifier);
    final k = await n.addPerson('Kaarthik');
    final g = await n.addGroup('Flat', [k.id]);
    await n.saveExpense(TallyExpense(id: '', groupId: g.id, description: 'Rent', amountCents: 1000, paidBy: me, shares: {me: 500, k.id: 500}, spentOn: DateTime(2026, 11, 1)));
    await n.remind(g.id, k.id, ReminderTone.neutral);
    expect(c.read(tallyProvider).lastReminder(g.id, k.id), isNotNull);
    expect(c.read(tallyProvider).reminders.single.amountCents, 500);
  });

  test('Zelle: my note wins, then their email or phone; clearing falls back', () async {
    final c = await demoContainer(demo: false);
    addTearDown(c.dispose);
    final n = c.read(tallyProvider.notifier);
    final k = await n.addPerson('Kaarthik');
    final g = await n.addGroup('Flat', [k.id]);
    final m = await n.addGuest(g.id, 'Asha', phone: '5551234567');
    expect(c.read(tallyProvider).zelleOf(k.id), isNull);
    expect(c.read(tallyProvider).zelleOf(m), '5551234567');
    await n.setZelle(m, 'asha@zelle.test');
    expect(c.read(tallyProvider).zelleOf(m), 'asha@zelle.test');
    await n.setZelle(m, ' ');
    expect(c.read(tallyProvider).zelleOf(m), '5551234567');
  });
}
