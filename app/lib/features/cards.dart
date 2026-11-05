import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../data/activity.dart';
import '../data/ledger.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../design/widgets/more.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import '../domain/payday.dart';
import 'common.dart';

/// Utilisation above this reads as "high" (the usual credit-score guidance).
const highUtilisation = 0.30;

String dueLine(Account a, DateTime now) {
  final d = a.dueDate;
  if (d == null) return a.owedCents == 0 ? 'Paid off' : 'Due date not shared by the bank';
  final days = dayOnly(d).difference(dayOnly(now)).inDays;
  final when = days < 0 ? 'was due ${DateFormat('MMM d').format(d)}' : days == 0 ? 'due today' : days == 1 ? 'due tomorrow' : days < 7 ? 'due ${DateFormat('EEEE').format(d)}' : 'due ${DateFormat('MMM d').format(d)}';
  final due = a.statementDueCents;
  return due == 0 ? 'Statement paid' : '${formatDollars(due)} $when';
}

/// The thin utilisation bar: neutral below 30%, Clay above it.
class UtilisationBar extends StatelessWidget {
  const UtilisationBar({super.key, required this.value});
  final double value;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final v = value.clamp(0.0, 1.0);
    return Semantics(
      excludeSemantics: true,
      child: SizedBox(
        height: 6, width: double.infinity,
        child: LayoutBuilder(builder: (context, box) => DecoratedBox(
          decoration: BoxDecoration(color: c.surface2, borderRadius: BorderRadius.circular(999)),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Container(width: box.maxWidth * v, decoration: BoxDecoration(color: value >= highUtilisation ? c.alert : c.text, borderRadius: BorderRadius.circular(999))),
          ),
        )),
      ),
    );
  }
}

class CardTile extends StatelessWidget {
  const CardTile({super.key, required this.a, required this.now, this.spentThisMonth, this.onTap});
  final Account a;
  final DateTime now;
  final int? spentThisMonth;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final u = a.utilisation;
    final dueSoon = a.dueDate != null && a.statementDueCents > 0 && dayOnly(a.dueDate!).difference(dayOnly(now)).inDays <= 3;
    return TickCard(
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      child: Semantics(
        label: '${a.shortLabel}, ${formatCents(a.owedCents)} owed, ${dueLine(a, now)}${u == null ? '' : ', ${(u * 100).round()} percent of the limit used'}'
            '${spentThisMonth == null ? '' : ', ${formatCents(spentThisMonth!)} spent this month'}',
        excludeSemantics: true,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Avatar(a.institution ?? a.name, 'biz', size: 32), const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(a.shortLabel, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.ts(TickType.title, size: 16)),
              Text(dueLine(a, now), maxLines: 2, style: context.ts(TickType.bodyS, color: dueSoon ? c.alert : c.textSecondary)),
            ])),
            const SizedBox(width: 8),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(formatCents(a.owedCents), style: context.ts(TickType.mono)),
              Text('owed', style: context.ts(TickType.bodyS, size: 12, color: c.textSecondary)),
            ]),
          ]),
          if (u != null) ...[
            const SizedBox(height: 10),
            UtilisationBar(value: u),
            const SizedBox(height: 6),
            Row(children: [
              Expanded(child: Text('${(u * 100).round()}% of ${formatDollars(a.creditLimitCents!)} used', style: context.ts(TickType.bodyS, size: 12.5, color: c.textSecondary))),
              if (spentThisMonth != null) Text('${formatDollars(spentThisMonth!)} this month', style: context.ts(TickType.monoS, size: 12, color: c.textSecondary)),
            ]),
          ],
        ]),
      ),
    );
  }
}

