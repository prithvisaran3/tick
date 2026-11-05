// The Dart money rules (demo mode) must give the same numbers as the server's tick_flows on the same fixture.
// Fixture and expected numbers: supabase/tests/flows.sql. Keep the two in sync.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tick/data/activity.dart';
import 'package:tick/data/ledger.dart';
import 'package:tick/domain/flows.dart';
import 'package:tick/domain/models.dart';

const cats = [
  Category(id: 'inc', name: 'Income', colorKey: 'inc', kind: 'income'),
  Category(id: 'gro', name: 'Groceries', colorKey: 'food'),
  Category(id: 'tr', name: 'Transfer', colorKey: 'shop', kind: 'transfer'),
  Category(id: 'loan', name: 'Loan payment', colorKey: 'home'),
  Category(id: 'fee', name: 'Fees and interest', colorKey: 'shop'),
  Category(id: 'cof', name: 'Coffee', colorKey: 'food'),
  Category(id: 'sw', name: 'Software', colorKey: 'biz'),
];
const accts = [
  Account(id: 'chk', name: 'Chase checking', type: 'checking', mask: '1173'),
  Account(id: 'disc', name: 'Discover it', type: 'credit', mask: '1234', institution: 'Discover'),
  Account(id: 'loanA', name: 'Student loan', type: 'loan', mask: '9001', institution: 'SoFi'),
];
Txn tx(String id, String acct, int cents, String utc, String m, String cat, {String? flow, List<String> tags = const []}) =>
    Txn(id: id, accountId: acct, amountCents: cents, occurredAt: DateTime.parse(utc).toLocal(), merchant: m, categoryId: cat, flow: flow, tags: tags);

final fixture = [
  tx('01', 'chk', 200000, '2026-11-14T15:00:00Z', 'Payroll', 'inc'),
  tx('02', 'disc', -5000, '2026-11-03T18:00:00Z', "Trader Joe's", 'gro'),
  tx('03', 'disc', 1000, '2026-11-05T18:00:00Z', "Trader Joe's", 'gro'),
  tx('04', 'chk', -30000, '2026-11-20T15:00:00Z', 'Discover payment', 'tr', flow: 'transfer'),
  tx('05', 'disc', 30000, '2026-11-21T15:00:00Z', 'Payment received', 'tr', flow: 'transfer'),
  tx('06', 'chk', -40000, '2026-11-10T15:00:00Z', 'SoFi loan', 'loan', flow: 'bill'),
  tx('07', 'loanA', 40000, '2026-11-11T15:00:00Z', 'Payment received', 'tr', flow: 'transfer'),
  tx('08', 'disc', -3500, '2026-11-25T15:00:00Z', 'Interest charge', 'fee'),
  tx('09', 'chk', -2000, '2026-12-01T04:30:00Z', 'Blue Bottle', 'cof'),
  tx('10', 'chk', -999, '2026-11-01T03:00:00Z', 'Late snack', 'cof'),
  tx('11', 'disc', -1500, '2026-11-12T15:00:00Z', 'Cursor', 'sw', tags: ['business']),
];

