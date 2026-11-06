import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../data/ledger.dart';
import '../design/motion.g.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../design/widgets/more.dart';
import '../design/widgets/refresh.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import '../domain/payday.dart';
import '../services/haptics.dart';
import 'common.dart';

class IncomingScreen extends ConsumerWidget {
  const IncomingScreen({super.key, this.landed});
  final Expected? landed; // shows the Landed stamp banner when money just arrived
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = ref.watch(ledgerProvider);
    final now = ref.watch(clockProvider)();
    final c = context.c;
    final today = dayOnly(now);
    final incoming = [...l.expected]..sort((a, b) => a.date.compareTo(b.date));
    final horizon = today.add(const Duration(days: 30));
    final bills = l.recurring.where((r) => r.nextDate.isBefore(horizon)).toList()..sort((a, b) => a.nextDate.compareTo(b.nextDate));
    final inTotal = incoming.fold(0, (s, e) => s + e.amountCents);
    final billTotal = bills.fold(0, (s, r) => s + r.expectedCents);
    return TickScreen(
      child: TickScrollView(onRefresh: ref.read(ledgerProvider.notifier).refresh, slivers: [SliverToBoxAdapter(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ScreenTitle('Coming up', onBack: () => context.pop()),
        if (l.offline) OfflineBanner(onRetry: ref.read(ledgerProvider.notifier).refresh),
        if (l.loading && l.recurring.isEmpty && l.expected.isEmpty) const ListSkeleton(rows: 6) else ...[
        if (landed != null) PopIn(onLanded: () => TickHaptics.instance.landed(), fromScale: 1.15, spring: TickSprings.pop,
            child: TickCard(color: c.accent, child: Row(children: [
              Transform.rotate(angle: -0.1, child: Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6), decoration: BoxDecoration(border: Border.all(color: c.onAccent, width: 3), borderRadius: BorderRadius.circular(999)), child: Text('Landed.', style: context.ts(TickType.displayM, color: c.onAccent, size: 20)))),
              const SizedBox(width: 16), Expanded(child: Text('${formatDollars(landed!.amountCents)} from ${landed!.kind == ExpectedKind.paycheck ? landed!.label.toLowerCase() : landed!.label.replaceAll(RegExp(r' owes you\$'), '')}.', style: context.ts(TickType.title, color: c.onAccent, size: 15.5))),
            ]))),
        SectionLabel('Incoming${incoming.isEmpty ? '' : ' · ${formatDollars(inTotal)}'}', color: c.incoming),
        if (incoming.isEmpty)
          TickCard(child: Text('Nothing coming in yet. Add your paycheck and Tick will watch for it.', style: context.ts(TickType.body, color: c.textSecondary)))
        else
          TickCard(padding: const EdgeInsets.symmetric(horizontal: 16), child: Column(children: [
            for (var i = 0; i < incoming.length; i++) ...[
              if (i > 0) const Hairline(),
              _Row(letter: incoming[i].label, key2: 'inc', title: incoming[i].label, sub: '${incoming[i].kind == ExpectedKind.paycheck ? 'Payday · ' : ''}${weekdayName(incoming[i].date, now)}', cents: incoming[i].amountCents, kind: MoneyKind.expected),
            ],
          ])),
        SectionLabel('Upcoming${bills.isEmpty ? '' : ' · ${formatDollars(billTotal)}'}', color: c.alert),
        if (bills.isEmpty)
          TickCard(child: Text('Nothing due before payday.', style: context.ts(TickType.body, color: c.textSecondary)))
        else
          TickCard(padding: const EdgeInsets.symmetric(horizontal: 16), child: Column(children: [
            for (var i = 0; i < bills.length; i++) ...[
              if (i > 0) const Hairline(),
              _Row(
                letter: bills[i].merchant, key2: l.category(bills[i].categoryId)?.colorKey ?? 'home', title: bills[i].merchant,
                sub: bills[i].priceWentUp ? '${DateFormat('EEE MMM d').format(bills[i].nextDate)} · was ${formatDollars(bills[i].previousPrice!)}' : DateFormat('EEE MMM d').format(bills[i].nextDate), subAlert: bills[i].priceWentUp,
                cents: -bills[i].expectedCents, kind: MoneyKind.out,
              ),
            ],
          ])),
        ],
        const SizedBox(height: 40),
      ]))]),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.letter, required this.key2, required this.title, required this.sub, required this.cents, required this.kind, this.subAlert = false});
  final String letter, key2, title, sub;
  final int cents;
  final MoneyKind kind;
  final bool subAlert;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(children: [
          Avatar(letter, key2), const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.ts(TickType.title, size: 16)),
            Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.ts(TickType.bodyS, color: subAlert ? context.c.alert : context.c.textSecondary)),
          ])),
          const SizedBox(width: 8), ConstrainedBox(constraints: const BoxConstraints(maxWidth: 120), child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight, child: Money(cents, kind: kind))),
        ]),
      );
}
