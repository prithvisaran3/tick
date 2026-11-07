import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../data/activity.dart';
import '../data/insights.dart';
import '../data/ledger.dart';
import '../data/nav.dart';
import '../data/settings.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../design/widgets/more.dart';
import '../design/widgets/motion.dart';
import '../design/widgets/scaffold.dart';
import '../domain/flows.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import '../domain/safe_to_spend.dart';
import '../services/api.dart';
import 'ask_button.dart';
import 'common.dart';

/// Insights answers two questions: "Where is my money going?" and "Am I on track?". Everything here comes from the shared money rules:
/// cards included, transfers and Tally settle-ups excluded. Nothing is shown that can't be tapped through to the rows behind it.
class InsightsScreen extends ConsumerWidget {
  const InsightsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = ref.watch(ledgerProvider);
    final data = ref.watch(insightsProvider);
    final sts = ref.watch(safeToSpendProvider);
    Future<void> refresh() async { await ref.read(ledgerProvider.notifier).refresh(); ref.invalidate(insightsProvider); }
    return TickPage(
      title: 'Insights', trailing: const AskButton(), onRefresh: refresh, bottomPad: 130,
      children: [
        if (l.offline) OfflineBanner(onRetry: refresh),
        switch (data) {
          AsyncData(:final value) => _Body(d: value, ledger: l, sts: sts),
          AsyncError(:final error) => ErrorState(title: 'Insights didn\'t load', body: describeError(error, action: 'load Insights'), onRetry: refresh),
          _ => const Column(children: [Skeleton(height: 150, radius: 24), SizedBox(height: 12), Skeleton(height: 220, radius: 24), SizedBox(height: 12), Skeleton(height: 160, radius: 24)]),
        },
      ],
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.d, required this.ledger, required this.sts});
  final InsightsData d;
  final LedgerState ledger;
  final SafeToSpend? sts;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    if (d.cur.count == 0 && d.prevFull.count == 0) {
      return const EmptyState('Not enough yet', 'Give it a week of purchases and Tick shows where it goes.', icon: 'insights');
    }
    final month = DateFormat('MMMM').format(d.now);
    final vs = d.vsLast;
    final cats = d.categories.take(6).toList();
    final maxCat = cats.isEmpty ? 1 : cats.map((r) => r.$2 > r.$3 ? r.$2 : r.$3).reduce((a, b) => a > b ? a : b);
    final up = vs != null && vs > 0.15;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // 1. This month vs last
      TickCard(
        raised: true,
        child: Semantics(
          label: '${formatCents(d.cur.outCents)} spent in $month so far${vs == null ? '' : ', ${(vs.abs() * 100).round()} percent ${vs <= 0 ? 'less' : 'more'} than last month at this point'}', excludeSemantics: true,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Spent in $month', style: context.ts(TickType.bodyS, size: 13, color: c.textSecondary).copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: RollingNumber(value: d.cur.outCents, builder: (_, v) => Text(formatDollars(v), style: context.ts(TickType.hero, size: 48)))),
            const SizedBox(height: 6),
            if (vs != null)
              Text('${(vs.abs() * 100).round()}% ${vs <= 0 ? 'less' : 'more'} than last month at this point', style: context.ts(TickType.body, color: up ? c.alert : c.text))
            else
              Text('Last month isn\'t there to compare yet.', style: context.ts(TickType.body, color: c.textSecondary)),
            const SizedBox(height: 12),
            _Compare(label: month, cents: d.cur.outCents, max: d.cur.outCents > d.prevSame.outCents ? d.cur.outCents : d.prevSame.outCents, strong: true),
            const SizedBox(height: 6),
            _Compare(label: 'Last month, same days', cents: d.prevSame.outCents, max: d.cur.outCents > d.prevSame.outCents ? d.cur.outCents : d.prevSame.outCents, strong: false),
            if (d.projectedCents != null) ...[
              const SizedBox(height: 12),
              Text('On pace for ${formatDollars(d.projectedCents!)}${d.prevFull.outCents > 0 ? '. Last month ended at ${formatDollars(d.prevFull.outCents)}.' : '.'}', style: context.ts(TickType.bodyS, color: c.textSecondary)),
            ],
            const SizedBox(height: 4),
            Text('In ${formatDollars(d.cur.inCents)} · Out ${formatDollars(d.cur.outCents)}. ${d.cur.friendsIncluded ? 'Transfers and card payments aren\'t counted.' : 'Transfers, card payments and money with friends aren\'t counted.'}', style: context.ts(TickType.bodyS, size: 12.5, color: c.textSecondary)),
          ]),
        ),
      ),
      // 2. Where it went
      const SectionLabel('Where it went'),
      if (cats.isEmpty)
        TickCard(child: Text('No spending yet this month.', style: context.ts(TickType.body, color: c.textSecondary)))
      else
        TickCard(padding: const EdgeInsets.fromLTRB(16, 4, 16, 8), child: Column(children: [
          for (final (i, r) in cats.indexed) ...[
            if (i > 0) const Hairline(),
            StaggerIn(scope: 'insights', index: i, child: _CatRow(name: r.$1 == 'none' ? 'Other' : (ledger.category(r.$1)?.name ?? 'Other'), now: r.$2, before: r.$3, max: maxCat,
                onTap: r.$1 == 'none' ? null : () => openActivity(ref, ActivityQuery(categories: {r.$1})))),
          ],
        ])),
      // 2b. Money with friends: one net line, out of the totals unless the toggle says otherwise
      if (d.cur.friendsCount > 0 || d.prevFull.friendsCount > 0 || d.cur.friendsIncluded) FriendsSection(t: d.cur, onToggle: (v) async {
        await ref.read(settingsProvider.notifier).setIncludeFriends(v);
        await ref.read(ledgerProvider.notifier).refresh();
        ref.invalidate(insightsProvider);
      }, onOpen: () {
        final id = ledger.categories.where((x) => x.name == 'Friends and family').firstOrNull?.id;
        if (id != null) openActivity(ref, ActivityQuery(categories: {id}));
      }),
      // 3. Top merchants
      if (d.merchants.isNotEmpty) ...[
        const SectionLabel('Top merchants'),
        TickCard(padding: const EdgeInsets.symmetric(horizontal: 16), child: Column(children: [
          for (final (i, m) in d.merchants.indexed) ...[
            if (i > 0) const Hairline(),
            Pressable(
              onTap: () => openActivity(ref, ActivityQuery(query: m.merchant)), scale: 0.99, semanticLabel: '${m.merchant}, ${formatCents(m.cents)}, ${m.count} ${m.count == 1 ? 'purchase' : 'purchases'}. Show in Activity',
              child: Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Row(children: [
                Avatar(m.merchant, 'shop', size: 32), const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(m.merchant, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.ts(TickType.title, size: 15.5)),
                  Text('${m.count} ${m.count == 1 ? 'purchase' : 'purchases'}', style: context.ts(TickType.bodyS, size: 12.5, color: c.textSecondary)),
                ])),
                const SizedBox(width: 8),
                Text(formatCents(m.cents), style: context.ts(TickType.mono)),
              ])),
            ),
          ],
        ])),
      ],
      // 4. Subscriptions and price changes
      if (ledger.recurring.isNotEmpty) _Subscriptions(recurring: ledger.recurring),
      // 5. Ahead: card bills and cash runway
      if (sts != null) _Ahead(sts: sts!, ledger: ledger),
    ]);
  }
}