void main() {
  final l = LedgerState(categories: cats, accounts: accts, txns: fixture);
  final src = LocalActivitySource(l);
  const all = ActivityQuery();
  Future<Totals> nov(ActivityQuery q) => src.totals(q, from: etToUtc(DateTime(2026, 11)), to: etToUtc(DateTime(2026, 12)));

  test('New York month bounds do not depend on the phone time zone', () {
    expect(etToUtc(DateTime(2026, 11, 1)), DateTime.utc(2026, 11, 1, 4));   // EDT until Nov 1 02:00
    expect(etToUtc(DateTime(2026, 12, 1)), DateTime.utc(2026, 12, 1, 5));   // EST
    expect(etToUtc(DateTime(2026, 3, 8, 1)), DateTime.utc(2026, 3, 8, 6));  // before the March change
    expect(etToUtc(DateTime(2026, 3, 8, 3)), DateTime.utc(2026, 3, 8, 7));  // after it
    expect(etDay(DateTime.utc(2026, 12, 1, 4, 30)), DateTime(2026, 11, 30)); // 11:30 pm Nov 30 in New York
    expect(utcToEt(DateTime.utc(2026, 7, 4, 16)), DateTime(2026, 7, 4, 12));
  });

  test('November totals match supabase/tests/flows.sql', () async {
    final t = await nov(all);
    expect((t.inCents, t.outCents, t.netCents, t.businessCents, t.billsCents), (200000, 51000, 149000, 1500, 40000));
    expect(t.byCategory['gro'], 4000);                       // card refund lowers groceries
    expect(t.byCategory.containsKey('tr'), isFalse);          // transfers never appear as spending
  });

  test('filters match the SQL filter', () async {
    final credit = await nov(all.copyWith(types: {'credit'}));
    expect((credit.outCents, credit.inCents), (9000, 0));
    final chk = await nov(all.copyWith(accounts: {'chk'}));
    expect((chk.outCents, chk.inCents), (42000, 200000));
    final s = await nov(all.copyWith(query: 'trader'));
    expect((s.outCents, s.count), (4000, 2));
    expect((await nov(all.copyWith(query: 'groc'))).count, 2);
    expect((await src.totals(const ActivityQuery())).outCents, 51999);
    final months = await src.months(const ActivityQuery());
    expect(months.length, 2);
    expect(months.first.totals.outCents, 51000);
  });

  test('keyset pages cover every row exactly once, newest first', () async {
    final seen = <String>[];
    DateTime? at;
    String? id;
    while (true) {
      final p = await src.page(all.copyWith(upTo: DateTime(2026, 11)), beforeAt: at, beforeId: id, limit: 3);
      if (p.rows.isEmpty) break;
      seen.addAll(p.rows.map((t) => t.id));
      at = p.rows.last.occurredAt;
      id = p.rows.last.id;
    }
    expect(seen.length, 11);                                   // 10 in November plus the Oct 30 (New York) row that precedes it
    expect(seen.toSet().length, 11);
    expect(seen.first, '09');
  });

  test('server arguments: empty filters are null, month becomes New York bounds', () {
    final a = ActivityQuery(upTo: DateTime(2026, 11), types: const {'credit'}, query: '  uber ').rpcArgs(from: etToUtc(DateTime(2026, 11)));
    expect(a['p_from'], '2026-11-01T04:00:00.000Z');
    expect(a['p_to'], '2026-12-01T05:00:00.000Z');
    expect(a['p_types'], ['credit']);
    expect(a['p_accounts'], isNull);
    expect(a['p_query'], 'uber');
    expect(const ActivityQuery().rpcArgs()['p_from'], isNull);
  });

  test('Activity notifier pages 40 at a time and keeps the query', () async {
    final many = [for (var i = 0; i < 95; i++) Txn(id: 'r${i.toString().padLeft(3, '0')}', amountCents: -100, occurredAt: DateTime(2026, 11, 20).subtract(Duration(hours: i)), merchant: 'M$i', categoryId: 'gro')];
    final c = ProviderContainer(overrides: [
      activitySourceProvider.overrideWithValue(LocalActivitySource(LedgerState(categories: cats, txns: many))),
      clockProvider.overrideWithValue(() => DateTime(2026, 11, 20, 12)),
    ]);
    addTearDown(c.dispose);
    c.read(activityProvider);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(c.read(activityProvider).rows.length, 40);
    expect(c.read(activityProvider).hasMore, isTrue);
    await c.read(activityProvider.notifier).loadMore();
    await c.read(activityProvider.notifier).loadMore();
    final s = c.read(activityProvider);
    expect(s.rows.length, 95);
    expect(s.rows.map((t) => t.id).toSet().length, 95);
    expect(s.hasMore, isFalse);
    expect(s.totals?.outCents, 9500);
  });
}
