import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../data/ledger.dart';
import '../data/settings.dart';
import '../design/motion.g.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../design/widgets/more.dart';
import '../design/widgets/pickers.dart';
import '../design/widgets/refresh.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import '../domain/payday.dart';
import '../services/haptics.dart';
import 'cards.dart';
import 'common.dart';
import 'nudges.dart';
import '../domain/budget_plan.dart';
import '../domain/ideas.dart';
import '../domain/safe_to_spend.dart';

class TodayScreen extends ConsumerWidget {
  const TodayScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ledger = ref.watch(ledgerProvider);
    final settings = ref.watch(settingsProvider);
    final sts = ref.watch(safeToSpendProvider);
    final now = ref.watch(clockProvider)();
    final c = context.c;
    final today = dayOnly(now);
    final todays = ledger.txns.where((t) => dayOnly(t.occurredAt) == today).toList();
    final greeting = now.hour < 12 ? 'Good morning' : now.hour < 18 ? 'Good afternoon' : 'Good evening';
    final first = (settings.name ?? '').split(' ').first;
    final billShown = ledger.recurring.where((r) => !r.nextDate.isAfter(dayOnly(now).add(const Duration(days: 7)))).toList()..sort((a, b) => a.nextDate.compareTo(b.nextDate));
    final paydayNear = settings.demoMode ? (sts != null && sts.daysToPayday <= 1) : (settings.rule != null && isPaydayWindow(settings.rule!, now));
    final nudge = pickNudge(ledger, sts, now, skipBillFor: billShown.isEmpty ? null : billShown.first.merchant);

    final upcoming = sts == null ? <Recurring>[] : (ledger.recurring.where((r) => !r.nextDate.isAfter(today.add(const Duration(days: 7)))).toList()..sort((a, b) => a.nextDate.compareTo(b.nextDate)));
    final nextIn = ledger.expected.where((e) => e.kind == ExpectedKind.paycheck).toList()..sort((a, b) => a.date.compareTo(b.date));

