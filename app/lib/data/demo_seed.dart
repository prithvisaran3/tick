import 'dart:math';
import '../domain/models.dart';
import '../domain/payday.dart';

/// Realistic seed for a remote software engineer in Arlington, VA. Deterministic; dates relative to [now].
class DemoData {
  DemoData({required this.categories, required this.accounts, required this.txns, required this.recurring, required this.expected, required this.goals, required this.rule});
  final List<Category> categories;
  final List<Account> accounts;
  final List<Txn> txns;
  final List<Recurring> recurring;
  final List<Expected> expected;
  final List<Goal> goals;
  final PaydayRule rule;
}

const defaultCategories = [
  Category(id: 'cat-groceries', name: 'Groceries', colorKey: 'food', icon: 'receipt'),
  Category(id: 'cat-restaurants', name: 'Restaurants', colorKey: 'food', icon: 'receipt'),
  Category(id: 'cat-coffee', name: 'Coffee', colorKey: 'food', icon: 'receipt'),
  Category(id: 'cat-rideshare', name: 'Rideshare', colorKey: 'ride', icon: 'arrow-out'),
  Category(id: 'cat-travel', name: 'Travel', colorKey: 'ride', icon: 'arrow-out'),
  Category(id: 'cat-shopping', name: 'Shopping', colorKey: 'shop', icon: 'card'),
  Category(id: 'cat-subscriptions', name: 'Subscriptions', colorKey: 'sub', icon: 'repeat'),
  Category(id: 'cat-software', name: 'Software', colorKey: 'biz', icon: 'briefcase'),
  Category(id: 'cat-rent', name: 'Rent', colorKey: 'home', icon: 'bank'),
  Category(id: 'cat-utilities', name: 'Utilities', colorKey: 'home', icon: 'bank'),
  Category(id: 'cat-phone', name: 'Phone and internet', colorKey: 'home', icon: 'bank'),
  Category(id: 'cat-health', name: 'Health', colorKey: 'shop', icon: 'goal'),
  Category(id: 'cat-fun', name: 'Fun', colorKey: 'shop', icon: 'card'),
  Category(id: 'cat-transfer', name: 'Transfer', colorKey: 'shop', icon: 'repeat', kind: 'transfer'),
  Category(id: 'cat-income', name: 'Income', colorKey: 'inc', icon: 'arrow-in', kind: 'income'),
  Category(id: 'cat-other', name: 'Other', colorKey: 'shop', icon: 'card'),
];

