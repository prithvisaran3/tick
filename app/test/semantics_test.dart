import 'package:flutter/rendering.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tick/features/activity_screen.dart';
import 'package:tick/features/banks_screen.dart';
import 'package:tick/features/cards.dart';
import 'package:tick/features/ask_screen.dart';
import 'package:tick/features/budgets_screen.dart';
import 'package:tick/features/caught_screen.dart';
import 'package:tick/features/flows_screen.dart';
import 'package:tick/features/incoming_screen.dart';
import 'package:tick/features/onboarding_screen.dart';
import 'package:tick/features/payday_plan_screen.dart';
import 'package:tick/features/receipt_screen.dart';
import 'package:tick/features/settings_screen.dart';
import 'package:tick/features/today_screen.dart';
import 'golden_harness.dart';

/// VoiceOver audit: every tappable element on every screen has a spoken label.
void main() {
  setUpAll(loadFonts);
  final screens = <String, (Widget Function(), int?)>{
    'today': (() => const TodayScreen(), 0),
    'activity': (() => const ActivityScreen(), 1),
    'flows': (() => const FlowsScreen(), 2),
    'ask': (() => const AskScreen(), 3),
    'caught': (() => const CaughtScreen(), null),
    'receipt': (() => const ReceiptScreen(animate: false), null),
    'incoming': (() => const IncomingScreen(), null),
    'settings': (() => const SettingsScreen(), null),
    'onboarding-1': (() => const OnboardingScreen(initialStep: 0), null),
    'onboarding-2': (() => const OnboardingScreen(initialStep: 1), null),
    'onboarding-3': (() => const OnboardingScreen(initialStep: 2), null),
    'budgets': (() => const BudgetsScreen(), null),
    'payday-plan': (() => const PaydayPlanScreen(), null),
    'banks': (() => const BanksScreen(), null),
    'card': (() => const CardScreen(id: 'acc-disc'), null),
    'categories': (() => const CategoriesScreen(), null),
  };
  for (final e in screens.entries) {
    testWidgets('${e.key}: every tappable has a label', (tester) async {
      final handle = tester.ensureSemantics();
      final c = await demoContainer();
      addTearDown(c.dispose);
      await pumpGolden(tester, frame(c, e.value.$1(), dark: true, tab: e.value.$2));
      final missing = <String>[];
      void walk(SemanticsNode n) {
        final d = n.getSemanticsData();
        final tappable = d.hasAction(SemanticsAction.tap) || d.hasAction(SemanticsAction.longPress);
        final hidden = d.flagsCollection.isHidden;
        if (tappable && !hidden && d.label.trim().isEmpty && d.value.trim().isEmpty && d.tooltip.trim().isEmpty) {
          missing.add('${n.rect} ${d.actions}');
        }
        n.visitChildren((c) { walk(c); return true; });
      }
      // The semantics owner still hangs off the (deprecated) per-view pipeline owner in flutter_test; there is no replacement accessor yet.
      // ignore: deprecated_member_use
      walk(tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!);
      expect(missing, isEmpty, reason: 'tappable nodes without a label on ${e.key}');
      handle.dispose();
    });
  }
}
