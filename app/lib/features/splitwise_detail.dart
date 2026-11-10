import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../data/splitwise.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../design/widgets/more.dart';
import '../domain/merchant_name.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import '../services/haptics.dart';

/// After picking Splitwise: which group or friend it was with. "Not sure" leaves it untagged; Tick still guesses.
Future<void> askSplitwiseWho(BuildContext context, WidgetRef ref, Txn t) => showTickSheet<void>(context, builder: (ctx) => _Who(t: t));

class _Who extends ConsumerStatefulWidget {
  const _Who({required this.t});
  final Txn t;
  @override
  ConsumerState<_Who> createState() => _WhoState();
}

class _WhoState extends ConsumerState<_Who> {
  String? _error;
  bool _busy = false;

  Future<void> _pick({String? groupId, String? person}) async {
    setState(() { _busy = true; _error = null; });
    try {
      await ref.read(splitwiseActionsProvider).tag(widget.t.id, groupId: groupId, person: person);
      TickHaptics.instance.confirm();
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) setState(() { _busy = false; _error = 'That didn\'t save. Check your connection and try again.'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final opts = ref.watch(splitwiseOptionsProvider);
    final c = context.c;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Text('Which group or friend?', style: context.ts(TickType.displayM)),
      const SizedBox(height: 4),
      Text('${cleanMerchant(widget.t.merchant)} · ${formatCents(widget.t.amountCents.abs())}', style: context.ts(TickType.body, color: c.textSecondary)),
      const SizedBox(height: 16),
      opts.when(
        loading: () => const Wrap(spacing: 8, runSpacing: 8, children: [Skeleton(width: 90, height: 36, radius: 18), Skeleton(width: 120, height: 36, radius: 18), Skeleton(width: 70, height: 36, radius: 18)]),
        error: (_, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Groups didn\'t load. It stays Splitwise either way.', style: context.ts(TickType.body, color: c.textSecondary)),
          const SizedBox(height: 8),
          PillButton('Try again', height: 44, style: PillStyle.quiet, onTap: () => ref.invalidate(splitwiseOptionsProvider)),
        ]),
        data: (o) => o.isEmpty
            ? Text('No Tally groups yet. It stays Splitwise, and Tick still looks for the match.', style: context.ts(TickType.body, color: c.textSecondary))
            : Wrap(spacing: 8, runSpacing: 8, children: [
                for (final g in o.groups) TickChip(g.name, icon: 'tally', onTap: _busy ? null : () => _pick(groupId: g.id)),
                for (final f in o.friends) TickChip(f, onTap: _busy ? null : () => _pick(person: f)),
              ]),
      ),
      if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: context.ts(TickType.bodyS, color: c.alert))),
      const SizedBox(height: 16),
      PillButton('Not sure', style: PillStyle.quiet, onTap: () => Navigator.of(context).pop()),
    ]);
  }
}

/// On a Splitwise row (or a payment to a friend): what it most likely was, how sure, and "Not this one".
class SplitwiseDetail extends ConsumerWidget {
  const SplitwiseDetail({super.key, required this.t});
  final Txn t;

  static bool appliesTo(Txn t, Category? cat) =>
      !t.isTransfer && (cat?.name == 'Splitwise' || (cat?.name == 'Friends and family' && p2pName(t.merchant) != null));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final x = ref.watch(splitwiseExplainProvider(t.id));
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: x.when(
        loading: () => const TickCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Skeleton(width: 90, height: 12), SizedBox(height: 10), Skeleton(width: 200, height: 18), SizedBox(height: 8), Skeleton(width: 140, height: 12)])),
        error: (_, _) => TickCard(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('The match didn\'t load', style: context.ts(TickType.title, size: 15.5)),
          const SizedBox(height: 4),
          Text('Check your connection and try again.', style: context.ts(TickType.bodyS, color: c.textSecondary)),
          const SizedBox(height: 10),
          PillButton('Try again', height: 44, style: PillStyle.quiet, onTap: () => ref.invalidate(splitwiseExplainProvider(t.id))),
        ])),
        data: (e) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _Best(t: t, e: e),
          if (e.couldSettle != null) ...[const SizedBox(height: 12), _Settles(cs: e.couldSettle!, cents: t.amountCents.abs())],
          if (!e.gmailConnected)
            Pressable(
              onTap: () => _gmailSheet(context),
              child: Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text('Connect Gmail to match Splitwise emails  ›', style: context.ts(TickType.bodyS, color: c.textSecondary))),
            ),
        ]),
      ),
    );
  }
}

