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
import 'package:tick/features/flows_screen.dart';
import 'package:tick/features/settings_screen.dart';
import 'package:tick/features/today_screen.dart';
import 'golden_harness.dart';

/// Dynamic Type to XXL (text scale 1.6): no overflow exceptions on the main screens.
void main() {
  setUpAll(loadFonts);
  final screens = <String, Widget Function()>{'today': () => const TodayScreen(), 'activity': () => const ActivityScreen(), 'flows': () => const FlowsScreen(), 'settings': () => const SettingsScreen(), 'budgets': () => const BudgetsScreen(), 'caught': () => const CaughtScreen(), 'incoming': () => const IncomingScreen(), 'receipt': () => const ReceiptScreen(animate: false), 'ask': () => const AskScreen(), 'categories': () => const CategoriesScreen(), 'onb1': () => const OnboardingScreen(initialStep: 0), 'onb2': () => const OnboardingScreen(initialStep: 1), 'onb3': () => const OnboardingScreen(initialStep: 2), 'payday-plan': () => const PaydayPlanScreen(), 'banks': () => const BanksScreen(), 'card': () => const CardScreen(id: 'acc-disc')};
  for (final e in screens.entries) {
    testWidgets('${e.key} survives text scale 1.6', (tester) async {
      final c = await demoContainer();
      addTearDown(c.dispose);
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpGolden(tester, frame(c, e.value(), dark: true));
      expect(tester.takeException(), isNull);
    });
  }
}
