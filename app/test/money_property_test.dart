// Property: whatever the filters, a day's header total equals the sum of the rows listed under it, and the month total equals the sum
// of its days. Random but seeded ledgers (cards, refunds, transfers, Zelle both ways, loan bills, Tally settlements).
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:tick/data/activity.dart';
import 'package:tick/data/ledger.dart';
import 'package:tick/domain/flows.dart';
import 'package:tick/domain/models.dart';

const cats = [
  Category(id: 'inc', name: 'Income', colorKey: 'inc', kind: 'income'),
  Category(id: 'gro', name: 'Groceries', colorKey: 'food'),
  Category(id: 'tr', name: 'Transfer', colorKey: 'shop', kind: 'transfer'),
  Category(id: 'ff', name: 'Friends and family', colorKey: 'shop'),
  Category(id: 'loan', name: 'Loan payment', colorKey: 'home'),
];
const accts = [
  Account(id: 'chk', name: 'Chase', type: 'checking'),
  Account(id: 'sav', name: 'SoFi Savings', type: 'savings'),
  Account(id: 'cc', name: 'Discover', type: 'credit'),
  Account(id: 'ln', name: 'Student loan', type: 'loan'),
];

List<Txn> randomLedger(int seed, int n) {
  final r = Random(seed);
  final out = <Txn>[];
  for (var i = 0; i < n; i++) {
    final acct = accts[r.nextInt(accts.length)];
    final cents = (r.nextInt(30000) + 1) * (r.nextBool() ? -1 : 1);
    final flow = const [null, null, null, null, 'transfer', 'bill', 'settlement'][r.nextInt(7)];
    out.add(Txn(
      id: 't${i.toString().padLeft(4, '0')}', amountCents: cents, accountId: acct.id, flow: flow,
      categoryId: ['inc', 'gro', 'tr', 'ff', 'loan'][r.nextInt(5)],
      merchant: ['Zelle to Kaarthik', 'Trader Joes', 'Payroll', 'Discover payment'][r.nextInt(4)],
      occurredAt: DateTime.utc(2026, 8 + r.nextInt(4), 1 + r.nextInt(28), r.nextInt(24), r.nextInt(60)).toLocal(),
      tags: r.nextInt(6) == 0 ? const ['business'] : const [],
    ));
  }
  return out;
}

void main() {
  final cmap = {for (final c in cats) c.id: c};
  final amap = {for (final a in accts) a.id: a};
  int net(Iterable<Txn> ts) => ts.fold(0, (s, t) => s + inOf(t, cats: cmap, accounts: amap) - outOf(t, cats: cmap, accounts: amap));

  for (final seed in [1, 7, 42, 99, 2026]) {
    test('day and month totals equal the visible rows under random filters (seed $seed)', () async {
      final l = LedgerState(categories: cats, accounts: accts, txns: randomLedger(seed, 400));
      final src = LocalActivitySource(l);
      final r = Random(seed);
      for (var f = 0; f < 12; f++) {
        final q = ActivityQuery(
          types: {if (r.nextBool()) 'credit', if (r.nextInt(3) == 0) 'checking'},
          accounts: r.nextInt(4) == 0 ? {'chk'} : {},
          categories: r.nextInt(5) == 0 ? {'gro'} : {},
          query: r.nextInt(5) == 0 ? 'zelle' : '',
          business: r.nextInt(8) == 0,
        );
        final rows = <Txn>[];
        final days = <DateTime, int>{};
        DateTime? at;
        String? id;
        while (true) {
          final p = await src.page(q, beforeAt: at, beforeId: id, limit: 25);
          if (p.rows.isEmpty) break;
          rows.addAll(p.rows);
          days.addAll(p.dayTotals);
          at = p.rows.last.occurredAt;
          id = p.rows.last.id;
        }
        for (final e in days.entries) {
          expect(e.value, net(rows.where((t) => etDay(t.occurredAt) == e.key)), reason: 'day ${e.key} under filter $f');
        }
        final total = await src.totals(q);
        expect(total.netCents, net(rows), reason: 'month/all-time total under filter $f');
        expect(total.count, rows.length);
        expect(days.values.fold(0, (s, v) => s + v), net(rows));
      }
    });
  }

  test('Zelle to a friend is real money: it shows in the day total (it used to show zero)', () async {
    final t = Txn(id: 'z', amountCents: -51146, accountId: 'chk', categoryId: 'ff', merchant: 'Zelle payment to Kaarthik', occurredAt: DateTime(2026, 11, 1, 12));
    final src = LocalActivitySource(LedgerState(categories: cats, accounts: accts, txns: [t]));
    final p = await src.page(const ActivityQuery());
    expect(p.dayTotals.values.single, -51146);
    expect((await src.totals(const ActivityQuery())).outCents, 51146);
  });

  test('both sides of an internal transfer are excluded; Tally settlements too; a card refund lowers spending', () async {
    final ts = [
      Txn(id: '1', amountCents: 120000, accountId: 'chk', categoryId: 'tr', merchant: 'SoFi', occurredAt: DateTime(2026, 11, 2), flow: 'transfer'),
      Txn(id: '2', amountCents: -120000, accountId: 'sav', categoryId: 'tr', merchant: 'Chase', occurredAt: DateTime(2026, 11, 2), flow: 'transfer'),
      Txn(id: '3', amountCents: -5000, accountId: 'cc', categoryId: 'gro', merchant: 'Trader Joes', occurredAt: DateTime(2026, 11, 3)),
      Txn(id: '4', amountCents: 1000, accountId: 'cc', categoryId: 'gro', merchant: 'Trader Joes refund', occurredAt: DateTime(2026, 11, 4)),
      Txn(id: '5', amountCents: 7000, accountId: 'chk', categoryId: 'ff', merchant: 'Zelle from Sam', occurredAt: DateTime(2026, 11, 5), flow: 'settlement'),
    ];
    final t = await LocalActivitySource(LedgerState(categories: cats, accounts: accts, txns: ts)).totals(const ActivityQuery());
    expect((t.inCents, t.outCents), (0, 4000));
  });
}