class _Best extends ConsumerStatefulWidget {
  const _Best({required this.t, required this.e});
  final Txn t;
  final SplitwiseExplain e;
  @override
  ConsumerState<_Best> createState() => _BestState();
}

class _BestState extends ConsumerState<_Best> {
  bool _busy = false;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final b = widget.e.best;
    if (b == null) {
      return TickCard(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('No match yet', style: context.ts(TickType.title, size: 15.5)),
        const SizedBox(height: 4),
        Text(widget.e.tag != null ? 'Tick is looking in ${widget.e.tag} for an expense or balance that fits.' : 'Tick checks Tally expenses and balances for one that fits.',
            style: context.ts(TickType.bodyS, color: c.textSecondary)),
      ]));
    }
    final when = b.date == null ? null : DateFormat('MMM d').format(b.date!);
    return TickCard(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(child: Text('Most likely', style: context.ts(TickType.bodyS, color: c.textSecondary))),
        TickChip(b.confidenceLabel, on: b.confidence >= 0.85),
      ]),
      const SizedBox(height: 8),
      Text('${b.label} · ${formatCents(b.cents)}', style: context.ts(TickType.title, size: 16)),
      const SizedBox(height: 2),
      Text([b.where, ?when].where((s) => s.isNotEmpty).join(' · '), style: context.ts(TickType.bodyS, color: c.textSecondary)),
      const SizedBox(height: 10),
      Row(children: [
        Pressable(
          onTap: _busy ? null : () async {
            setState(() => _busy = true);
            TickHaptics.instance.selection();
            try { await ref.read(splitwiseActionsProvider).notThis(widget.t.id, b.ref); } catch (_) {/* it shows again next time */}
            if (mounted) setState(() => _busy = false);
          },
          child: Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Text('Not this one', style: context.ts(TickType.bodyS, color: c.text))),
        ),
        const Spacer(),
        if (widget.e.more > 0) Text('${widget.e.more} more', style: context.ts(TickType.bodyS, color: c.textSecondary)),
      ]),
    ]));
  }
}

class _Settles extends StatelessWidget {
  const _Settles({required this.cs, required this.cents});
  final CouldSettle cs;
  final int cents;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final first = cs.person.split(' ').first;
    return TickCard(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(cs.exact ? 'Settles these with $first' : 'Could settle these with $first', style: context.ts(TickType.title, size: 15.5)),
      const SizedBox(height: 4),
      Text(cs.exact ? 'Your shares add up to exactly ${formatCents(cents)}.' : 'Your shares come to ${formatCents(cs.totalCents)}; this was ${formatCents(cents)}.',
          style: context.ts(TickType.bodyS, color: c.textSecondary)),
      const SizedBox(height: 8),
      for (final i in cs.items)
        Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Row(children: [
          Expanded(child: Text(i.label, style: context.ts(TickType.body), overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 8),
          Text(formatCents(i.cents), style: context.ts(TickType.body)),
        ])),
    ]));
  }
}

void _gmailSheet(BuildContext context) => showTickSheet<void>(context, builder: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Text('Match Splitwise emails', style: ctx.ts(TickType.displayM)),
      const SizedBox(height: 8),
      Text('With Gmail connected, Tick reads only Splitwise notification emails, keeps the amount, description and date, and never the email itself. '
          'It needs a one-time Google Cloud setup on your side first; the steps are in docs/POLISH_V3.md. Until then Tick matches against Tally.',
          style: ctx.ts(TickType.body, color: ctx.c.textSecondary)),
      const SizedBox(height: 16),
      PillButton('Got it', style: PillStyle.quiet, onTap: () => Navigator.of(ctx).pop()),
    ]));
