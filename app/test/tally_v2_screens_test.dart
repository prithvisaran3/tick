import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tick/domain/tally.dart';
import 'package:tick/features/tally_manage.dart';
import 'package:tick/features/tally_more.dart';
import 'package:tick/features/tally_people.dart';
import 'golden_harness.dart';

/// Every new Tally screen renders with demo data at the narrowest phone, with no overflow or exception.
void main() {
  const room = TallyGroup(id: 'g-room', name: 'Roommates', emoji: '🏠', memberIds: ['p-k', 'p-j']);
  final screens = <String, Widget>{
    'settings': const TallyGroupSettingsScreen(id: 'g-room'),
    'activity': const TallyActivityScreen(id: 'g-room'),
    'person': const TallyPersonScreen(groupId: 'g-room', member: 'p-k'),
    'plan': const TallyPlanScreen(),
    'receipt': const TallyReceiptScreen(id: 'g-room'),
    'inbox': const TallyInboxScreen(),
    'remind': const SingleChildScrollView(child: RemindSheet(g: room, member: 'p-j', cents: 3000)),
  };
  for (final e in screens.entries) {
    testWidgets('${e.key} renders at 320pt', (tester) async {
      await loadFonts();
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = await demoContainer();
      addTearDown(c.dispose);
      await tester.pumpWidget(frame(c, e.value, dark: true));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('settle sheet: partial amounts allowed, more than owed refused', (tester) async {
    await loadFonts();
    final c = await demoContainer();
    addTearDown(c.dispose);
    late BuildContext host;
    await tester.pumpWidget(frame(c, Builder(builder: (ctx) { host = ctx; return SingleChildScrollView(child: SettleSheet(g: room, m: const Transfer('p-j', me, 3000), host: host)); }), dark: true));
    await tester.pump();
    expect(find.text('Settle up with Jo'), findsOneWidget);
    await tester.enterText(find.byType(EditableText).first, '45');
    await tester.pump();
    expect(find.textContaining('more than'), findsOneWidget);
    await tester.enterText(find.byType(EditableText).first, '10');
    await tester.pump();
    expect(find.textContaining('more than'), findsNothing);
  });
}
