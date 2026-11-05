import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../data/activity.dart';
import '../data/ledger.dart';
import '../data/settings.dart';
import '../domain/flows.dart';
import '../domain/ideas.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../design/widgets/more.dart';
import '../design/widgets/scaffold.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import '../domain/payday.dart';
import 'common.dart';

/// Utilisation above this reads as "high" (the usual credit-score guidance).
const highUtilisation = 0.30;

/// One plain-words line about the statement: due, paid, or not shared. Consistent with the card screen and Safe to spend.
String dueLine(Account a, DateTime now) {
  if (a.owedCents == 0) return 'Paid off';
  if (a.statementBalanceCents == null) return a.dueDate == null ? 'The bank shares the balance, not the statement' : 'Due ${DateFormat('MMM d').format(a.dueDate!)}';
  if (a.statementPaid) return a.newSinceStatementCents > 0 ? 'Statement paid · ${formatDollars(a.newSinceStatementCents)} new' : 'Statement paid';
  final d = a.dueDate;
  if (d == null) return '${formatDollars(a.statementDueCents)} due, date not shared';
  final days = dayOnly(d).difference(dayOnly(now)).inDays;
  final when = days < 0 ? 'was due ${DateFormat('MMM d').format(d)}' : days == 0 ? 'due today' : days == 1 ? 'due tomorrow' : days < 7 ? 'due ${DateFormat('EEEE').format(d)}' : 'due ${DateFormat('MMM d').format(d)}';
  return '${formatDollars(a.statementDueCents)} $when';
}

/// Why the numbers look the way they do, in words, when the bank's data is partial or the statement is paid.
String? statementExplainer(Account a) {
  if (a.owedCents == 0) return null;
  if (a.statementBalanceCents == null) return 'Your bank shares what you owe, but not the statement. Check the bank\'s app for the due date.';
  if (a.statementPaid) {
    return a.newSinceStatementCents > 0
        ? 'The last statement is paid. ${formatCents(a.newSinceStatementCents)} is new spending since it closed, and it is due with your next statement.'
        : 'The last statement is paid.';
  }
  if (a.knownMinimumCents == null) return 'Your bank didn\'t share a minimum payment. Pay the statement balance to avoid interest.';
  return null;
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
  final m = monthOf(now);
  final t = await src.totals(const ActivityQuery(), from: etToUtc(m), to: etToUtc(DateTime(m.year, m.month + 1, 1)));
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
      return TickPage(title: 'Card', onBack: () => context.pop(), children: const [EmptyState('This card isn\'t here any more', 'It may have been removed from its bank link.', icon: 'card')]);
    }
    final months = ref.watch(cardMonthsProvider(id));
    final u = a.utilisation;
    String? apr = a.aprBps == null ? null : '${(a.aprBps! / 100).toStringAsFixed(2)}%';
    return TickPage(
      title: a.shortLabel, onBack: () => context.pop(),
      children: [
        Semantics(label: '${formatCents(a.owedCents)} owed', excludeSemantics: true, child: Text(formatCents(a.owedCents), style: context.ts(TickType.hero))),
        Text(dueLine(a, now), style: context.ts(TickType.body, color: c.textSecondary)),
        if (statementExplainer(a) case final why?) Padding(padding: const EdgeInsets.only(top: 6), child: Text(why, style: context.ts(TickType.bodyS, color: c.textSecondary))),
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
          _KV('Minimum payment', a.knownMinimumCents == null ? 'Not shared by the bank' : formatCents(a.knownMinimumCents!)),
          _KV('Available credit', a.availableCreditCents == null ? '—' : formatCents(a.availableCreditCents!)),
          if (apr != null) _KV('Purchase APR', apr),
        ])),
        if (ref.watch(settingsProvider.select((x) => x.flag('statement_cycle'))))
          if (statementCycle(a, now) case final cy?) ...[
            const SectionLabel('Statement cycle'),
            TickCard(child: Semantics(
              label: 'Statement closes ${DateFormat('MMMM d').format(cy.closes)}. ${_cycleLine(a, cy, now)}', excludeSemantics: true,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Expanded(child: Text('Closes ${DateFormat('EEE MMM d').format(cy.closes)}', style: context.ts(TickType.title, size: 16))),
                  Text(cy.daysToClose == 0 ? 'today' : 'in ${cy.daysToClose} ${cy.daysToClose == 1 ? 'day' : 'days'}', style: context.ts(TickType.monoS, color: c.textSecondary)),
                ]),
                const SizedBox(height: 6),
                Text(_cycleLine(a, cy, now), style: context.ts(TickType.bodyS, color: cy.payForUnder30Cents > 0 ? c.alert : c.textSecondary)),
                if (cy.dueDays != null && cy.statementDueCents > 0) ...[
                  const SizedBox(height: 10),
                  const Hairline(),
                  const SizedBox(height: 10),
                  Text(cy.dueDays! < 0 ? 'Statement was due ${-cy.dueDays!} ${cy.dueDays == -1 ? 'day' : 'days'} ago.'
                      : 'Pay ${formatDollars(cy.statementDueCents)} in full within ${cy.dueDays} ${cy.dueDays == 1 ? 'day' : 'days'} and there is no interest.',
                      style: context.ts(TickType.bodyS, color: c.textSecondary)),
                ],
              ]),
            )),
          ],
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
      ],
    );
  }
}

String _cycleLine(Account a, Cycle cy, DateTime now) => cy.payForUnder30Cents > 0
    ? 'Pay ${formatDollars(cy.payForUnder30Cents)} by ${DateFormat('EEE MMM d').format(cy.bestPayDay)} and the statement reports under 30% of your limit.'
    : 'Your balance is under 30% of the limit. Nothing to do before it closes.';

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
