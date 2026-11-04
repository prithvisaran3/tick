import 'dart:math' as math;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../data/ledger.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../design/widgets/more.dart';
import '../design/widgets/refresh.dart';
import '../domain/flows.dart';
import '../domain/money.dart';
import 'common.dart';

class FlowsScreen extends ConsumerStatefulWidget {
  const FlowsScreen({super.key});
  @override
  ConsumerState<FlowsScreen> createState() => _FlowsScreenState();
}

class _FlowsScreenState extends ConsumerState<FlowsScreen> {
  bool? _last; // null = automatic: early in the month show last month, which has a full picture
  @override
  Widget build(BuildContext context) {
    final l = ref.watch(ledgerProvider);
    final real = ref.watch(clockProvider)();
    final showLast = _last ?? real.day < 8;
    final now = showLast ? DateTime(real.year, real.month, 0, 12) : real;
    final c = context.c;
    final f = computeFlows(l.txns, now);
    final cats = f.byCategory.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final maxCat = cats.isEmpty ? 1 : cats.first.value;
    final vs = f.vsLast;
    return TickScrollView(onRefresh: ref.read(ledgerProvider.notifier).refresh, slivers: [SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.only(bottom: 130), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ScreenTitle('Flows', trailing: TickChip(DateFormat('MMMM').format(now), onTap: () => setState(() => _last = !showLast))),
      if (l.offline) OfflineBanner(onRetry: ref.read(ledgerProvider.notifier).refresh),
      if (l.loading && l.txns.isEmpty) ...[const Skeleton(height: 90, radius: 24), const SizedBox(height: 8), const ListSkeleton(rows: 3)] else if (l.offline && l.txns.isEmpty)
        ErrorState(onRetry: ref.read(ledgerProvider.notifier).refresh)
      else if (l.txns.isEmpty)
        const EmptyState('Not enough data for a trend yet', 'Give it a week.', icon: 'flows')
      else ...[
        Padding(padding: const EdgeInsets.only(top: 8), child: Text(showLast ? (f.netCents >= 0 ? 'Left over in ${DateFormat('MMMM').format(now)}' : 'Over in ${DateFormat('MMMM').format(now)}') : (f.netCents >= 0 ? 'Left this month' : 'Over this month'), style: context.ts(TickType.bodyS, size: 13, color: c.textSecondary).copyWith(fontWeight: FontWeight.w700))),
        Semantics(label: '${formatCents(f.netCents.abs())} ${f.netCents >= 0 ? 'left' : 'over'} this month', child: Text(formatCents(f.netCents, sign: true, whole: true), style: context.ts(TickType.hero, color: f.netCents >= 0 ? c.text : c.alert))),
        Padding(padding: const EdgeInsets.only(top: 4), child: Wrap(spacing: 16, children: [
          Row(mainAxisSize: MainAxisSize.min, children: [Text('In ', style: context.ts(TickType.mono)), Money(f.inCents, sign: false, kind: MoneyKind.income, whole: true, style: context.ts(TickType.mono))]),
          Text('Out ${formatDollars(f.outCents)}', style: context.ts(TickType.mono)),
        ])),
        const SizedBox(height: 16),
        TickCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Flexible(child: Text('Where it went', style: context.ts(TickType.title, size: 16))),
            if (vs != null) Padding(padding: const EdgeInsets.only(left: 8), child: Text('vs ${showLast ? DateFormat('MMM').format(DateTime(now.year, now.month - 1)) : 'last month'}: ${vs <= 0 ? '−' : '+'}${(vs.abs() * 100).round()}%', style: context.ts(TickType.bodyS, color: c.textSecondary))),
          ]),
          if (cats.isEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: Text('No spending yet this month.', style: context.ts(TickType.body, color: c.textSecondary))),
          for (final e in cats.take(5)) Padding(padding: const EdgeInsets.only(top: 12), child: _CatBar(name: l.category(e.key)?.name ?? 'Other', cents: e.value, frac: e.value / maxCat)),
        ])),
        const SizedBox(height: 8),
        TickCard(padding: const EdgeInsets.fromLTRB(16, 12, 16, 12), child: _Heatmap(flows: f, now: now, isCurrent: !showLast)),
        const SizedBox(height: 8),
        TickCard(onTap: () => context.push('/budgets'), padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), child: Row(children: [TickIcon('goal', size: 22, color: c.text), const SizedBox(width: 8), Expanded(child: Text('Budgets and goals', style: context.ts(TickType.title, size: 16))), TickIcon('chevron-right', size: 20, color: c.textSecondary)])),
        const SizedBox(height: 8),
        TickCard(raised: true, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Flexible(child: Row(children: [TickIcon('briefcase', size: 22, color: c.text), const SizedBox(width: 8), Flexible(child: Text('Business', style: context.ts(TickType.title, size: 16)))])),
          Text(formatCents(f.businessCents), style: context.ts(TickType.monoL)),
        ])),
      ],
    ]))),
    ]);
  }
}