class LoanTile extends StatelessWidget {
  const LoanTile({super.key, required this.a, required this.now});
  final Account a;
  final DateTime now;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final next = a.nextPaymentCents ?? a.minimumPaymentCents;
    final rate = a.interestRateBps == null ? null : '${(a.interestRateBps! / 100).toStringAsFixed(2)}%';
    final line = [
      if (next != null && a.dueDate != null) 'Next ${formatDollars(next)} ${weekdayName(a.dueDate!, now) == 'today' ? 'today' : 'on ${DateFormat('MMM d').format(a.dueDate!)}'}',
      ?rate,
    ].join(' · ');
    return TickCard(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Semantics(
        label: '${a.shortLabel} student loan, ${formatCents(a.owedCents)} left${line.isEmpty ? '' : ', $line'}', excludeSemantics: true,
        child: Row(children: [
          Avatar(a.institution ?? a.name, 'home', size: 32), const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(a.subtype == 'student' ? '${a.institution ?? a.name} student loan' : a.shortLabel, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.ts(TickType.title, size: 16)),
            Text(line.isEmpty ? 'Payment details not shared by the bank' : line, style: context.ts(TickType.bodyS, color: c.textSecondary)),
          ])),
          const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(formatDollars(a.owedCents), style: context.ts(TickType.mono)),
            Text('left', style: context.ts(TickType.bodyS, size: 12, color: c.textSecondary)),
          ]),
        ]),
      ),
    );
  }
}

/// Cards (owed, due date, utilisation) and loans. Used on Today and on Banks.
class CardsSection extends ConsumerWidget {
  const CardsSection({super.key, this.showSpend = false, this.compact = false});
  final bool showSpend;
  /// Today: one card with a row per credit card instead of a tile each.
  final bool compact;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = ref.watch(ledgerProvider);
    final now = ref.watch(clockProvider)();
    final cards = l.accounts.where((a) => a.isCard).toList()..sort((a, b) => (a.dueDate ?? DateTime(9999)).compareTo(b.dueDate ?? DateTime(9999)));
    final loans = l.accounts.where((a) => a.isLoan).toList();
    if (cards.isEmpty && loans.isEmpty) return const SizedBox.shrink();
    final spend = showSpend ? ref.watch(monthFlowsProvider(dayOnly(now))).value : null;
    final perCard = showSpend ? ref.watch(monthSpendByAccountProvider(dayOnly(now))).value : null;
    final owed = cards.fold<int>(0, (s, a) => s + a.owedCents);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (cards.isNotEmpty && compact) ...[
        SectionLabel('Cards', trailing: Text('${formatDollars(owed)} owed', style: context.ts(TickType.monoS, color: context.c.textSecondary))),
        TickCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Column(children: [
            for (final (i, a) in cards.indexed) ...[
              if (i > 0) const Hairline(),
              _CompactCardRow(a: a, now: now),
            ],
          ]),
        ),
        const SizedBox(height: 8),
      ] else if (cards.isNotEmpty) ...[
        SectionLabel('Cards', trailing: Text('${formatDollars(owed)} owed', style: context.ts(TickType.monoS, color: context.c.textSecondary))),
        for (final a in cards) ...[
          CardTile(a: a, now: now, spentThisMonth: perCard?[a.id] ?? (spend == null ? null : 0), onTap: () => context.push('/card/${a.id}')),
          const SizedBox(height: 8),
        ],
      ],
      if (loans.isNotEmpty) ...[
        const SectionLabel('Loans'),
        for (final a in loans) ...[LoanTile(a: a, now: now), const SizedBox(height: 8)],
      ],
    ]);
  }
}

class _CompactCardRow extends StatelessWidget {
  const _CompactCardRow({required this.a, required this.now});
  final Account a;
  final DateTime now;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final u = a.utilisation;
    final dueSoon = a.dueDate != null && a.statementDueCents > 0 && dayOnly(a.dueDate!).difference(dayOnly(now)).inDays <= 3;
    return Pressable(
      onTap: () => context.push('/card/${a.id}'), scale: 0.985,
      semanticLabel: '${a.shortLabel}, ${formatCents(a.owedCents)} owed, ${dueLine(a, now)}${u == null ? '' : ', ${(u * 100).round()} percent used'}',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text(a.shortLabel, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.ts(TickType.title, size: 15.5))),
            Text(formatCents(a.owedCents), style: context.ts(TickType.mono)),
          ]),
          const SizedBox(height: 2),
          Text(dueLine(a, now), style: context.ts(TickType.bodyS, size: 13, color: dueSoon ? c.alert : c.textSecondary)),
          if (u != null) ...[const SizedBox(height: 6), UtilisationBar(value: u)],
        ]),
      ),
    );
  }
}

