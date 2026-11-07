import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tick/features/activity_screen.dart';
import 'package:tick/features/banks_screen.dart';
import 'package:tick/features/cards.dart';
import 'package:tick/features/budgets_screen.dart';
import 'package:tick/features/caught_screen.dart';
import 'package:tick/features/incoming_screen.dart';
import 'package:tick/features/onboarding_screen.dart';
import 'package:tick/features/receipt_screen.dart';
import 'package:tick/features/ask_screen.dart';
import 'package:tick/features/payday_plan_screen.dart';
import 'package:tick/features/insights_screen.dart';
import 'package:tick/features/import_screen.dart';
import 'package:tick/features/settings_screen.dart';
import 'package:tick/features/today_screen.dart';
import 'package:tick/domain/tally.dart';
import 'package:tick/features/tally_screen.dart';
import 'package:tick/features/tally_group_screen.dart';
import 'package:tick/features/tally_expense_sheet.dart';
import 'package:tick/features/tally_expense_screen.dart';
import 'package:tick/features/tally_manage.dart';
import 'package:tick/features/tally_more.dart';
import 'golden_harness.dart';

/// Dynamic Type to XXL (text scale 1.6): no overflow exceptions on the main screens.
void main() {
  setUpAll(loadFonts);
  final screens = <String, Widget Function()>{'tally-settings': () => const TallyGroupSettingsScreen(id: 'g-room'), 'tally-expense-detail': () => const TallyExpenseScreen(groupId: 'g-room', id: 'x1'), 'tally-plan': () => const TallyPlanScreen(), 'tally-person': () => const TallyPersonScreen(groupId: 'g-room', member: 'p-k'), 'tally-receipt': () => const TallyReceiptScreen(id: 'g-room'), 'today': () => const TodayScreen(), 'activity': () => const ActivityScreen(), 'insights': () => const InsightsScreen(), 'settings': () => const SettingsScreen(), 'budgets': () => const BudgetsScreen(), 'caught': () => const CaughtScreen(), 'incoming': () => const IncomingScreen(), 'receipt': () => const ReceiptScreen(animate: false), 'ask': () => const AskScreen(), 'categories': () => const CategoriesScreen(), 'onb1': () => const OnboardingScreen(initialStep: 0), 'onb2': () => const OnboardingScreen(initialStep: 1), 'onb3': () => const OnboardingScreen(initialStep: 2), 'payday-plan': () => const PaydayPlanScreen(), 'banks': () => const BanksScreen(), 'import': () => const ImportScreen(), 'settings-appearance': () => const SettingsScreen(page: SettingsPage.appearance), 'settings-data': () => const SettingsScreen(page: SettingsPage.data), 'settings-labs': () => const SettingsScreen(page: SettingsPage.labs), 'settings-about': () => const SettingsScreen(page: SettingsPage.about), 'card': () => const CardScreen(id: 'acc-disc'), 'tally': () => const TallyScreen(), 'tally-group': () => const TallyGroupScreen(id: 'g-room'), 'tally-expense': () => const ExpenseSheet(group: TallyGroup(id: 'g-room', name: 'Roommates', memberIds: ['p-k', 'p-j']), description: 'A long dinner description that has to wrap', cents: 8750)};
  // Every screen at the four iPhone widths we support, from default text to accessibility sizes: nothing may overflow or throw.
  for (final e in screens.entries) {
    for (final w in [320.0, 375.0, 393.0, 430.0]) {
      for (final scale in [1.0, 1.6, 2.35]) {
        if (w != 320 && w != 430 && scale == 1.0) continue; // 1.0 at 393 is covered by the goldens
        testWidgets('${e.key} at ${w.toInt()}pt, text x$scale', (tester) async {
          final c = await demoContainer();
          addTearDown(c.dispose);
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          await pumpGolden(tester, frame(c, e.value(), dark: scale > 1.5), width: w);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