/// Friends and family as ONE net line: mostly paybacks and Splitwise settling, so it says nothing about spending.
class FriendsSection extends StatefulWidget {
  const FriendsSection({super.key, required this.t, required this.onToggle, this.onOpen});
  final Totals t;
  final Future<void> Function(bool) onToggle;
  final VoidCallback? onOpen;
  @override
  State<FriendsSection> createState() => _FriendsSectionState();
}

class _FriendsSectionState extends State<FriendsSection> {
  String? _error;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final t = widget.t;
    final net = t.friendsNetCents;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SectionLabel('Money with friends'),
      TickCard(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Pressable(
          onTap: widget.onOpen, scale: 0.99, semanticLabel: 'Friends and family, ${formatCents(net.abs())} net ${net < 0 ? 'out' : 'in'}. Show in Activity',
          child: Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Friends and family', style: context.ts(TickType.title, size: 15.5)),
              Text('In ${formatDollars(t.friendsInCents)} · Out ${formatDollars(t.friendsOutCents)}', style: context.ts(TickType.bodyS, size: 12.5, color: c.textSecondary)),
            ])),
            const SizedBox(width: 8),
            Money(net),
          ]),
        ),
        const SizedBox(height: 6),
        const Hairline(),
        Row(children: [
          Expanded(child: Text('Include money with friends', style: context.ts(TickType.body))),
          TickToggle(on: t.friendsIncluded, label: 'Include money with friends', onChanged: (v) async {
            setState(() => _error = null);
            try { await widget.onToggle(v); } catch (e) { if (mounted) setState(() => _error = describeError(e, action: 'change that')); }
          }),
        ]),
        Text(t.friendsIncluded ? 'Counted in spending and income.' : 'Not in spending, income or budgets.', style: context.ts(TickType.bodyS, size: 12.5, color: c.textSecondary)),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(_error!, style: context.ts(TickType.bodyS, size: 12.5, color: c.alert))),
      ])),
    ]);
  }
}

