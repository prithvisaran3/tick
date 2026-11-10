import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../data/activity.dart';
import '../data/ledger.dart';
import '../data/nav.dart';
import '../data/settings.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../design/widgets/more.dart';
import '../design/widgets/motion.dart';
import '../design/widgets/pickers.dart';
import '../design/widgets/refresh.dart';
import '../domain/balances.dart';
import '../domain/budget_plan.dart';
import '../domain/money.dart';
import '../services/haptics.dart';
import 'ask_button.dart';
import 'common.dart';
import 'nudges.dart';
import 'tips.dart';

/// Home: what you have. Cash in checking leads; savings sits apart; cards are one quiet row and never come off Cash here.
/// Then the one suggestion that matters most, and the last few purchases. Safe to spend lives in Insights.
class TodayScreen extends ConsumerWidget {
  const TodayScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ledger = ref.watch(ledgerProvider);
    final settings = ref.watch(settingsProvider);
    final sts = ref.watch(safeToSpendProvider);
    final now = ref.watch(clockProvider)();
    final c = context.c;
    final b = homeBalances(ledger.accounts);
    final first = (settings.name ?? '').split(' ').first;
    final paydayNear = sts != null && (settings.demoMode ? sts.daysToPayday <= 1 : (settings.rule != null && isPaydayWindow(settings.rule!, now)));
    final nudge = paydayNear ? null : pickNudge(ledger, sts, now);
    final recent = [...ledger.txns]..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
    final notifier = ref.read(ledgerProvider.notifier);

    return TickScrollView(
      onRefresh: notifier.refresh,
      slivers: [SliverToBoxAdapter(child: Padding(padding: EdgeInsets.fromLTRB(TickLayout.gutter, MediaQuery.of(context).padding.top, TickLayout.gutter, 130), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(height: 52, child: Row(children: [
          const Wordmark(),
          const Spacer(),
          const AskButton(),
          Pressable(onTap: () => context.push('/profile'), semanticLabel: 'Profile', minSize: 44, child: Avatar(first.isEmpty ? 'P' : first, 'biz')),
        ])),
        const SizedBox(height: TickSpace.x2),
        if (ledger.offline) OfflineBanner(onRetry: notifier.refresh),
        if (ledger.loading && ledger.accounts.isEmpty)
          const Column(children: [Skeleton(height: 180, radius: 24), SizedBox(height: TickSpace.x3), Skeleton(height: 72, radius: 24)])
        else ...[
          CashCard(b: b, onAdd: () async {
            final cents = await showAmountSheet(context, title: 'In your checking account');
            if (cents != null) notifier.setManualBalance(cents);
          }),
          if (b.savings.isNotEmpty) ...[const SizedBox(height: TickSpace.x3), _Savings(b: b)],
          if (b.cardsOwedCents > 0 || b.nextCard != null) ...[const SizedBox(height: TickSpace.x3), _Cards(b: b)],
        ],
        if (paydayNear) ...[
          const SizedBox(height: TickSpace.x3),
          _Suggestion(title: 'Payday plan', body: sts.daysToPayday <= 1 ? 'Payday is here. Plan it in a minute.' : 'Payday is tomorrow. Plan it in a minute.', onTap: () => context.push('/payday-plan')),
        ] else if (nudge != null) ...[
          const SizedBox(height: TickSpace.x3),
          _Suggestion(title: nudge.title, body: nudge.body, onTap: () => context.push(nudge.route ?? (nudge.kind == 'relink' ? '/banks' : '/incoming'))),
        ],
        SectionLabel('Recent', trailing: recent.isEmpty ? null : Pressable(onTap: () => ref.read(shellTabProvider.notifier).go(1), semanticLabel: 'See all activity', minSize: 44,
            child: Center(child: Text('See all', style: context.ts(TickType.bodyS, color: c.textSecondary))))),
        if (ledger.loading && recent.isEmpty)
          const ListSkeleton(rows: 3)
        else if (recent.isEmpty)
          const EmptyState('Nothing yet', 'Purchases show up here as they happen.', icon: 'activity')
        else
          TickCard(padding: const EdgeInsets.symmetric(horizontal: TickSpace.x4), child: Column(children: [
            for (final (i, t) in recent.take(5).indexed) ...[
              if (i > 0) const Hairline(),
              if (i == 0 && t.source != 'manual' && now.difference(t.occurredAt).abs() < const Duration(minutes: 2))
                // A capture that just arrived lands with the pop and its price weight; reopening the app later doesn't replay it.
                PopIn(fromOffsetY: 60, fromScale: 0.94, onLanded: () => TickHaptics.instance.capturePop(t.amountCents),
                    child: TxRow(t: t, ledger: ledger, sticker: true, onTap: () => context.push('/txn/${t.id}')))
              else
                StaggerIn(scope: 'home-recent', index: i, child: TxRow(t: t, ledger: ledger, onTap: () => context.push('/txn/${t.id}'))),
            ],
          ])),
      ]))),
      ],
    );
  }
}

