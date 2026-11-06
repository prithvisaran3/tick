import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:tick/domain/tally.dart';

void main() {
  test('simplify matches the shared vectors the server uses', () {
    final vs = jsonDecode(File('../api/tests/data/tally_simplify.json').readAsStringSync()) as List;
    for (final v in vs) {
      final net = {for (final e in (v['net'] as Map).entries) e.key as String: (e.value as num).toInt()};
      final want = [for (final t in v['transfers'] as List) Transfer(t[0] as String, t[1] as String, t[2] as int)];
      expect(simplify(net), want, reason: v['name'] as String);
    }
  });

  test('equal split gives leftover cents to the first people and always adds up', () {
    expect(splitEqual(1000, ['a', 'b', 'c']), {'a': 334, 'b': 333, 'c': 333});
    for (var total = 1; total < 400; total++) {
      for (var n = 1; n < 8; n++) {
        expect(splitEqual(total, [for (var i = 0; i < n; i++) 'p$i']).values.fold<int>(0, (a, b) => a + b), total);
      }
    }
  });

  test('percent and share splits add up exactly (largest remainder)', () {
    expect(splitWeighted(10000, {'a': 50, 'b': 30, 'c': 20}), {'a': 5000, 'b': 3000, 'c': 2000});
    final s = splitWeighted(1000, {'a': 1, 'b': 1, 'c': 1})!;
    expect(s.values.fold<int>(0, (a, b) => a + b), 1000);
    expect(s['a'], 334);
    final sh = splitWeighted(9999, {'a': 2, 'b': 1, 'c': 3})!;
    expect(sh.values.fold<int>(0, (a, b) => a + b), 9999);
    expect(splitWeighted(100, {}), isNull);
    expect(splitWeighted(100, {'a': 0}), isNull);
    expect(splitWeighted(100, {'a': -1, 'b': 2}), isNull);
  });

  test('exact split is valid only when it adds up', () {
    expect(splitExact(1000, {'a': 400, 'b': 600}), {'a': 400, 'b': 600});
    expect(splitExact(1000, {'a': 400, 'b': 500}), isNull);
  });

  test('balances: payer is owed, sharers owe, confirmed settlements move money, pending ones do not', () {
    final e = TallyExpense(id: 'e', groupId: 'g', description: 'Groceries', amountCents: 9000, paidBy: me, shares: {me: 3000, 'k': 3000, 'j': 3000}, spentOn: DateTime(2026, 11, 1));
    expect(balances([e], []), {me: 6000, 'k': -3000, 'j': -3000});
    final paid = TallySettlement(id: 's', groupId: 'g', from: 'k', to: me, amountCents: 3000, on: DateTime(2026, 11, 2));
    expect(balances([e], [paid]), {me: 3000, 'j': -3000});
    final pending = TallySettlement(id: 's2', groupId: 'g', from: 'j', to: me, amountCents: 3000, on: DateTime(2026, 11, 2), status: 'pending');
    expect(balances([e], [paid, pending]), {me: 3000, 'j': -3000});
    final g = TallyGroup(id: 'g', name: 'Roommates', memberIds: const ['k', 'j']);
    expect(summary([g], [e], [paid]).owedToMe, 3000);
    expect(isAllSquare([g], [e], [paid, TallySettlement(id: 's3', groupId: 'g', from: 'j', to: me, amountCents: 3000, on: DateTime(2026, 11, 3))]), isTrue);
    expect(isAllSquare([g], [], []), isFalse); // nothing split yet is not "all square"
  });

  test('a debt in one group never cancels credit in another', () {
    final g1 = const TallyGroup(id: 'g1', name: 'A', memberIds: ['k']), g2 = const TallyGroup(id: 'g2', name: 'B', memberIds: ['j']);
    final e1 = TallyExpense(id: '1', groupId: 'g1', description: 'x', amountCents: 2000, paidBy: me, shares: {me: 1000, 'k': 1000}, spentOn: DateTime(2026, 11, 1));
    final e2 = TallyExpense(id: '2', groupId: 'g2', description: 'y', amountCents: 2000, paidBy: 'j', shares: {me: 1000, 'j': 1000}, spentOn: DateTime(2026, 11, 1));
    final s = summary([g1, g2], [e1, e2], []);
    expect((s.owedToMe, s.iOwe), (1000, 1000));
  });

  test('settlement suggestions match amount, direction and name', () {
    const t = Transfer('k', me, 3000);
    final since = DateTime(2026, 11, 1);
    expect(looksLikeSettlement(t: t, personFirstName: 'Kaarthik', txnCents: 3000, merchant: 'Zelle from Kaarthik Kumar', txnAt: DateTime(2026, 11, 5), since: since), isTrue);
    expect(looksLikeSettlement(t: t, personFirstName: 'Kaarthik', txnCents: -3000, merchant: 'Zelle to Kaarthik', txnAt: DateTime(2026, 11, 5), since: since), isFalse);
    expect(looksLikeSettlement(t: t, personFirstName: 'Kaarthik', txnCents: 2999, merchant: 'Zelle from Kaarthik', txnAt: DateTime(2026, 11, 5), since: since), isFalse);
  });
}
