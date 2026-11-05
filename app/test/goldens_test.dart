import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tick/features/activity_screen.dart';
import 'package:tick/features/banks_screen.dart';
import 'package:tick/features/cards.dart';
import 'package:tick/features/ask_button.dart';
import 'package:tick/features/ask_screen.dart';
import 'package:tick/features/tally_screen.dart';
import 'package:tick/features/budgets_screen.dart';
import 'package:tick/features/caught_screen.dart';
import 'package:tick/features/payday_plan_screen.dart';
import 'package:tick/domain/models.dart';
import 'package:tick/features/insights_screen.dart';
import 'package:tick/features/incoming_screen.dart';
import 'package:tick/features/onboarding_screen.dart';
import 'package:tick/features/receipt_screen.dart';
import 'package:tick/features/settings_screen.dart';
import 'package:tick/features/today_screen.dart';
import 'golden_harness.dart';

void main() {
  setUpAll(loadFonts);

  final screens = <String, (Widget Function(), int?)>{
    'today': (() => const TodayScreen(), 0),
    'activity': (() => const ActivityScreen(), 1),
    'insights': (() => const InsightsScreen(), 2),
    'tally': (() => const TallyScreen(), 3),
    'ask-tick': (() => const AskSheet(), null),
    'ask-tick-answer': (() => const AskSheet(), null),
    'caught': (() => const CaughtScreen(), null),
    'morning-receipt': (() => const ReceiptScreen(animate: false), null),
    'incoming-upcoming': (() => const IncomingScreen(), null),
    'settings': (() => const SettingsScreen(), null),
    'onboarding-1': (() => const OnboardingScreen(initialStep: 0), null),
    'onboarding-2': (() => const OnboardingScreen(initialStep: 1), null),
    'onboarding-3': (() => const OnboardingScreen(initialStep: 2), null),
    'budgets-goals': (() => const BudgetsScreen(), null),
    'payday-plan': (() => const PaydayPlanScreen(), null),
    'categories': (() => const CategoriesScreen(), null),
    'banks': (() => const BanksScreen(), null),
    'card': (() => const CardScreen(id: 'acc-disc'), null),
    'landed': (() => IncomingScreen(landed: Expected(id: 'e', kind: ExpectedKind.iou, label: 'Alex', amountCents: 4000, date: DateTime(2026, 11, 4))), null),
  };

  for (final e in screens.entries) {
    for (final dark in [true, false]) {
      testWidgets('golden ${e.key} ${dark ? 'dark' : 'light'}', (tester) async {
        final c = await demoContainer(overrides: e.key == 'ask-tick-answer' ? [askProvider.overrideWith(_SeededAsk.new)] : const []);
        addTearDown(c.dispose);
        debugDisableShadows = false; // real shadows in goldens
        await pumpGolden(tester, frame(c, e.value.$1(), dark: dark, tab: e.value.$2));
        await expectLater(find.byType(WidgetsApp), matchesGoldenFile('goldens/${e.key}.${dark ? 'dark' : 'light'}.png'));
        debugDisableShadows = true;
      });
    }
  }
}

class _SeededAsk extends AskNotifier {
  @override
  List<AskMessage> build() => [
        AskMessage(true, 'How much did I spend on food this month?'),
        AskMessage(false, '\$412 on food so far this month. That\'s \$58 over last month at this point.', blocks: [
          {'kind': 'bars', 'values': [for (final e in [('Wk 1', 5200), ('Wk 2', 9100), ('Wk 3', 7400), ('Now', 11800)]) {'label': e.$1, 'cents': e.$2}]},
          {'kind': 'txns', 'ids': ['demo-2', 'demo-4']},
        ]),
      ];
}
