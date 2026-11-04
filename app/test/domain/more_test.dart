import 'package:flutter_test/flutter_test.dart';
import 'package:tick/data/demo_seed.dart';
import 'package:tick/data/ledger.dart';
import 'package:tick/domain/flows.dart';
import 'package:tick/domain/models.dart';
import 'package:tick/domain/notification_plan.dart';
import 'package:tick/domain/payday.dart';
import 'package:tick/domain/receipt.dart';
import 'package:tick/domain/safe_to_spend.dart';
import 'package:tick/features/nudges.dart';
import 'package:tick/services/widget_sync.dart';
import '../golden_harness.dart';

void main() {
  final now = fixedNow;
  final demo = buildDemo(now);
  final sts = computeSafeToSpend(today: dayOnly(now), rule: demo.rule, accounts: demo.accounts, recurring: demo.recurring, goals: demo.goals);

  test('demo safe to spend matches the design: \$214', () {
    expect(sts.cents, 21400);
    expect(sts.billsCents, 6400);
    expect(sts.nextPayday, DateTime(2026, 11, 6));
  });

  test('receipt is yesterday only, sorted by size, folds extras', () {
    final r = buildReceipt(demo.txns, now, maxLines: 3);
    expect(r.captures, 5);
    expect(r.lines.first.merchant, 'Whole Foods');
    expect(r.moreCount, 2);
    expect(r.totalCents, 4218 + 2200 + 1385 + 1940 + 1099);
    expect(fallbackAdvice(r, 21400, 2), contains('\$'));
    expect(fallbackAdvice(buildReceipt(const [], now), 100, 1), 'Quiet day. Your wallet says thanks.');
    expect(fallbackAdvice(r, -5, 1), contains('ahead'));
  });

  test('flows: transfers ignored, business total, vs last month', () {
    final txns = [
      Txn(id: '1', amountCents: -10000, occurredAt: DateTime(2026, 11, 2), merchant: 'A', categoryId: 'cat-groceries'),
      Txn(id: '2', amountCents: -5000, occurredAt: DateTime(2026, 11, 3), merchant: 'Cursor', categoryId: 'cat-software', tags: const ['business']),
      Txn(id: '3', amountCents: -99900, occurredAt: DateTime(2026, 11, 3), merchant: 'To savings', categoryId: 'cat-transfer'),
      Txn(id: '4', amountCents: 200000, occurredAt: DateTime(2026, 11, 1), merchant: 'Payroll', categoryId: 'cat-income'),
      Txn(id: '5', amountCents: -7500, occurredAt: DateTime(2026, 10, 2), merchant: 'B', categoryId: 'cat-groceries'),
    ];
    final f = computeFlows(txns, DateTime(2026, 11, 4));
    expect(f.inCents, 200000);
    expect(f.outCents, 15000);
    expect(f.netCents, 185000);
    expect(f.businessCents, 5000);
    expect(f.byCategory['cat-groceries'], 10000);
    expect(f.vsLast, closeTo(1.0, 0.001)); // 15000 vs 7500
    expect(daysInMonth(DateTime(2026, 2, 10)), 28);
    expect(firstWeekdaySunday0(DateTime(2026, 11, 20)), 0); // Nov 1 2026 is a Sunday
  });

  test('nudges: one at a time, in priority order', () {
    final l = LedgerState(categories: demo.categories, accounts: demo.accounts, txns: demo.txns, recurring: demo.recurring, expected: demo.expected, goals: demo.goals);
    final n = pickNudge(l, sts, now)!;
    expect(n.kind, 'bill');
    expect(n.title, contains('Internet'));
    final relink = pickNudge(l.copyWith(connections: const [Connection(id: 'c', institution: 'Chase', status: 'login_required')]), sts, now)!;
    expect(relink.kind, 'relink');
    expect(relink.title, 'Your Chase link needs a quick sign-in to keep syncing.');
    final over = computeSafeToSpend(today: dayOnly(now), rule: demo.rule, accounts: const [Account(id: 'a', name: 'C', availableCents: 1000)], recurring: demo.recurring, goals: demo.goals);
    expect(pickNudge(l, over, now)!.urgent, isTrue);
    expect(pickNudge(const LedgerState(), null, now), isNull);
  });

  test('duplicate subscription charge nudge', () {
    final l = LedgerState(txns: [
      Txn(id: 'a', amountCents: -1299, occurredAt: now, merchant: 'Spotify', categoryId: 'cat-subscriptions'),
      Txn(id: 'b', amountCents: -1299, occurredAt: now.subtract(const Duration(days: 1)), merchant: 'Spotify', categoryId: 'cat-subscriptions'),
    ]);
    expect(pickNudge(l, null, now)!.kind, 'duplicate');
  });

  test('notification plan: morning, bill-the-day-before, payday, weekly', () {
    final plan = planNotifications(now: now, morningTime: '08:00', weeklyTime: '19:00', sts: sts, recurring: demo.recurring, goals: demo.goals);
    expect(plan.where((p) => p.title == 'Good morning').length, 6); // today 8:00 already passed
    expect(plan.firstWhere((p) => p.title == 'Good morning').body, contains('\$214 safe to spend until Friday'));
    expect(plan.any((p) => p.title == 'Due tomorrow: Rent'), isTrue);
    expect(plan.firstWhere((p) => p.title == 'Payday').body, contains('Move \$400 to savings'));
    expect(plan.firstWhere((p) => p.repeatWeekly).when.weekday, DateTime.sunday);
    expect(plan.every((p) => p.when.isAfter(now)), isTrue);
    final ids = plan.map((p) => p.id).toList();
    expect(ids.toSet().length, ids.length);
  });

  test('widget snapshot', () {
    final s = buildWidgetSnapshot(sts: sts, txns: demo.txns, recurring: demo.recurring, now: now);
    expect(s['safeCents'], 21400);
    expect(s['until'], 'Friday');
    expect(s['spentTodayCents'], 1840 + 575);
    expect(s['nextBillName'], 'Internet');
    expect(s['nextBillDay'], 'tomorrow');
    expect(buildWidgetSnapshot(sts: null, txns: const [], recurring: const [], now: now)['hasData'], isFalse);
  });

  test('ledger notifier: add, business suggestion, caught resolution', () async {
    final c = await demoContainer();
    addTearDown(c.dispose);
    final n = c.read(ledgerProvider.notifier);
    final t = await n.add(amountCents: -1500, merchant: 'Namecheap');
    expect(t.tags, contains('business'));
    expect(c.read(ledgerProvider).txns.first.id, t.id);
    final inc = await n.add(amountCents: 4000, merchant: 'Alex');
    expect(inc.categoryId, 'cat-income');
    final review = c.read(ledgerProvider).needsReview.length;
    await n.markLooksRight(c.read(ledgerProvider).needsReview.first.id);
    expect(c.read(ledgerProvider).needsReview.length, review - 1);
    final uber = c.read(ledgerProvider).needsReview.first;
    await n.toggleBusiness(uber.id);
    expect(c.read(ledgerProvider).txns.firstWhere((x) => x.id == uber.id).isBusiness, isTrue);
    expect(c.read(ledgerProvider).txns.firstWhere((x) => x.id == uber.id).needsReview, isFalse);
  });
}