    return TickScrollView(
      onRefresh: ref.read(ledgerProvider.notifier).refresh,
      slivers: [SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.only(bottom: 130), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          height: 52,
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            const Wordmark(),
            Pressable(onTap: () => context.push('/settings'), semanticLabel: 'Settings', minSize: 44, child: Avatar(first.isEmpty ? 'P' : first, 'biz')),
          ]),
        ),
        Padding(padding: const EdgeInsets.only(top: 4), child: Text(first.isEmpty ? '$greeting.' : '$greeting, $first.', style: context.ts(TickType.bodyL, color: c.textSecondary))),
        const SizedBox(height: 16),
        if (ledger.offline) OfflineBanner(onRetry: ref.read(ledgerProvider.notifier).refresh),
        _Hero(sts: sts, loading: ledger.loading, needsBalance: !settings.demoMode && !ledger.loading && sts != null && !ledger.accounts.any((a) => a.includeInSafe && a.isCash && a.type != 'savings'), onAddBalance: () async {
          final cents = await showAmountSheet(context, title: 'In your checking account');
          if (cents != null) ref.read(ledgerProvider.notifier).setManualBalance(cents);
        }),
        const SizedBox(height: 12),
        if (sts != null)
          SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [
            _Pill('${formatDollars(sts.cashCents)} cash'), const SizedBox(width: 6),
            _Pill('${formatDollars(-sts.billsCents)} bills'), const SizedBox(width: 6),
            if (sts.cardsDueCents > 0) ...[_Pill('${formatDollars(-sts.cardsDueCents)} cards due'), const SizedBox(width: 6)],
            if (sts.loansDueCents > 0) ...[_Pill('${formatDollars(-sts.loansDueCents)} loan'), const SizedBox(width: 6)],
            _Pill('${formatDollars(-sts.goalsCents)} goals'),
            if (settings.flag('what_if')) ...[
              const SizedBox(width: 6),
              Pressable(onTap: () => _whatIf(context, sts), semanticLabel: 'What if I spend', minSize: 44, child: const _Pill('What if…')),
            ],
          ])),
        if (sts != null && settings.flag('truly_free') && sts.cardsLaterCents > 0)
          Padding(padding: const EdgeInsets.only(top: 8), child: Text(trulyFreeLine(sts), style: context.ts(TickType.bodyS, color: c.textSecondary))),
        if (settings.flag('card_guard')) ...[
          if (cardGuard(sts, ledger.accounts, now) case final g?) ...[
            const SizedBox(height: 12),
            TickCard(
              raised: true, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              onTap: g.firstDue == null ? null : () => context.push('/card/${g.firstDue!.id}'),
              child: Semantics(label: cardGuardLine(g, now), excludeSemantics: true, child: Row(children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(g.short ? 'Cards need more than checking has' : 'Cards before payday', style: context.ts(TickType.title, size: 15.5, color: g.short ? c.alert : c.text)),
                  const SizedBox(height: 2),
                  Text(cardGuardLine(g, now), style: context.ts(TickType.bodyS, size: 13.5, color: c.textSecondary)),
                ])),
                Text(formatDollars(g.dueCents), style: context.ts(TickType.mono)),
              ])),
            ),
          ],
        ],
        if (paydayNear && sts != null) ...[
          const SizedBox(height: 12),
          TickCard(
            onTap: () => context.push('/payday-plan'), raised: true, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Payday plan', style: context.ts(TickType.title, size: 16)),
                Text(sts.daysToPayday <= 1 ? 'Payday is here. Plan it in a minute.' : 'Payday is tomorrow. Plan it in a minute.', style: context.ts(TickType.bodyS, color: c.textSecondary)),
              ])),
              TickIcon('chevron-right', size: 20, color: c.textSecondary),
            ]),
          ),
        ],
        SectionLabel(todays.isEmpty ? 'Today' : 'Today · ${todays.length} caught', trailing: ledger.needsReview.isEmpty ? null : TickChip('${ledger.needsReview.length} to check', icon: 'caught', onTap: () => context.push('/caught'))),
        if (ledger.loading)
          const ListSkeleton(rows: 2)
        else if (todays.isEmpty)
          TickCard(child: Text('Quiet day. Your wallet says thanks.', style: context.ts(TickType.body, color: c.textSecondary)))
        else
          TickCard(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(children: [
              for (var i = 0; i < todays.length && i < 4; i++) ...[
                if (i > 0) const Hairline(),
                PopIn(delay: Duration(milliseconds: 80 * i), fromOffsetY: 60, fromScale: 0.94, onLanded: () {
                  // The pop + price weight is for a NEW capture only, not for re-opening the app with an old one on top.
                  if (i == 0 && todays[0].source != 'manual' && now.difference(todays[0].occurredAt).abs() < const Duration(minutes: 2)) TickHaptics.instance.capturePop(todays[0].amountCents);
                },
                    child: TxRow(t: todays[i], ledger: ledger, sticker: i == 0, subtitle: _sub(todays[i], ledger, i == 0), onTap: () => context.push('/txn/${todays[i].id}'))),
              ],
            ]),
          ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: _Strip(label: 'Incoming', color: c.incoming, amount: nextIn.isEmpty ? null : nextIn.first.amountCents, sub: nextIn.isEmpty ? 'Add your paycheck' : '${nextIn.first.label} · ${weekdayName(nextIn.first.date, now)}', onTap: () => context.push('/incoming'))),
          const SizedBox(width: 8),
          Expanded(child: _Strip(label: 'Upcoming', color: c.alert, amount: upcoming.isEmpty ? null : upcoming.first.expectedCents, sub: upcoming.isEmpty ? 'Nothing due this week' : '${upcoming.first.merchant} · ${weekdayName(upcoming.first.nextDate, now)}', onTap: () => context.push('/incoming'))),
        ]),
        const CardsSection(compact: true),
        if (nudge != null) ...[
          const SizedBox(height: 8),
          TickCard(
            raised: true, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), onTap: () => context.push(nudge.route ?? (nudge.kind == 'relink' ? '/banks' : '/incoming')),
            child: Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(nudge.title, style: context.ts(TickType.title, size: 15.5)),
                const SizedBox(height: 2),
                Text(nudge.body, style: context.ts(TickType.bodyS, size: 13.5, color: c.textSecondary)),
              ])),
              if (nudge.paceRatio != null) ...[const SizedBox(width: 12), _PaceBar(ratio: nudge.paceRatio!)],
            ]),
          ),
        ],
      ]))),
      ],
    );
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
        Text(r.over ? 'past safe to spend until $day if you spend ${formatDollars(cents)}.' : 'still safe to spend until $day after ${formatDollars(cents)}.',
            style: ctx.ts(TickType.body, color: ctx.c.textSecondary)),
        const SizedBox(height: 16),
        PillButton('Done', onTap: () => Navigator.of(ctx).pop()),
      ]));
}