DemoData buildDemo(DateTime now) {
  final today = dayOnly(now);
  DateTime at(int daysAgo, int h, int m) => today.subtract(Duration(days: daysAgo)).add(Duration(hours: h, minutes: m));
  var n = 0;
  Txn t(int daysAgo, int h, int m, String merchant, int cents, String cat, {String src = 'plaid', String acct = 'acc-chk', double conf = 1, bool review = false, List<String> tags = const []}) =>
      Txn(id: 'demo-${n++}', amountCents: cents, occurredAt: at(daysAgo, h, m), merchant: merchant, categoryId: cat, accountId: acct, source: src, confidence: conf, needsReview: review, tags: tags);

  final txns = <Txn>[
    // Today
    t(0, 9, 12, 'Uber', -1840, 'cat-rideshare', src: 'applepay', conf: 0.72, review: true),
    t(0, 7, 41, 'Blue Bottle', -575, 'cat-coffee'),
    // Yesterday (the Morning Receipt)
    t(1, 18, 20, 'Whole Foods', -4218, 'cat-groceries'),
    t(1, 14, 5, 'Cursor', -2200, 'cat-software', tags: const ['business']),
    t(1, 12, 31, 'Chipotle', -1385, 'cat-restaurants', acct: 'acc-card'),
    t(1, 10, 2, "Trader Joe's", -1940, 'cat-groceries'),
    t(1, 6, 0, 'Spotify', -1099, 'cat-subscriptions', acct: 'acc-card'),
    // Needs-review pair for Caught
    t(2, 21, 8, 'AMZN Mktp US*2K4', -2999, 'cat-shopping', src: 'sms', conf: 0.55, review: true),
    t(3, 13, 44, 'SQ *BLUEBIRD', -1260, 'cat-coffee', src: 'sms', conf: 0.66, review: true),
    // Last payday
    Txn(id: 'demo-pay1', amountCents: 231000, occurredAt: at(12, 6, 0), merchant: 'Payroll', categoryId: 'cat-income', accountId: 'acc-chk', source: 'plaid'),
  ];
  final rnd = Random(42);
  const pool = [
    ('Whole Foods', 'cat-groceries', 3800, 6500), ("Trader Joe's", 'cat-groceries', 2200, 4800), ('Chipotle', 'cat-restaurants', 1250, 1650),
    ('Blue Bottle', 'cat-coffee', 450, 700), ('Uber', 'cat-rideshare', 1100, 3200), ('Sweetgreen', 'cat-restaurants', 1400, 1900),
    ('Cursor', 'cat-software', 2000, 2200), ('Amazon', 'cat-shopping', 1800, 7200), ('CVS', 'cat-health', 900, 2600),
  ];
  for (var d = 4; d <= 62; d++) {
    if (rnd.nextDouble() < 0.18) continue;
    for (var k = 0; k < 1 + rnd.nextInt(2); k++) {
      final p = pool[rnd.nextInt(pool.length)];
      final cents = p.$3 + rnd.nextInt(p.$4 - p.$3);
      txns.add(t(d, 8 + rnd.nextInt(12), rnd.nextInt(60), p.$1, -cents, p.$2, tags: p.$1 == 'Cursor' ? const ['business'] : const []));
    }
  }
  for (var m = 0; m < 3; m++) {
    final base = DateTime(today.year, today.month - m, 1);
    final dAgo = today.difference(base.add(const Duration(days: 0))).inDays;
    if (dAgo >= 4) txns.add(t(dAgo, 6, 0, 'Rent', -185000, 'cat-rent'));
    if (dAgo + 8 >= 4) txns.add(t(dAgo + 8, 6, 0, 'Comcast Internet', -6400, 'cat-phone'));
    if (dAgo + 14 >= 4) txns.add(t(dAgo + 14, 6, 0, 'Claude', -1800, 'cat-software', tags: const ['business']));
  }
  for (final k in [26, 40, 54]) {
    txns.add(Txn(id: 'demo-pay$k', amountCents: 231000, occurredAt: at(k, 6, 0), merchant: 'Payroll', categoryId: 'cat-income', accountId: 'acc-chk', source: 'plaid'));
  }
  txns.sort((a, b) => b.occurredAt.compareTo(a.occurredAt));

  // Next Friday strictly after today.
  var next = today.add(const Duration(days: 1));
  while (next.weekday != DateTime.friday) { next = next.add(const Duration(days: 1)); }
  final rule = PaydayRule(frequency: PayFrequency.biweekly, anchor: next, amountCents: 231000);

  final recurring = [
    Recurring(id: 'r-internet', merchant: 'Internet', cadence: Cadence.monthly, expectedCents: 6400, nextDate: today.add(const Duration(days: 1)), categoryId: 'cat-phone', priceHistory: const [6400, 6400]),
    Recurring(id: 'r-rent', merchant: 'Rent', cadence: Cadence.monthly, expectedCents: 185000, nextDate: today.add(const Duration(days: 5)), categoryId: 'cat-rent', priceHistory: const [185000]),
    Recurring(id: 'r-claude', merchant: 'Claude', cadence: Cadence.monthly, expectedCents: 2000, nextDate: today.add(const Duration(days: 9)), categoryId: 'cat-software', priceHistory: const [1800, 2000]),
    Recurring(id: 'r-cursor', merchant: 'Cursor', cadence: Cadence.monthly, expectedCents: 2200, nextDate: today.add(const Duration(days: 12)), categoryId: 'cat-software', priceHistory: const [2000, 2200]),
    Recurring(id: 'r-phone', merchant: 'Phone', cadence: Cadence.monthly, expectedCents: 5500, nextDate: today.add(const Duration(days: 15)), categoryId: 'cat-phone', priceHistory: const [5500]),
    Recurring(id: 'r-spotify', merchant: 'Spotify', cadence: Cadence.monthly, expectedCents: 1099, nextDate: today.add(const Duration(days: 28)), categoryId: 'cat-subscriptions', priceHistory: const [1099]),
    Recurring(id: 'r-apple', merchant: 'Apple Developer', cadence: Cadence.yearly, expectedCents: 9900, nextDate: today.add(const Duration(days: 140)), categoryId: 'cat-software', priceHistory: const [9900]),
  ];
  return DemoData(
    categories: defaultCategories,
    accounts: const [
      Account(id: 'acc-chk', name: 'Chase Checking', mask: '1180', type: 'checking', balanceCents: 67800, availableCents: 67800),
      Account(id: 'acc-card', name: 'Apple Card', mask: '4421', type: 'credit', balanceCents: 0),
      Account(id: 'acc-sav', name: 'Savings', mask: '9921', type: 'savings', balanceCents: 840000, availableCents: 840000, includeInSafe: false),
    ],
    txns: txns,
    recurring: recurring,
    expected: [
      Expected(id: 'e-pay', kind: ExpectedKind.paycheck, label: 'Payroll', amountCents: 231000, date: next),
      Expected(id: 'e-refund', kind: ExpectedKind.refund, label: 'Amazon refund', amountCents: 2400, date: today.add(const Duration(days: 4))),
      Expected(id: 'e-iou', kind: ExpectedKind.iou, label: 'Alex owes you', amountCents: 4000, date: today.add(const Duration(days: 7))),
    ],
    goals: const [Goal(id: 'g1', name: 'Savings', targetCents: 1000000, savedCents: 840000, perPaydayCents: 40000)],
    rule: rule,
  );
}
