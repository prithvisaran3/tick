import 'package:flutter_test/flutter_test.dart';
import 'package:tick/design/widgets/core.dart';
import 'package:tick/domain/flows.dart';
import 'package:tick/domain/models.dart';
import 'package:tick/features/insights_screen.dart';
import 'golden_harness.dart';

void main() {
  const friends = Category(id: 'f', name: 'Friends and family', colorKey: 'shop', icon: 'arrow-out');
  const food = Category(id: 'c', name: 'Restaurants', colorKey: 'food', icon: 'receipt');
  final cats = {'f': friends, 'c': food};
  final at = DateTime(2026, 11, 3, 12);
  final rows = [
    Txn(id: '1', amountCents: -5000, occurredAt: at, merchant: 'Zelle to Kaarthik', categoryId: 'f'),
    Txn(id: '2', amountCents: 2000, occurredAt: at, merchant: 'Zelle from Asha', categoryId: 'f'),
    Txn(id: '3', amountCents: -8000, occurredAt: at, merchant: 'Dishoom', categoryId: 'c', reimbursedCents: 3000),
    Txn(id: '4', amountCents: 3000, occurredAt: at, merchant: 'Zelle from Jo', categoryId: 'f', flow: 'reimbursement'),
  ];

  test('friends are one net, out of the totals by default', () {
    final t = computeTotals(rows, cats: cats);
    expect((t.outCents, t.inCents), (5000, 0));
    expect((t.friendsInCents, t.friendsOutCents, t.friendsNetCents, t.friendsIncluded), (2000, 5000, -3000, false));
    expect(t.byCategory.containsKey('f'), isFalse);
  });

  test('the toggle puts them back; the payback still nets the purchase', () {
    final t = computeTotals(rows, cats: cats, includeFriends: true);
    expect((t.outCents, t.inCents), (10000, 2000));
    expect(t.byCategory['c'], 5000);
    expect(t.friendsNetCents, -3000);
  });

  testWidgets('Insights shows one net line and the toggle', (tester) async {
    final c = await demoContainer(demo: false);
    addTearDown(c.dispose);
    bool? changed;
    await tester.pumpWidget(frame(c, FriendsSection(t: computeTotals(rows, cats: cats), onToggle: (v) async => changed = v), dark: true));
    expect(find.text('Money with friends'), findsOneWidget);
    expect(find.text('Friends and family'), findsOneWidget);
    expect(find.text('Not in spending, income or budgets.'), findsOneWidget);
    await tester.tap(find.byType(TickToggle));
    await tester.pump();
    expect(changed, isTrue);
  });

  testWidgets('with the toggle on it says it is counted', (tester) async {
    final c = await demoContainer(demo: false);
    addTearDown(c.dispose);
    await tester.pumpWidget(frame(c, FriendsSection(t: computeTotals(rows, cats: cats, includeFriends: true), onToggle: (_) async {}), dark: true));
    expect(find.text('Counted in spending and income.'), findsOneWidget);
  });
}