String _sub(Txn t, LedgerState l, bool first) {
  final acct = l.account(t.accountId)?.shortLabel ?? sourceLabel(t.source);
  return '$acct · ${first ? 'just now' : DateFormat('h:mm a').format(t.occurredAt)}';
}

class _Hero extends StatelessWidget {
  const _Hero({required this.sts, required this.loading, this.needsBalance = false, this.onAddBalance});
  final bool needsBalance;
  final VoidCallback? onAddBalance;
  final dynamic sts; // SafeToSpend?
  final bool loading;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    if (loading && sts == null) {
      return const Center(child: Skeleton(width: 300, height: 128, radius: 64));
    }
    if (needsBalance) {
      // No bank and no typed balance: Safe to spend can't be honest yet, so ask for the one number it needs.
      return Column(children: [
        Pressable(onTap: onAddBalance, semanticLabel: 'Add your balance', child: Sticker(hole: true, padding: const EdgeInsets.fromLTRB(44, 20, 36, 20), child: Text('Add balance', style: context.ts(TickType.displayM, color: c.onAccent)))),
        const SizedBox(height: 12),
        Text('Safe to spend needs what is in your account today.', textAlign: TextAlign.center, style: context.ts(TickType.body, color: c.textSecondary)),
      ]);
    }
    if (sts == null) {
      return Column(children: [
        Sticker(hole: true, padding: const EdgeInsets.fromLTRB(44, 20, 36, 20), child: Text('Add paycheck', style: context.ts(TickType.displayM, color: c.onAccent))),
        const SizedBox(height: 12),
        Text('Add your paycheck to see what is safe to spend.', textAlign: TextAlign.center, style: context.ts(TickType.body, color: c.textSecondary)),
      ]);
    }
    final cents = sts.cents as int;
    final day = DateFormat('EEEE').format(sts.nextPayday as DateTime);
    return Center(
      child: Semantics(
        label: '${formatDollars(cents)} safe to spend until $day',
        child: PopIn(
          spring: TickSprings.pop, fromScale: 0.7, fromTilt: -0.12,
          child: Sticker(
            hole: true, padding: const EdgeInsets.fromLTRB(60, 14, 52, 14),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              FittedBox(fit: BoxFit.scaleDown, child: CountUpText(cents: cents, style: context.ts(TickType.heroXL, color: c.onAccent, size: 72))),
              Text('Safe to spend until $day', style: TextStyle(fontFamily: TickFamilies.text, fontWeight: FontWeight.w900, fontSize: 14.5, color: c.onAccent, decoration: TextDecoration.none)),
            ]),
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Container(
        height: 32, padding: const EdgeInsets.symmetric(horizontal: 11), alignment: Alignment.center,
        decoration: BoxDecoration(color: context.c.surface1, borderRadius: BorderRadius.circular(999), border: Border.all(color: context.c.hairline)),
        child: Text(text, style: context.ts(TickType.monoS, size: 12)),
      );
}

class _Strip extends StatelessWidget {
  const _Strip({required this.label, required this.color, required this.amount, required this.sub, required this.onTap});
  final String label;
  final Color color;
  final int? amount;
  final String sub;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => TickCard(
        onTap: onTap, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: TextStyle(fontFamily: TickFamilies.text, fontWeight: FontWeight.w700, fontSize: 13, letterSpacing: 0.2, color: color, decoration: TextDecoration.none)),
          const SizedBox(height: 4),
          Text(amount == null ? '—' : formatDollars(amount!), style: context.ts(TickType.monoL)),
          Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.ts(TickType.bodyS, color: context.c.textSecondary)),
        ]),
      );
}

class _PaceBar extends StatelessWidget {
  const _PaceBar({required this.ratio});
  final double ratio; // pace / cap
  @override
  Widget build(BuildContext context) {
    final fill = (ratio.clamp(0.0, 1.3)) / 1.3;
    return SizedBox(
      width: 72, height: 16,
      child: Stack(alignment: Alignment.centerLeft, clipBehavior: Clip.none, children: [
        Container(height: 8, decoration: BoxDecoration(color: context.c.hairline, borderRadius: BorderRadius.circular(8))),
        FractionallySizedBox(widthFactor: fill, child: Container(height: 8, decoration: BoxDecoration(color: context.c.alert, borderRadius: BorderRadius.circular(8)))),
        Positioned(left: 72 / 1.3, child: Container(width: 2, height: 16, color: context.c.text)),
      ]),
    );
  }
}