class _Compare extends StatelessWidget {
  const _Compare({required this.label, required this.cents, required this.max, required this.strong});
  final String label;
  final int cents;
  final int max;
  final bool strong;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final f = max == 0 ? 0.0 : (cents / max).clamp(0.0, 1.0);
    return Row(children: [
      SizedBox(width: 112, child: Text(label, maxLines: 2, style: context.ts(TickType.bodyS, size: 12.5, color: c.textSecondary))),
      Expanded(child: LayoutBuilder(builder: (context, box) => DecoratedBox(
        decoration: BoxDecoration(color: c.surface2, borderRadius: BorderRadius.circular(999)),
        child: Align(alignment: Alignment.centerLeft, child: Container(height: 8, width: box.maxWidth * f, decoration: BoxDecoration(color: strong ? c.text : c.textSecondary, borderRadius: BorderRadius.circular(999)))),
      ))),
    ]);
  }
}

class _CatRow extends StatelessWidget {
  const _CatRow({required this.name, required this.now, required this.before, required this.max, this.onTap});
  final String name;
  final int now;
  final int before;
  final int max;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final delta = before == 0 ? null : (now - before) / before;
    final hot = delta != null && delta > 0.25 && now - before > 2000;
    final deltaText = delta == null ? (now > 0 ? 'New this month' : '') : '${delta <= 0 ? '−' : '+'}${(delta.abs() * 100).round()}% vs last month';
    return Pressable(
      onTap: onTap, scale: 0.99, semanticLabel: '$name ${formatCents(now)}${deltaText.isEmpty ? '' : ', $deltaText'}. Show in Activity',
      child: Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.ts(TickType.title, size: 15.5))),
          const SizedBox(width: 8),
          Text(formatCents(now), style: context.ts(TickType.mono)),
        ]),
        const SizedBox(height: 6),
        LayoutBuilder(builder: (context, box) => DecoratedBox(
          decoration: BoxDecoration(color: c.surface2, borderRadius: BorderRadius.circular(999)),
          child: Align(alignment: Alignment.centerLeft, child: Container(height: 6, width: box.maxWidth * (max == 0 ? 0 : (now / max).clamp(0.0, 1.0)), decoration: BoxDecoration(color: hot ? c.alert : c.text, borderRadius: BorderRadius.circular(999)))),
        )),
        if (deltaText.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(deltaText, style: context.ts(TickType.bodyS, size: 12.5, color: hot ? c.alert : c.textSecondary))),
      ])),
    );
  }
}

