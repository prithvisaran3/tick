import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../data/ledger.dart';
import '../data/paystubs.dart';
import '../data/remote.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../design/widgets/more.dart';
import '../design/widgets/scaffold.dart';
import '../domain/money.dart';
import '../services/api.dart';
import '../services/haptics.dart';
import 'common.dart';

/// Profile > Pay > Pay statements.
class PayStatementsScreen extends ConsumerStatefulWidget {
  const PayStatementsScreen({super.key});
  @override
  ConsumerState<PayStatementsScreen> createState() => _PayStatementsState();
}

class _PayStatementsState extends ConsumerState<PayStatementsScreen> {
  bool? _keep;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final s = ref.watch(payStatementsProvider);
    return TickPage(title: 'Pay statements', onBack: () => context.pop(), onRefresh: () async => ref.invalidate(payStatementsProvider), children: [
      switch (s) {
        AsyncData(:final value) when value.isEmpty => const EmptyState('No pay statements yet', 'In myADP, open a pay statement, tap Share, then Tick. Or import the PDF here.', icon: 'import'),
        AsyncData(:final value) => TickCard(padding: const EdgeInsets.symmetric(horizontal: TickSpace.x4), child: Column(children: [
            for (final (i, p) in value.indexed) ...[
              if (i > 0) const Hairline(),
              Pressable(onTap: () => context.push('/pay-statements/${p.id}'), scale: 0.99, semanticLabel: '${DateFormat('MMMM d').format(p.payDate)}, ${formatCents(p.netCents)} net',
                child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 56), child: Row(children: [
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(DateFormat('MMM d, y').format(p.payDate), style: context.ts(TickType.body)),
                    Text(p.review ? 'Check this one · ${formatCents(p.grossCents)} gross' : '${formatCents(p.grossCents)} gross', style: context.ts(TickType.bodyS, color: p.review ? c.alert : c.textSecondary)),
                  ])),
                  Text(formatCents(p.netCents), style: context.ts(TickType.mono)),
                ]))),
            ],
          ])),
        AsyncError(:final error) => ErrorState(title: 'Pay statements didn\'t load', body: describeError(error, action: 'load them'), onRetry: () async => ref.invalidate(payStatementsProvider)),
        _ => const ListSkeleton(rows: 4),
      },
      const SizedBox(height: TickSpace.x4),
      PillButton('Import a pay statement', icon: 'import', style: PillStyle.quiet, onTap: () => context.push('/import')),
      const SizedBox(height: TickSpace.x3),
      Row(children: [
        Expanded(child: Text('Keep the PDF', style: context.ts(TickType.body))),
        TickToggle(on: _keep ?? false, label: 'Keep the PDF', onChanged: (v) async {
          setState(() => _keep = v);
          final r = ref.read(remoteProvider);
          try { await r?.db.from('settings').update({'keep_pay_pdfs': v}).eq('user_id', r.db.auth.currentUser!.id); } catch (_) { if (mounted) setState(() => _keep = !v); }
        }),
      ]),
      Text('Off: Tick keeps the numbers only. On: the PDF goes to a private folder only you can read.', style: context.ts(TickType.bodyS, color: c.textSecondary)),
    ]);
  }
}

/// One statement as a waterfall: Gross, then taxes, then deductions, to Net. Each group opens to its lines; YTD on a toggle.
class PayStatementScreen extends ConsumerStatefulWidget {
  const PayStatementScreen({super.key, required this.id});
  final String id;
  @override
  ConsumerState<PayStatementScreen> createState() => _PayStatementState();
}

