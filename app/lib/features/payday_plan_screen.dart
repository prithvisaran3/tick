import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../data/ledger.dart';
import '../data/settings.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../design/widgets/more.dart';
import '../domain/budget_plan.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import '../domain/payday.dart';
import '../services/haptics.dart';
import 'common.dart';

/// Payday plan: what comes in, what is already spoken for, what to move to savings, and what is left safe.
/// Opened from the payday notification and from Today.
class PaydayPlanScreen extends ConsumerStatefulWidget {
  const PaydayPlanScreen({super.key});
  @override
  ConsumerState<PaydayPlanScreen> createState() => _PaydayPlanScreenState();
}

class _PaydayPlanScreenState extends ConsumerState<PaydayPlanScreen> {
  bool _moved = false;

  @override
  Widget build(BuildContext context) {
    final l = ref.watch(ledgerProvider);
    final s = ref.watch(settingsProvider);
    final now = ref.watch(clockProvider)();
    final c = context.c;
    if (l.loading && l.accounts.isEmpty) return TickScreen(child: Column(children: [ScreenTitle('Payday plan', onBack: () => context.pop()), const ListSkeleton(rows: 4)]));
    final rule = s.demoMode ? ref.watch(safeToSpendProvider) == null ? null : buildRuleFor(ref) : s.rule;
    if (rule == null) {
      return TickScreen(child: Column(children: [ScreenTitle('Payday plan', onBack: () => context.pop()), const EmptyState('Add your paycheck first', 'Tick plans payday once it knows when you get paid.', icon: 'calendar')]));
    }
    final landed = l.txns.any((t) => t.amountCents > 0 && dayOnly(t.occurredAt) == dayOnly(now) && l.category(t.categoryId)?.name == 'Income' && t.flow != 'transfer');
    final plan = buildPaydayPlan(today: now, rule: rule, accounts: l.accounts, recurring: l.recurring, goals: l.goals, paycheckLanded: landed);
    final headlineAmount = plan.safeAfterCents;
    return TickScreen(
      child: ListView(padding: const EdgeInsets.only(bottom: 40), children: [
        ScreenTitle('Payday plan', onBack: () => context.pop()),
        Center(
          child: PopIn(
            fromTilt: -0.12, onLanded: () => TickHaptics.instance.pop(),
            child: Sticker(hole: true, padding: const EdgeInsets.fromLTRB(60, 14, 52, 14), child: Column(mainAxisSize: MainAxisSize.min, children: [
              FittedBox(fit: BoxFit.scaleDown, child: CountUpText(cents: headlineAmount, style: context.ts(TickType.heroXL, color: c.onAccent, size: 64))),
              Text('Safe after the plan', style: TextStyle(fontFamily: TickFamilies.text, fontWeight: FontWeight.w900, fontSize: 14, color: c.onAccent, decoration: TextDecoration.none)),
            ])),
          ),
        ),
        const SizedBox(height: 16),
        Text(_moved ? 'Moved. ${formatDollars(plan.moveCents)} is set aside and you still have ${formatDollars(headlineAmount)} safe.' : plan.headline, style: context.ts(TickType.bodyL)),
        const SizedBox(height: 16),
        TickCard(padding: const EdgeInsets.symmetric(horizontal: 16), child: Column(children: [
          _line(context, 'Paycheck', plan.paycheckCents, kind: MoneyKind.expected, sub: landed ? 'Landed' : 'Expected ${weekdayName(nextPayday(rule, dayOnly(now)), now)}'),
          const Hairline(),
          _line(context, 'Bills before ${DateFormat('EEEE').format(plan.nextPayday)}', -plan.billsCents),
          for (final g in plan.moves) ...[const Hairline(), _line(context, 'To ${g.name}', -g.perPaydayCents, sub: '${formatDollars(g.savedCents)} of ${formatDollars(g.targetCents)} saved')],
        ])),
        const SizedBox(height: 16),
        if (plan.moves.isEmpty)
          Text('Nothing to move this payday. Add a goal that moves money each payday and it shows up here.', style: context.ts(TickType.body, color: c.textSecondary))
        else if (_moved)
          Center(child: PopIn(fromScale: 1.15, onLanded: () => TickHaptics.instance.landed(), child: Transform.rotate(angle: -0.1, child: Container(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8), decoration: BoxDecoration(border: Border.all(color: c.text, width: 3), borderRadius: BorderRadius.circular(999)), child: Text('Ticked.', style: context.ts(TickType.displayM, size: 22))))))
        else
          HoldToConfirm(label: 'Move to savings', onConfirmed: () async {
            if (_moved) return;                                          // a second hold can never move money twice
            setState(() => _moved = true);
            await ref.read(ledgerProvider.notifier).movePaydayToSavings(plan.moves);
            if (mounted) setState(() => _moved = true);
          }),
        const SizedBox(height: 8),
        if (!_moved) PillButton('Not now', style: PillStyle.ghost, height: 52, onTap: () => context.pop()),
      ]),
    );
  }

  PaydayRule? buildRuleFor(WidgetRef ref) {
    final sts = ref.read(safeToSpendProvider);
    if (sts == null) return null;
    // Demo mode: reconstruct the rule from the demo payday so the plan reads the same as Today.
    return PaydayRule(frequency: PayFrequency.biweekly, anchor: sts.nextPayday, amountCents: 231000);
  }

  Widget _line(BuildContext context, String t, int cents, {MoneyKind? kind, String? sub}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.ts(TickType.title, size: 16)),
            if (sub != null) Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.ts(TickType.bodyS, color: context.c.textSecondary)),
          ])),
          const SizedBox(width: 8),
          Money(cents, kind: kind),
        ]),
      );
}