class _Subscriptions extends StatelessWidget {
  const _Subscriptions({required this.recurring});
  final List<Recurring> recurring;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    int monthly(Recurring r) => switch (r.cadence) { Cadence.weekly => (r.expectedCents * 52 / 12).round(), Cadence.biweekly => (r.expectedCents * 26 / 12).round(), Cadence.monthly => r.expectedCents, Cadence.yearly => (r.expectedCents / 12).round() };
    final list = recurring.toList()..sort((a, b) => monthly(b).compareTo(monthly(a)));
    final total = list.fold<int>(0, (s, r) => s + monthly(r));
    final hikes = list.where((r) => r.priceWentUp).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionLabel('Subscriptions and bills', trailing: Text('${formatDollars(total)} a month', style: context.ts(TickType.monoS, color: c.textSecondary))),
      TickCard(padding: const EdgeInsets.symmetric(horizontal: 16), child: Column(children: [
        for (final (i, r) in list.take(5).indexed) ...[
          if (i > 0) const Hairline(),
          Padding(padding: const EdgeInsets.symmetric(vertical: 11), child: Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(r.merchant, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.ts(TickType.title, size: 15.5)),
              if (r.priceWentUp) Text('Was ${formatCents(r.previousPrice!)}. Went up ${formatCents(r.expectedCents - r.previousPrice!)}.', style: context.ts(TickType.bodyS, size: 12.5, color: c.alert)),
            ])),
            const SizedBox(width: 8),
            Text(formatCents(r.expectedCents), style: context.ts(TickType.mono)),
          ])),
        ],
        if (hikes.isEmpty) Padding(padding: const EdgeInsets.only(bottom: 10), child: Text('No price changes lately.', style: context.ts(TickType.bodyS, color: c.textSecondary))),
      ])),
    ]);
  }
}

class _Ahead extends StatelessWidget {
  const _Ahead({required this.sts, required this.ledger});
  final SafeToSpend sts;
  final LedgerState ledger;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final day = DateFormat('EEEE').format(sts.nextPayday);
    final perDay = sts.daysToPayday <= 0 ? null : (sts.cents / sts.daysToPayday).floor();
    final firstDue = ledger.accounts.where((a) => a.isCard && a.dueDate != null && a.statementDueCents > 0).toList()..sort((a, b) => a.dueDate!.compareTo(b.dueDate!));
    Widget line(String label, int cents, {bool strong = false, VoidCallback? onTap}) => Pressable(
          onTap: onTap, scale: 0.99, semanticLabel: '$label ${formatCents(cents)}',
          child: Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Row(children: [
            Expanded(child: Text(label, style: context.ts(strong ? TickType.title : TickType.body, size: strong ? 16 : 15, color: strong ? c.text : c.textSecondary))),
            Text(formatCents(cents), style: context.ts(TickType.mono, color: strong && cents < 0 ? c.alert : null)),
          ])),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionLabel('Ahead until $day'),
      TickCard(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        line('Cash in checking', sts.cashCents),
        if (sts.billsCents > 0) line('Bills', -sts.billsCents),
        if (sts.cardsDueCents > 0) line('Card statements due', -sts.cardsDueCents, onTap: firstDue.isEmpty ? null : () => context.push('/card/${firstDue.first.id}')),
        if (sts.loansDueCents > 0) line('Loan payment', -sts.loansDueCents),
        if (sts.goalsCents > 0) line('Goals', -sts.goalsCents),
        const Hairline(),
        line('Safe to spend', sts.cents, strong: true),
        if (perDay != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(
            sts.cents < 0 ? 'Bills and cards are ahead of your cash. Check what can wait.' : '${formatDollars(perDay)} a day for ${sts.daysToPayday} ${sts.daysToPayday == 1 ? 'day' : 'days'}.',
            style: context.ts(TickType.bodyS, color: sts.cents < 0 ? c.alert : c.textSecondary))),
        if (sts.cardsLaterCents > 0) Padding(padding: const EdgeInsets.only(top: 4), child: Text('${formatDollars(sts.cardsLaterCents)} more on cards isn\'t due until after payday.', style: context.ts(TickType.bodyS, size: 12.5, color: c.textSecondary))),
      ])),
    ]);
  }
}
