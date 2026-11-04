import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tick/features/activity_screen.dart';
import 'package:tick/features/ask_screen.dart';
import 'package:tick/features/budgets_screen.dart';
import 'package:tick/features/caught_screen.dart';
import 'package:tick/features/payday_plan_screen.dart';
import 'package:tick/domain/models.dart';
import 'package:tick/features/flows_screen.dart';
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
    'flows': (() => const FlowsScreen(), 2),
    'ask-tick': (() => const AskScreen(), 3),
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
    'landed': (() => IncomingScreen(landed: Expected(id: 'e', kind: ExpectedKind.iou, label: 'Alex', amountCents: 4000, date: DateTime(2026, 11, 4))), null),
  };

  for (final e in screens.entries) {
    for (final dark in [true, false]) {
      testWidgets('golden ${e.key} ${dark ? 'dark' : 'light'}', (tester) async {
        final c = await demoContainer();
        addTearDown(c.dispose);
        debugDisableShadows = false; // real shadows in goldens
        await pumpGolden(tester, frame(c, e.value.$1(), dark: dark, tab: e.value.$2));
        await expectLater(find.byType(WidgetsApp), matchesGoldenFile('goldens/${e.key}.${dark ? 'dark' : 'light'}.png'));
        debugDisableShadows = true;
      });
    }
  }
}