class _CatBar extends StatelessWidget {
  const _CatBar({required this.name, required this.cents, required this.frac});
  final String name;
  final int cents;
  final double frac;
  @override
  Widget build(BuildContext context) => Semantics(
        label: '$name ${formatCents(cents)}',
        child: Column(children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(name, style: context.ts(TickType.title, size: 15)), Text(formatDollars(cents), style: context.ts(TickType.mono))]),
          const SizedBox(height: 8),
          LayoutBuilder(builder: (_, cs) => Stack(children: [
            Container(height: 8, decoration: BoxDecoration(color: context.c.surface2, borderRadius: BorderRadius.circular(8))),
            TweenAnimationBuilder<double>(tween: Tween(begin: 0, end: frac), duration: const Duration(milliseconds: 500), curve: Curves.easeOutBack,
                builder: (_, v, _) => Container(width: cs.maxWidth * v.clamp(0.0, 1.0), height: 8, decoration: BoxDecoration(color: context.c.text.withValues(alpha: 0.85), borderRadius: BorderRadius.circular(8)))),
          ])),
        ]),
      );
}

class _Heatmap extends StatelessWidget {
  const _Heatmap({required this.flows, required this.now, required this.isCurrent});
  final bool isCurrent;
  final MonthFlows flows;
  final DateTime now;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final total = daysInMonth(now);
    final lead = firstWeekdaySunday0(now);
    final sorted = flows.dailyOut.values.toList()..sort();
    final maxV = sorted.isEmpty ? 1 : sorted[((sorted.length - 1) * 0.9).floor()].clamp(1, 1 << 40);
    final cells = <Widget>[
      for (final d in 'SMTWTFS'.split('')) Center(child: Text(d, style: context.ts(TickType.bodyS, size: 11, color: c.textSecondary))),
      for (var i = 0; i < lead; i++) const SizedBox(),
      for (var d = 1; d <= total; d++)
        Semantics(
          label: 'Day $d, ${formatCents(flows.dailyOut[d] ?? 0)} spent',
          child: Container(
            decoration: d > now.day
                ? BoxDecoration(borderRadius: BorderRadius.circular(7), border: Border.all(color: c.hairline))
                : BoxDecoration(color: (flows.dailyOut[d] ?? 0) == 0 ? c.surface2 : c.text.withValues(alpha: 0.22 + 0.78 * math.sqrt((flows.dailyOut[d]! / maxV).clamp(0.0, 1.0))), borderRadius: BorderRadius.circular(7),
                    border: isCurrent && d == now.day ? Border.all(color: c.text, width: 2) : null),
          ),
        ),
    ];
    return LayoutBuilder(builder: (_, cs) {
      final w = (cs.maxWidth - 6 * 5) / 7;
      final rows = ((lead + total) / 7).ceil();
      return SizedBox(height: 20 + 5 + rows * (w * 0.55 + 5), child: GridView.count(crossAxisCount: 7, mainAxisSpacing: 5, crossAxisSpacing: 5, childAspectRatio: 1.8, physics: const NeverScrollableScrollPhysics(), padding: EdgeInsets.zero, children: cells));
    });
  }
}