class _PayStatementState extends ConsumerState<PayStatementScreen> {
  final _open = <String>{};
  bool _ytd = false;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final all = ref.watch(payStatementsProvider).value ?? const <PayStatement>[];
    final p = all.where((x) => x.id == widget.id).firstOrNull;
    if (p == null) return TickPage(title: 'Pay statement', onBack: () => context.pop(), children: const [EmptyState('Not found', 'This statement is gone.', icon: 'import')]);
    int? ytd(String k) => (p.ytd[k] as num?)?.toInt();
    Widget group(String kind, String label, int cents, int? ytdCents, {bool subtract = true}) {
      final lines = p.lines.where((l) => l.kind == kind).toList();
      final open = _open.contains(kind);
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Pressable(onTap: lines.isEmpty ? null : () { TickHaptics.instance.selection(); setState(() => open ? _open.remove(kind) : _open.add(kind)); }, scale: 0.99,
          semanticLabel: '$label ${formatCents(cents)}${lines.isEmpty ? '' : open ? '. Hide lines' : '. Show lines'}',
          child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 48), child: Row(children: [
            Expanded(child: Text(label, style: context.ts(TickType.title, size: 16))),
            Text(formatCents(subtract ? -(_ytd ? (ytdCents ?? 0) : cents) : (_ytd ? (ytdCents ?? 0) : cents), sign: subtract), style: context.ts(TickType.mono)),
            if (lines.isNotEmpty) ...[const SizedBox(width: 6), AnimatedRotation(turns: open ? 0.25 : 0, duration: Duration(milliseconds: context.reduceMotion ? 0 : 200), child: TickIcon('chevron-right', size: 16, color: c.textSecondary))],
          ]))),
        AnimatedSize(duration: Duration(milliseconds: context.reduceMotion ? 0 : 220), alignment: Alignment.topCenter, child: !open ? const SizedBox(width: double.infinity) : Column(children: [
          for (final l in lines) Padding(padding: const EdgeInsets.fromLTRB(TickSpace.x3, 3, 0, 3), child: Row(children: [
            Expanded(child: Text(l.label, style: context.ts(TickType.body, color: c.textSecondary))),
            Text(formatCents(_ytd ? (l.ytdCents ?? 0) : l.cents), style: context.ts(TickType.monoS, color: c.textSecondary)),
          ])),
          const SizedBox(height: TickSpace.x2),
        ])),
      ]);
    }
    return TickPage(title: DateFormat('MMM d, y').format(p.payDate), onBack: () => context.pop(), children: [
      Text(p.employer, style: context.ts(TickType.bodyS, color: c.textSecondary)),
      Text('${formatCents(_ytd ? (ytd('net') ?? 0) : p.netCents)} net', style: context.ts(TickType.hero, size: 44)),
      const SizedBox(height: TickSpace.x2),
      Segmented(options: const ['This paycheck', 'Year to date'], index: _ytd ? 1 : 0, onChanged: (i) => setState(() => _ytd = i == 1)),
      const SizedBox(height: TickSpace.x3),
      TickCard(child: Column(children: [
        group('earning', 'Gross', p.grossCents, ytd('gross'), subtract: false),
        const Hairline(),
        group('tax', 'Taxes', p.taxesCents, ytd('taxes')),
        const Hairline(),
        group('deduction', 'Deductions', p.deductionsCents, ytd('deductions')),
        const Hairline(),
        Padding(padding: const EdgeInsets.symmetric(vertical: TickSpace.x2), child: Row(children: [
          Expanded(child: Text('Net', style: context.ts(TickType.title, size: 16))),
          Text(formatCents(_ytd ? (ytd('net') ?? 0) : p.netCents), style: context.ts(TickType.mono)),
        ])),
      ])),
      if (p.review) Padding(padding: const EdgeInsets.only(top: TickSpace.x2), child: Text('These don\'t add up to the cent. Check them against the PDF.', style: context.ts(TickType.bodyS, color: c.alert))),
      if (p.matchedTxn != null) Padding(padding: const EdgeInsets.only(top: TickSpace.x3), child: PillButton('See the deposit', style: PillStyle.quiet, onTap: () => context.push('/txn/${p.matchedTxn}'))),
      const SizedBox(height: TickSpace.x3),
      PillButton('Delete this statement', style: PillStyle.quiet, onTap: () async {
        final ok = await showTickSheet<bool>(context, builder: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Text('Delete this pay statement?', style: ctx.ts(TickType.title)),
          const SizedBox(height: TickSpace.x3),
          PillButton('Delete', onTap: () => Navigator.of(ctx).pop(true)),
          const SizedBox(height: TickSpace.x2),
          PillButton('Keep it', style: PillStyle.quiet, onTap: () => Navigator.of(ctx).pop(false)),
        ]));
        if (ok != true || !context.mounted) return;
        try {
          await ref.read(remoteProvider)?.db.from('pay_statements').delete().eq('id', p.id);
          ref.invalidate(payStatementsProvider);
          if (context.mounted) context.pop();
        } catch (_) {/* nothing changed */}
      }),
    ]);
  }
}

/// Insights: one Pay card, collapsed until tapped.
class PayInsightsCard extends ConsumerStatefulWidget {
  const PayInsightsCard({super.key});
  @override
  ConsumerState<PayInsightsCard> createState() => _PayInsightsCardState();
}

