import 'package:flutter_test/flutter_test.dart';
import 'package:tick/data/demo_seed.dart';
import 'package:tick/data/ledger.dart';
import 'package:tick/domain/budget_plan.dart';
import 'package:tick/domain/calendar.dart';
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
  budgetAndPlanTests();
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
      Txn(id: '3', amountCents: -99900, occurredAt: DateTime(2026, 11, 3), merchant: 'To savings', categoryId: 'cat-transfer', flow: 'transfer'),
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
    final l = LedgerState(categories: defaultCategories, txns: [
      Txn(id: 'a', amountCents: -1299, occurredAt: now, merchant: 'Spotify', categoryId: 'cat-subscriptions'),
      Txn(id: 'b', amountCents: -1299, occurredAt: now.subtract(const Duration(days: 1)), merchant: 'Spotify', categoryId: 'cat-subscriptions'),
    ]);
    expect(pickNudge(l, null, now)!.kind, 'duplicate');
  });

  test('nudges fire on LIVE data: categories are uuids, matched by name', () {
    const subs = Category(id: '5b0c1d2e-0000-4000-8000-000000000001', name: 'Subscriptions', colorKey: 'sub', icon: 'repeat');
    final l = LedgerState(categories: const [subs], txns: [
      Txn(id: 'a', amountCents: -1299, occurredAt: now, merchant: 'Spotify', categoryId: subs.id),
      Txn(id: 'b', amountCents: -1299, occurredAt: now.subtract(const Duration(days: 1)), merchant: 'Spotify', categoryId: subs.id),
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

void budgetAndPlanTests() {
  final now = fixedNow;
  final demo = buildDemo(now);
  test('budget pace: calm, warm, hot, over', () {
    final mid = DateTime(2026, 11, 15);
    expect(budgetPace(spentCents: 10000, capCents: 40000, now: mid).state, PaceState.calm);
    expect(budgetPace(spentCents: 19000, capCents: 40000, now: mid).state, PaceState.warm);
    final hot = budgetPace(spentCents: 30000, capCents: 40000, now: mid);
    expect(hot.state, PaceState.hot);
    expect(hot.projectedCents, 60000);
    expect(hot.line, 'Running hot: on pace for \$600 vs your \$400.');
    expect(budgetPace(spentCents: 45000, capCents: 40000, now: mid).line, 'Over by \$50.');
    expect(budgetPace(spentCents: 0, capCents: 40000, now: DateTime(2026, 11, 1)).paceFraction, closeTo(1 / 30, 0.001));
    final early = budgetPace(spentCents: 30000, capCents: 40000, now: DateTime(2026, 11, 4));
    expect(early.state, PaceState.calm);
    expect(early.line, r'$100 left this month.');
  });


  test('goal progress clamps', () {
    expect(goalProgress(const Goal(id: 'g', name: 'x', targetCents: 100, savedCents: 150, perPaydayCents: 0)), 1.0);
    expect(goalProgress(const Goal(id: 'g', name: 'x', targetCents: 0, savedCents: 0, perPaydayCents: 0)), 0);
  });

  test('payday plan: move to savings and what is left safe', () {
    final rule = PaydayRule(frequency: PayFrequency.biweekly, anchor: DateTime(2026, 11, 6), amountCents: 231000);
    final accounts = [const Account(id: 'a', name: 'Chase Checking', mask: '1180', availableCents: 67800 + 231000)];
    final plan = buildPaydayPlan(today: DateTime(2026, 11, 6), rule: rule, accounts: accounts, recurring: demo.recurring, goals: demo.goals, paycheckLanded: true);
    expect(plan.nextPayday, DateTime(2026, 11, 20));
    expect(plan.moveCents, 40000);                       // only goals that move money and are not full
    expect(plan.billsCents, 185000 + 6400 + 2000 + 2200 + 5500 > 0 ? plan.billsCents : 0);
    expect(plan.safeAfterCents, 67800 + 231000 - plan.billsCents - 40000);
    expect(plan.headline, startsWith('Payday. Move \$400 to savings and you still have '));
    final notLanded = buildPaydayPlan(today: DateTime(2026, 11, 6), rule: rule, accounts: [const Account(id: 'a', name: 'C', availableCents: 67800)], recurring: const [], goals: const [], paycheckLanded: false);
    expect(notLanded.safeAfterCents, 67800 + 231000);
    expect(notLanded.headline, contains('safe to spend until Friday'));
    expect(isPaydayWindow(rule, DateTime(2026, 11, 5)), isTrue);
    expect(isPaydayWindow(rule, DateTime(2026, 11, 7)), isFalse);
  });

  test('calendar grid and short account labels', () {
    final cells = monthCells(DateTime(2026, 11, 10));
    expect(cells.where((c) => c == null).length, 0);          // Nov 1 2026 is a Sunday
    expect(cells.length, 30);
    expect(monthCells(DateTime(2026, 12, 1)).where((c) => c == null).length, 2);
    expect(addMonths(DateTime(2026, 12, 15), 1), DateTime(2027, 1, 1));
    expect(const Account(id: 'a', name: 'Chase Checking', mask: '1180').shortLabel, 'Chase ••1180');
    expect(const Account(id: 'a', name: 'Cash').shortLabel, 'Cash');
  });

  test('move to savings adds goal progress and one transfer', () async {
    final c = await demoContainer();
    addTearDown(c.dispose);
    final n = c.read(ledgerProvider.notifier);
    final before = c.read(ledgerProvider).goals.firstWhere((g) => g.id == 'g1').savedCents;
    final count = c.read(ledgerProvider).txns.length;
    await n.movePaydayToSavings(c.read(ledgerProvider).goals.where((g) => g.perPaydayCents > 0).toList());
    expect(c.read(ledgerProvider).goals.firstWhere((g) => g.id == 'g1').savedCents, before + 40000);
    expect(c.read(ledgerProvider).txns.length, count + 1);
    expect(c.read(ledgerProvider).txns.first.categoryId, 'cat-transfer');
    expect(c.read(ledgerProvider).txns.first.amountCents, -40000);
  });

  test('budget and goal CRUD in the notifier', () async {
    final c = await demoContainer();
    addTearDown(c.dispose);
    final n = c.read(ledgerProvider.notifier);
    await n.saveBudget('cat-fun', 12000);
    expect(c.read(ledgerProvider).budgets.any((b) => b.categoryId == 'cat-fun' && b.capCents == 12000), isTrue);
    await n.saveBudget('cat-fun', 9000);                           // edit replaces, never duplicates
    expect(c.read(ledgerProvider).budgets.where((b) => b.categoryId == 'cat-fun').length, 1);
    await n.deleteBudget(c.read(ledgerProvider).budgets.firstWhere((b) => b.categoryId == 'cat-fun').id);
    expect(c.read(ledgerProvider).budgets.any((b) => b.categoryId == 'cat-fun'), isFalse);
    await n.saveGoal(const Goal(id: 'local-g-1', name: 'Bike', targetCents: 50000, savedCents: 0, perPaydayCents: 5000));
    expect(c.read(ledgerProvider).goals.any((g) => g.name == 'Bike'), isTrue);
    await n.saveGoal(const Goal(id: 'local-g-1', name: 'Bike', targetCents: 60000, savedCents: 0, perPaydayCents: 5000));
    expect(c.read(ledgerProvider).goals.where((g) => g.name == 'Bike').single.targetCents, 60000);
    await n.deleteGoal('local-g-1');
    expect(c.read(ledgerProvider).goals.any((g) => g.name == 'Bike'), isFalse);
    await n.addCategory('Pets', 'shop');
    final pets = c.read(ledgerProvider).categories.firstWhere((x) => x.name == 'Pets');
    await n.renameCategory(pets.id, 'Pet care');
    expect(c.read(ledgerProvider).categories.any((x) => x.name == 'Pet care'), isTrue);
  });

  test('card due within 3 days is a gentle nudge and a reminder two days before; paid statements stay quiet', () {
    final now = DateTime(2026, 11, 10, 8);
    final disc = Account(id: 'd', name: 'Discover it', institution: 'Discover', mask: '1234', type: 'credit', balanceCents: -81240, statementBalanceCents: 64012, dueDate: DateTime(2026, 11, 13));
    final l = LedgerState(accounts: [disc]);
    final n = pickNudge(l, null, now)!;
    expect(n.kind, 'card');
    expect(n.title, r'Discover ••1234: $640 due Friday.');
    expect(n.route, '/card/d');
    final plan = planNotifications(now: now, morningTime: '08:00', weeklyTime: '19:00', sts: null, recurring: const [], goals: const [], accounts: [disc]);
    final card = plan.where((p) => p.payload == 'card:d').single;
    expect(card.when, DateTime(2026, 11, 11, 9));
    expect(card.body, isNot(contains('Pay now')));
    final paid = Account(id: 'p', name: 'Paid', type: 'credit', balanceCents: 0, statementBalanceCents: 0, dueDate: DateTime(2026, 11, 12));
    expect(pickNudge(LedgerState(accounts: [paid]), null, now), isNull);
  });
}