/// Spend this month per account (card purchases minus refunds), from the server's totals.
final monthSpendByAccountProvider = FutureProvider.family<Map<String, int>, DateTime>((ref, now) async {
  ref.watch(ledgerRevisionProvider);
  final src = ref.watch(activitySourceProvider);
  final t = await src.totals(ActivityQuery(month: monthOf(now)));
  return t.byAccount;
});

/// Card spend by month (newest first) for one account, from the server.
final cardMonthsProvider = FutureProvider.family<List<MonthSummary>, String>((ref, accountId) async {
  ref.watch(ledgerRevisionProvider);
  return ref.watch(activitySourceProvider).months(ActivityQuery(accounts: {accountId}));
});

class CardScreen extends ConsumerWidget {
  const CardScreen({super.key, required this.id});
  final String id;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = ref.watch(ledgerProvider);
    final now = ref.watch(clockProvider)();
    final a = l.account(id);
    final c = context.c;
    if (a == null) {
      return TickScreen(child: Column(children: [ScreenTitle('Card', onBack: () => context.pop()), const EmptyState('This card isn\'t here any more', 'It may have been removed from its bank link.', icon: 'card')]));
    }
    final months = ref.watch(cardMonthsProvider(id));
    final u = a.utilisation;
    String? apr = a.aprBps == null ? null : '${(a.aprBps! / 100).toStringAsFixed(2)}%';
    return TickScreen(
      child: ListView(padding: const EdgeInsets.only(bottom: 48), children: [
        ScreenTitle(a.shortLabel, onBack: () => context.pop()),
        Semantics(label: '${formatCents(a.owedCents)} owed', excludeSemantics: true, child: Text(formatCents(a.owedCents), style: context.ts(TickType.hero))),
        Text(dueLine(a, now), style: context.ts(TickType.body, color: c.textSecondary)),
        const SizedBox(height: 16),
        TickCard(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (u != null) ...[
            UtilisationBar(value: u),
            const SizedBox(height: 8),
            Text('${(u * 100).round()}% of your ${formatDollars(a.creditLimitCents!)} limit used${u >= highUtilisation ? '. Paying some before the statement closes keeps it under 30%.' : '.'}',
                style: context.ts(TickType.bodyS, color: c.textSecondary)),
            const SizedBox(height: 12),
          ],
          _KV('Last statement', a.statementBalanceCents == null ? 'Not shared by the bank' : formatCents(a.statementBalanceCents!)),
          _KV('Minimum payment', a.minimumPaymentCents == null ? '—' : formatCents(a.minimumPaymentCents!)),
          _KV('Available credit', a.availableCreditCents == null ? '—' : formatCents(a.availableCreditCents!)),
          if (apr != null) _KV('Purchase APR', apr),
        ])),
        const SectionLabel('Spent on this card'),
        switch (months) {
          AsyncData(:final value) when value.isEmpty => TickCard(child: Text('No purchases on this card yet.', style: context.ts(TickType.body, color: c.textSecondary))),
          AsyncData(:final value) => TickCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Column(children: [
                for (final (i, m) in value.take(6).indexed) ...[
                  if (i > 0) const Hairline(),
                  Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Semantics(
                    label: '${DateFormat('MMMM y').format(m.month)}: ${formatCents(m.totals.outCents)} spent', excludeSemantics: true,
                    child: Row(children: [
                      Expanded(child: Text(DateFormat('MMMM y').format(m.month), style: context.ts(TickType.body))),
                      Text(formatCents(m.totals.outCents), style: context.ts(TickType.mono)),
                    ]),
                  )),
                ],
              ]),
            ),
          AsyncError() => ErrorState(onRetry: () async => ref.invalidate(cardMonthsProvider(id))),
          _ => const ListSkeleton(rows: 3),
        },
        const SizedBox(height: 12),
        Text('Tick never pays bills or moves money. Pay from your bank\'s app.', style: context.ts(TickType.bodyS, color: c.textSecondary)),
      ]),
    );
  }
}

class _KV extends StatelessWidget {
  const _KV(this.k, this.v);
  final String k;
  final String v;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          Expanded(child: Text(k, style: context.ts(TickType.body, color: context.c.textSecondary))),
          Text(v, style: context.ts(TickType.mono)),
        ]),
      );
}