class _PayInsightsCardState extends ConsumerState<PayInsightsCard> {
  bool _open = false;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final all = ref.watch(payStatementsProvider).value ?? const <PayStatement>[];
    if (all.isEmpty) return const SizedBox.shrink();
    final y = payThisYear(all, ref.watch(clockProvider)().year);
    final keep = y.gross == 0 ? 0 : (y.net * 100 / y.gross).round();
    Widget line(String l, int cents) => Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Row(children: [Expanded(child: Text(l, style: context.ts(TickType.body))), Text(formatCents(cents), style: context.ts(TickType.mono))]));
    return Padding(padding: const EdgeInsets.only(top: TickSpace.x3), child: TickCard(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Pressable(onTap: () { TickHaptics.instance.selection(); setState(() => _open = !_open); }, scale: 0.99, semanticLabel: 'Pay this year ${formatCents(y.net)} net',
        child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Pay this year', style: context.ts(TickType.bodyS, color: c.textSecondary)),
            Text('${formatCents(y.net)} net', style: context.ts(TickType.title)),
          ])),
          AnimatedRotation(turns: _open ? 0.25 : 0, duration: Duration(milliseconds: context.reduceMotion ? 0 : 200), child: TickIcon('chevron-right', size: 18, color: c.textSecondary)),
        ])),
      AnimatedSize(duration: Duration(milliseconds: context.reduceMotion ? 0 : 220), alignment: Alignment.topCenter, child: !_open ? const SizedBox(width: double.infinity) : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const SizedBox(height: TickSpace.x2),
        line('Gross', y.gross), line('Taxes', y.taxes), line('401(k)', y.retirement), line('Net', y.net),
        Padding(padding: const EdgeInsets.only(top: TickSpace.x2), child: Text('You keep $keep% of gross.', style: context.ts(TickType.bodyS, color: c.textSecondary))),
        Align(alignment: Alignment.centerLeft, child: TickChip('By month', onTap: () => context.push('/pay'))),
      ])),
    ])));
  }
}

/// Pay by month, net over gross.
class PayByMonthScreen extends ConsumerWidget {
  const PayByMonthScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final all = ref.watch(payStatementsProvider).value ?? const <PayStatement>[];
    final now = ref.watch(clockProvider)();
    final months = [for (var m = 1; m <= now.month; m++) (DateTime(now.year, m), all.where((p) => p.payDate.year == now.year && p.payDate.month == m))];
    final peak = months.fold<int>(1, (a, m) => m.$2.fold<int>(0, (s, p) => s + p.grossCents) > a ? m.$2.fold<int>(0, (s, p) => s + p.grossCents) : a);
    return TickPage(title: 'Pay by month', onBack: () => context.pop(), children: [
      if (all.isEmpty) const EmptyState('No pay statements yet', 'Import one and Tick charts it here.', icon: 'insights'),
      for (final (m, ps) in months) Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Semantics(label: '${DateFormat('MMMM').format(m)}: ${formatCents(ps.fold(0, (s, p) => s + p.netCents))} net of ${formatCents(ps.fold(0, (s, p) => s + p.grossCents))} gross', excludeSemantics: true,
        child: Row(children: [
          SizedBox(width: 40, child: Text(DateFormat('MMM').format(m), style: context.ts(TickType.bodyS, color: c.textSecondary))),
          Expanded(child: LayoutBuilder(builder: (context, box) {
            final g = ps.fold<int>(0, (s, p) => s + p.grossCents), n = ps.fold<int>(0, (s, p) => s + p.netCents);
            return Stack(children: [
              Container(height: 14, width: box.maxWidth * g / peak, decoration: BoxDecoration(color: c.surface2, borderRadius: BorderRadius.circular(TickRadius.pill))),
              Container(height: 14, width: box.maxWidth * n / peak, decoration: BoxDecoration(color: c.text, borderRadius: BorderRadius.circular(TickRadius.pill))),
            ]);
          })),
          SizedBox(width: 92, child: Text(formatCents(ps.fold(0, (s, p) => s + p.netCents)), textAlign: TextAlign.right, style: context.ts(TickType.monoS))),
        ]))),
      Padding(padding: const EdgeInsets.only(top: TickSpace.x3), child: Text('Dark is what you kept; the lighter bar is gross.', style: context.ts(TickType.bodyS, color: c.textSecondary))),
    ]);
  }
}

/// On a deposit Tick matched to a pay statement: the breakdown, one tap from the statement.
class PaycheckDetail extends ConsumerWidget {
  const PaycheckDetail({super.key, required this.txnId});
  final String txnId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = (ref.watch(payStatementsProvider).value ?? const <PayStatement>[]).where((x) => x.matchedTxn == txnId).firstOrNull;
    if (p == null) return const SizedBox.shrink();
    final c = context.c;
    Widget line(String l, int cents) => Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Row(children: [Expanded(child: Text(l, style: context.ts(TickType.body, color: c.textSecondary))), Text(formatCents(cents, sign: true), style: context.ts(TickType.mono))]));
    return Padding(padding: const EdgeInsets.only(top: TickSpace.x3), child: TickCard(onTap: () => context.push('/pay-statements/${p.id}'), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Paycheck · ${DateFormat('MMM d').format(p.payDate)}', style: context.ts(TickType.title, size: 16)),
      const SizedBox(height: 4),
      line('Gross', p.grossCents), line('Taxes', -p.taxesCents), line('Deductions', -p.deductionsCents), line('Net', p.netCents),
    ])));
  }
}
