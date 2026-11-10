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
import '../design/widgets/motion.dart';
import '../design/widgets/pickers.dart';
import '../domain/dates.dart';
import '../domain/payday.dart';
import '../domain/ideas.dart';
import '../domain/money.dart';
import '../domain/safe_to_spend.dart';
import '../services/haptics.dart';

const _groups = <(String, String)>[('cash', 'Cash in checking'), ('bill', 'Bills before payday'), ('card', 'Card payments due'), ('loan', 'Loan payments due'), ('goal', 'Goals planned')];

/// Insights, top: Safe to spend for this pay period, with the sum behind it on a tap. The lines add up to the headline exactly.
class SafeToSpendCard extends ConsumerStatefulWidget {
  const SafeToSpendCard({super.key});
  @override
  ConsumerState<SafeToSpendCard> createState() => _SafeToSpendCardState();
}

class _SafeToSpendCardState extends ConsumerState<SafeToSpendCard> {
  bool _open = false;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final sts = ref.watch(safeToSpendProvider);
    final now = ref.watch(clockProvider)();
    if (sts == null) {
      return TickCard(onTap: () => context.push('/settings/payday'), child: Row(children: [
        Expanded(child: Text('Set your payday to see Safe to spend.', style: context.ts(TickType.body))),
        TickIcon('chevron-right', size: 18, color: c.textSecondary),
      ]));
    }
    final fmt = DateFormat('MMM d');
    final period = sts.periodStart == null ? '' : '${fmt.format(sts.periodStart!)} – ${fmt.format(addDays(sts.nextPayday, -1))}';
    final days = daysBetween(dayOnly(now), sts.nextPayday);
    final flags = ref.watch(settingsProvider);
    return TickCard(raised: true, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Safe to spend this pay period', style: context.ts(TickType.bodyS, color: c.textSecondary)),
      FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: RollingNumber(value: sts.cents, builder: (_, v) => Text(formatCents(v), style: context.ts(TickType.hero, color: v < 0 ? c.alert : null)))),
      Text('$period · ${days == 1 ? '1 day' : '$days days'} to payday', style: context.ts(TickType.bodyS, color: c.textSecondary)),
      const SizedBox(height: TickSpace.x2),
      Pressable(
        onTap: () { TickHaptics.instance.selection(); setState(() => _open = !_open); }, scale: 0.99, semanticLabel: _open ? 'Hide how it\'s calculated' : 'How it\'s calculated',
        child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 44), child: Row(children: [
          Expanded(child: Text('How it\'s calculated', style: context.ts(TickType.body))),
          AnimatedRotation(turns: _open ? 0.25 : 0, duration: Duration(milliseconds: context.reduceMotion ? 0 : 200), child: TickIcon('chevron-right', size: 18, color: c.textSecondary)),
        ])),
      ),
      AnimatedSize(duration: Duration(milliseconds: context.reduceMotion ? 0 : 220), alignment: Alignment.topCenter, child: !_open ? const SizedBox(width: double.infinity) : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final (g, label) in _groups)
          if (sts.lines.any((l) => l.group == g)) ...[
            const Hairline(),
            Padding(padding: const EdgeInsets.only(top: TickSpace.x2, bottom: TickSpace.x1), child: Text(label, style: context.ts(TickType.bodyS, color: c.textSecondary))),
            for (final l in sts.lines.where((l) => l.group == g)) Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Row(children: [
              Expanded(child: Text(l.date == null ? l.label : '${l.label} · ${fmt.format(l.date!)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: context.ts(TickType.body))),
              const SizedBox(width: TickSpace.x2),
              Text(formatCents(l.cents, sign: true), style: context.ts(TickType.mono)),
            ])),
          ],
        const Hairline(),
        Padding(padding: const EdgeInsets.symmetric(vertical: TickSpace.x2), child: Row(children: [
          Expanded(child: Text('Safe to spend', style: context.ts(TickType.title, size: 16))),
          Text(formatCents(sts.cents), style: context.ts(TickType.mono)),
        ])),
        if (flags.flag('card_guard')) if (cardGuard(sts, ref.watch(ledgerProvider).accounts, now) case final g?) Padding(padding: const EdgeInsets.only(bottom: TickSpace.x2), child: Text(cardGuardLine(g, now), style: context.ts(TickType.bodyS, color: g.short ? c.alert : c.textSecondary))),
        if (flags.flag('truly_free') && sts.cardsLaterCents > 0) Text(trulyFreeLine(sts), style: context.ts(TickType.bodyS, color: c.textSecondary)),
        if (flags.flag('what_if')) Align(alignment: Alignment.centerLeft, child: TickChip('What if I spend…', onTap: () => _whatIf(context, sts))),
      ])),
    ]));
  }
}

/// What if: try an amount before you buy it. Suggest-only; nothing is saved.
Future<void> _whatIf(BuildContext context, SafeToSpend sts) async {
  final cents = await showAmountSheet(context, title: 'What if you spent', confirm: 'Check');
  if (cents == null || cents == 0 || !context.mounted) return;
  final r = whatIf(sts, cents);
  TickHaptics.instance.priceWeight(cents);
  final day = DateFormat('EEEE').format(r.payday);
  await showTickSheet<void>(context, builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(formatDollars(r.afterCents.abs()), style: ctx.ts(TickType.hero, color: r.over ? ctx.c.alert : ctx.c.text)),
        const SizedBox(height: 4),
        Text(r.over ? 'past safe to spend until $day if you spend ${formatDollars(cents)}.' : 'still safe to spend until $day after ${formatDollars(cents)}.', style: ctx.ts(TickType.body, color: ctx.c.textSecondary)),
        const SizedBox(height: 16),
        PillButton('Done', onTap: () => Navigator.of(ctx).pop()),
      ]));
}
