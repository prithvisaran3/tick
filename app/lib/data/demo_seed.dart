import 'dart:math';
import '../domain/models.dart';
import '../domain/payday.dart';
import '../domain/dates.dart';

/// Realistic seed for a remote software engineer in Arlington, VA. Deterministic; dates relative to [now].
class DemoData {
  DemoData({this.connections = const [], required this.categories, required this.accounts, required this.txns, required this.recurring, required this.expected, required this.goals, required this.rule, this.budgets = const []});
  final List<Connection> connections;
  final List<Category> categories;
  final List<Account> accounts;
  final List<Txn> txns;
  final List<Recurring> recurring;
  final List<Expected> expected;
  final List<Goal> goals;
  final PaydayRule rule;
  final List<Budget> budgets;
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
  Category(id: 'cat-friends', name: 'Friends and family', colorKey: 'shop', icon: 'arrow-out'),
  Category(id: 'cat-splitwise', name: 'Splitwise', colorKey: 'shop', icon: 'tally'),
  Category(id: 'cat-loan', name: 'Loan payment', colorKey: 'home', icon: 'bank'),
  Category(id: 'cat-fees', name: 'Fees and interest', colorKey: 'shop', icon: 'card'),
  Category(id: 'cat-transfer', name: 'Transfer', colorKey: 'shop', icon: 'repeat', kind: 'transfer'),
  Category(id: 'cat-income', name: 'Income', colorKey: 'inc', icon: 'arrow-in', kind: 'income'),
  Category(id: 'cat-other', name: 'Other', colorKey: 'shop', icon: 'card'),
];

/// Demo payday rule without building the whole seed (it is read on every ledger change).
PaydayRule demoPaydayRule(DateTime now) {
  var next = addDays(dayOnly(now), 1);
  while (next.weekday != DateTime.friday) { next = addDays(next, 1); }
  return PaydayRule(frequency: PayFrequency.biweekly, anchor: next, amountCents: 231000);
}