/// The headline: Cash across checking, rolling to its value, with one quiet row per account. The number opens every account.
class CashCard extends ConsumerWidget {
  const CashCard({super.key, required this.b, this.onAdd});
  final HomeBalances b;
  final VoidCallback? onAdd;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    if (b.cash.isEmpty) {
      return TickCard(raised: true, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Cash', style: context.ts(TickType.bodyS, color: c.textSecondary)),
        const SizedBox(height: TickSpace.x2),
        Text('Link a bank, or add what\'s in checking.', style: context.ts(TickType.bodyL)),
        const SizedBox(height: TickSpace.x3),
        PillButton('Add what\'s in checking', height: 48, onTap: onAdd),
      ]));
    }
    return TickCard(raised: true, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TipTarget(id: 'home-cash', child: Pressable(
        onTap: () => context.push('/banks'), scale: 0.99, semanticLabel: 'Cash ${formatCents(b.cashCents)} across ${b.cash.length} checking ${b.cash.length == 1 ? 'account' : 'accounts'}. Show every account',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Cash', style: context.ts(TickType.bodyS, color: c.textSecondary)),
          FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: CountUpText(cents: b.cashCents, style: context.ts(TickType.hero), haptic: true, format: (v) => formatCents(v))),
        ]),
      )),
      const SizedBox(height: TickSpace.x2),
      for (final (a, cents) in b.cash) _AccountRow(a: a, cents: cents),
      if (b.excludedCount > 0) Padding(padding: const EdgeInsets.only(top: TickSpace.x1), child: Text('${b.excludedCount} checking ${b.excludedCount == 1 ? 'account is' : 'accounts are'} left out. Change it in Profile.', style: context.ts(TickType.bodyS, color: c.textSecondary))),
    ]));
  }
}

class _AccountRow extends ConsumerWidget {
  const _AccountRow({required this.a, required this.cents});
  final dynamic a; // Account
  final int cents;
  @override
  Widget build(BuildContext context, WidgetRef ref) => Pressable(
        onTap: () { TickHaptics.instance.selection(); openActivity(ref, ActivityQuery(accounts: {a.id as String})); }, scale: 0.99,
        semanticLabel: '${a.institution ?? a.name}, ${formatCents(cents)}. Show its transactions',
        child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 48), child: _Split(
          lead: Row(children: [
            Avatar((a.institution ?? a.name) as String, 'biz', size: 28),
            const SizedBox(width: TickSpace.x3),
            Flexible(child: Text(a.shortLabel as String, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.ts(TickType.body, color: context.c.textSecondary))),
          ]),
          amount: Text(formatCents(cents), style: context.ts(TickType.mono)),
        )),
      );
}

class _Savings extends StatelessWidget {
  const _Savings({required this.b});
  final HomeBalances b;
  @override
  Widget build(BuildContext context) => TickCard(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _Split(lead: Text('Savings', style: context.ts(TickType.bodyS, color: context.c.textSecondary)), amount: Text(formatCents(b.savingsCents), style: context.ts(TickType.monoL))),
        for (final (a, cents) in b.savings) _AccountRow(a: a, cents: cents),
      ]));
}

class _Cards extends StatelessWidget {
  const _Cards({required this.b});
  final HomeBalances b;
  @override
  Widget build(BuildContext context) {
    final due = b.nextCard?.dueDate;
    return TickCard(onTap: () => context.push('/banks'), padding: const EdgeInsets.symmetric(horizontal: TickSpace.x4, vertical: TickSpace.x3), child: _Split(
      lead: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Cards', style: context.ts(TickType.body)),
        if (due != null) Text('Next due ${DateFormat('MMM d').format(due)}', style: context.ts(TickType.bodyS, color: context.c.textSecondary)),
      ]),
      amount: Text('${formatCents(b.cardsOwedCents)} owed', style: context.ts(TickType.mono)),
    ));
  }
}

class _Suggestion extends StatelessWidget {
  const _Suggestion({required this.title, required this.body, required this.onTap});
  final String title;
  final String body;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => TickCard(onTap: onTap, padding: const EdgeInsets.symmetric(horizontal: TickSpace.x4, vertical: TickSpace.x3), child: Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: context.ts(TickType.title, size: 15.5)),
          const SizedBox(height: 2),
          Text(body, style: context.ts(TickType.bodyS, color: context.c.textSecondary)),
        ])),
        TickIcon('chevron-right', size: 18, color: context.c.textSecondary),
      ]));
}

/// A label and an amount on one line; at large text sizes the amount drops under the label instead of squeezing it.
class _Split extends StatelessWidget {
  const _Split({required this.lead, required this.amount});
  final Widget lead;
  final Widget amount;
  @override
  Widget build(BuildContext context) {
    if (MediaQuery.textScalerOf(context).scale(1) > 1.4) {
      return Padding(padding: const EdgeInsets.symmetric(vertical: TickSpace.x1), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [lead, Align(alignment: Alignment.centerRight, child: amount)]));
    }
    return Row(children: [Expanded(child: lead), const SizedBox(width: TickSpace.x2), amount]);
  }
}