DemoData buildDemo(DateTime now) {
  final today = dayOnly(now);
  DateTime at(int daysAgo, int h, int m) => addDays(today, -daysAgo).add(Duration(hours: h, minutes: m));
  var n = 0;
  Txn t(int daysAgo, int h, int m, String merchant, int cents, String cat, {String src = 'plaid', String acct = 'acc-disc', double conf = 1, bool review = false, List<String> tags = const [], String? flow}) =>
      Txn(id: 'demo-${n++}', amountCents: cents, occurredAt: at(daysAgo, h, m), merchant: merchant, categoryId: cat, accountId: acct, source: src, confidence: conf, needsReview: review, tags: tags, flow: flow);
  // Mostly card spending, paid from checking (the real setup).
  const cards = ['acc-disc', 'acc-disc', 'acc-boa', 'acc-savor', 'acc-savor', 'acc-card'];

  final txns = <Txn>[
    // Today
    t(0, 9, 12, 'Uber', -1840, 'cat-rideshare', src: 'applepay', conf: 0.72, review: true, acct: 'acc-card'),
    t(0, 7, 41, 'Blue Bottle', -575, 'cat-coffee', acct: 'acc-savor'),
    // Yesterday (the Morning Receipt)
    t(1, 18, 20, 'Whole Foods', -4218, 'cat-groceries', acct: 'acc-savor'),
    t(1, 14, 5, 'Cursor', -2200, 'cat-software', tags: const ['business'], acct: 'acc-boa'),
    t(1, 12, 31, 'Chipotle', -1385, 'cat-restaurants', acct: 'acc-card'),
    t(1, 10, 2, "Trader Joe's", -1940, 'cat-groceries'),
    t(1, 6, 0, 'Spotify', -1099, 'cat-subscriptions', acct: 'acc-card'),
    // Needs-review pair for Caught
    t(2, 21, 8, 'AMZN Mktp US*2K4', -2999, 'cat-shopping', src: 'sms', conf: 0.55, review: true),
    t(3, 13, 44, 'SQ *BLUEBIRD', -1260, 'cat-coffee', src: 'sms', conf: 0.66, review: true),
    // Last payday
    Txn(id: 'demo-pay1', amountCents: 231000, occurredAt: at(12, 6, 0), merchant: 'Payroll', categoryId: 'cat-income', accountId: 'acc-chk', source: 'plaid'),
    // Card payments from checking and the student loan: internal transfers, paired on both sides.
    t(9, 9, 0, 'Discover payment', -45000, 'cat-transfer', acct: 'acc-chk', flow: 'transfer'),
    t(8, 9, 0, 'Payment received', 45000, 'cat-transfer', acct: 'acc-disc', flow: 'transfer'),
    t(10, 9, 0, 'Capital One payment', -38000, 'cat-transfer', acct: 'acc-chk', flow: 'transfer'),
    t(9, 10, 0, 'Payment received', 38000, 'cat-transfer', acct: 'acc-savor', flow: 'transfer'),
    t(11, 9, 0, 'SoFi student loan', -40000, 'cat-loan', acct: 'acc-chk', flow: 'bill'),
    t(10, 11, 0, 'Payment received', 40000, 'cat-transfer', acct: 'acc-loan', flow: 'transfer'),
    t(14, 9, 0, 'Interest charge', -1236, 'cat-fees', acct: 'acc-boa'),
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
      txns.add(t(d, 8 + rnd.nextInt(12), rnd.nextInt(60), p.$1, -cents, p.$2, tags: p.$1 == 'Cursor' ? const ['business'] : const [], acct: cards[rnd.nextInt(cards.length)]));
    }
  }
  for (var m = 0; m < 3; m++) {
    final base = DateTime(today.year, today.month - m, 1);
    final dAgo = today.difference(addDays(base, 0)).inDays;
    if (dAgo >= 4) txns.add(t(dAgo, 6, 0, 'Rent', -185000, 'cat-rent', acct: 'acc-chk'));
    if (dAgo + 8 >= 4) txns.add(t(dAgo + 8, 6, 0, 'Comcast Internet', -6400, 'cat-phone', acct: 'acc-boa'));
    if (dAgo + 14 >= 4) txns.add(t(dAgo + 14, 6, 0, 'Claude', -1800, 'cat-software', tags: const ['business']));
  }
  for (final k in [26, 40, 54]) {
    txns.add(Txn(id: 'demo-pay$k', amountCents: 231000, occurredAt: at(k, 6, 0), merchant: 'Payroll', categoryId: 'cat-income', accountId: 'acc-chk', source: 'plaid'));
  }
  txns.sort((a, b) => b.occurredAt.compareTo(a.occurredAt));

  final rule = demoPaydayRule(now);
  final next = rule.anchor;

  final recurring = [
    Recurring(id: 'r-internet', merchant: 'Internet', cadence: Cadence.monthly, expectedCents: 6400, nextDate: addDays(today, 1), categoryId: 'cat-phone', priceHistory: const [6400, 6400]),
    Recurring(id: 'r-rent', merchant: 'Rent', cadence: Cadence.monthly, expectedCents: 185000, nextDate: addDays(today, 5), categoryId: 'cat-rent', priceHistory: const [185000]),
    Recurring(id: 'r-claude', merchant: 'Claude', cadence: Cadence.monthly, expectedCents: 2000, nextDate: addDays(today, 9), categoryId: 'cat-software', priceHistory: const [1800, 2000]),
    Recurring(id: 'r-cursor', merchant: 'Cursor', cadence: Cadence.monthly, expectedCents: 2200, nextDate: addDays(today, 12), categoryId: 'cat-software', priceHistory: const [2000, 2200]),
    Recurring(id: 'r-phone', merchant: 'Phone', cadence: Cadence.monthly, expectedCents: 5500, nextDate: addDays(today, 15), categoryId: 'cat-phone', priceHistory: const [5500]),
    Recurring(id: 'r-spotify', merchant: 'Spotify', cadence: Cadence.monthly, expectedCents: 1099, nextDate: addDays(today, 28), categoryId: 'cat-subscriptions', priceHistory: const [1099]),
    Recurring(id: 'r-apple', merchant: 'Apple Developer', cadence: Cadence.yearly, expectedCents: 9900, nextDate: addDays(today, 140), categoryId: 'cat-software', priceHistory: const [9900]),
  ];
  final connections = [
    Connection(id: 'c-chase', institution: 'Chase', status: 'active', syncState: 'ok', lastSyncedAt: now.subtract(const Duration(minutes: 5))),
    Connection(id: 'c-sofi', institution: 'SoFi', status: 'active', syncState: 'ok', lastSyncedAt: now.subtract(const Duration(minutes: 5))),
    Connection(id: 'c-disc', institution: 'Discover', status: 'active', syncState: 'ok', lastSyncedAt: now.subtract(const Duration(minutes: 12))),
    Connection(id: 'c-boa', institution: 'Bank of America', status: 'active', syncState: 'partial', lastSyncedAt: now.subtract(const Duration(hours: 3))),
    Connection(id: 'c-cap', institution: 'Capital One', status: 'active', syncState: 'syncing', syncStartedAt: now.subtract(const Duration(minutes: 2)), createdAt: now.subtract(const Duration(minutes: 2))),
  ];
  return DemoData(
    connections: connections,
    categories: defaultCategories,
    accounts: [
      const Account(id: 'acc-chk', connectionId: 'c-chase', name: 'Chase Checking', institution: 'Chase', mask: '1173', type: 'checking', balanceCents: 58140, availableCents: 58140),
      const Account(id: 'acc-sofi', connectionId: 'c-sofi', name: 'SoFi Checking', institution: 'SoFi', mask: '2210', type: 'checking', balanceCents: 41500, availableCents: 41500),
      const Account(id: 'acc-sav', connectionId: 'c-sofi', name: 'SoFi Savings', institution: 'SoFi', mask: '9921', type: 'savings', balanceCents: 840000, availableCents: 840000, includeInSafe: false),
      Account(id: 'acc-disc', connectionId: 'c-disc', name: 'Discover it', institution: 'Discover', mask: '1234', type: 'credit', balanceCents: -81240, creditLimitCents: 500000,
          statementBalanceCents: 64012, minimumPaymentCents: 3500, dueDate: addDays(today, 3), lastStatementDate: addDays(today, -22), aprBps: 2499),
      Account(id: 'acc-boa', connectionId: 'c-boa', name: 'Customized Cash Rewards', institution: 'Bank of America', mask: '5567', type: 'credit', balanceCents: -23410, creditLimitCents: 300000,
          statementBalanceCents: 18800, minimumPaymentCents: 2500, dueDate: addDays(today, 19), lastStatementDate: addDays(today, -6), aprBps: 2324),
      Account(id: 'acc-savor', connectionId: 'c-cap', name: 'Savor', institution: 'Capital One', mask: '8810', type: 'credit', balanceCents: -192300, creditLimitCents: 250000,
          statementBalanceCents: 142000, minimumPaymentCents: 4000, dueDate: addDays(today, 8), lastStatementDate: addDays(today, -17), aprBps: 2899),
      const Account(id: 'acc-card', name: 'Apple Card', institution: 'Apple Card', mask: '4421', type: 'credit', balanceCents: -31840, creditLimitCents: 400000),
      Account(id: 'acc-loan', connectionId: 'c-sofi', name: 'Student loan', institution: 'SoFi', mask: '9001', type: 'loan', subtype: 'student', balanceCents: -1825000,
          interestRateBps: 550, nextPaymentCents: 40000, minimumPaymentCents: 40000, dueDate: addDays(today, 20), includeInSafe: false),
    ],
    txns: txns,
    recurring: recurring,
    expected: [
      Expected(id: 'e-pay', kind: ExpectedKind.paycheck, label: 'Payroll', amountCents: 231000, date: next),
      Expected(id: 'e-refund', kind: ExpectedKind.refund, label: 'Amazon refund', amountCents: 2400, date: addDays(today, 4)),
      Expected(id: 'e-iou', kind: ExpectedKind.iou, label: 'Alex owes you', amountCents: 4000, date: addDays(today, 7)),
    ],
    goals: const [
      Goal(id: 'g1', name: 'Savings', targetCents: 1000000, savedCents: 840000, perPaydayCents: 40000),
      Goal(id: 'g2', name: 'Japan trip', targetCents: 400000, savedCents: 120000, perPaydayCents: 0),
    ],
    budgets: const [
      Budget(id: 'b1', categoryId: 'cat-groceries', capCents: 40000),
      Budget(id: 'b2', categoryId: 'cat-restaurants', capCents: 15000),
      Budget(id: 'b3', categoryId: 'cat-coffee', capCents: 6000),
      Budget(id: 'b4', categoryId: 'cat-rideshare', capCents: 10000),
    ],
    rule: rule,
  );
}
