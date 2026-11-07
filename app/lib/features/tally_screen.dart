import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../data/tally_store.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../design/widgets/more.dart';
import '../design/widgets/motion.dart';
import '../design/widgets/scaffold.dart';
import '../domain/money.dart';
import '../domain/tally.dart';
import '../services/haptics.dart';
import 'ask_button.dart';
import 'common.dart';
import 'tally_expense_sheet.dart';
import 'tally_people.dart';

/// Tally: split costs with friends. Playful on purpose (the one place), but errors and money problems stay plain.
class TallyScreen extends ConsumerWidget {
  const TallyScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(tallyProvider);
    final s = t.totals;
    return TickPage(
      title: 'Tally', trailing: const AskButton(), bottomPad: 130,
      onRefresh: () => ref.read(tallyProvider.notifier).refresh(),
      children: [
        if (t.inboxBadge > 0 || t.inbox.isNotEmpty) Padding(padding: const EdgeInsets.only(bottom: 12), child: Align(alignment: Alignment.centerLeft, child: TickChip(t.inboxBadge > 0 ? 'Inbox ${t.inboxBadge}' : 'Inbox', icon: 'tally', onTap: () => context.push('/tally/inbox')))),
        const HandleNudge(),
        if (t.loading && t.groups.isEmpty) const Column(children: [Skeleton(height: 96, radius: 24), SizedBox(height: 12), ListSkeleton(rows: 4)])
        else if (t.error != null && t.groups.isEmpty) ErrorState(title: 'Tally didn\'t load', body: t.error!, onRetry: () => ref.read(tallyProvider.notifier).refresh())
        else if (t.groups.isEmpty)
          const EmptyState('No tallies yet', 'Split a purchase with a friend and it shows up here.', icon: 'tally')
        else ...[
          _Summary(owed: s.owedToMe, owe: s.iOwe, square: t.allSquare),
          const SizedBox(height: 20),
          for (final (i, g) in t.groups.where((g) => !g.archived).indexed) StaggerIn(scope: 'tally', index: i, child: _GroupRow(g: g, t: t)),
          for (final g in t.groups) if (g.archived) Opacity(opacity: 0.62, child: _GroupRow(g: g, t: t)),
        ],
        if (t.offline && t.groups.isNotEmpty) OfflineBanner(onRetry: () => ref.read(tallyProvider.notifier).refresh()),
        if (t.plan.length > 1 || t.plan.any((p) => p.legs.length > 1)) ...[const SizedBox(height: 8), PillButton('Settle everything', icon: 'check', style: PillStyle.quiet, onTap: () => context.push('/tally/plan'))],
        const SizedBox(height: 16),
        PillButton('New tally', icon: 'plus', style: t.groups.isEmpty ? PillStyle.primary : PillStyle.quiet, onTap: () => showNewGroupSheet(context)),
      ],
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.owed, required this.owe, required this.square});
  final int owed;
  final int owe;
  final bool square;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    if (owed == 0 && owe == 0) {
      return TickCard(child: Semantics(label: square ? 'All square' : 'Nothing owed', child: Row(children: [
        TickIcon('check', size: 28, color: c.textSecondary), const SizedBox(width: 12),
        Expanded(child: Text(square ? 'All square ✓' : 'Nobody owes anybody.', style: context.ts(TickType.title))),
      ])));
    }
    return TickCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (owed > 0) Semantics(label: 'You\'re owed ${formatCents(owed)}', excludeSemantics: true, child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 10, children: [
        Text('You\'re owed', style: context.ts(TickType.body, color: c.textSecondary)),
        Sticker(glow: false, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6), tilt: 2, child: RollingNumber(value: owed, builder: (_, v) => Text(formatCents(v), style: context.ts(TickType.monoL, color: c.onAccent)))),
      ])),
      if (owed > 0 && owe > 0) const SizedBox(height: 10),
      if (owe > 0) Row(children: [
        Expanded(child: Text('You owe', style: context.ts(TickType.body, color: c.textSecondary))),
        RollingNumber(value: owe, semanticLabel: formatCents(owe), builder: (_, v) => Text(formatCents(v), style: context.ts(TickType.monoL))),
      ]),
    ]));
  }
}

class _GroupRow extends StatelessWidget {
  const _GroupRow({required this.g, required this.t});
  final TallyGroup g;
  final TallyState t;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final net = t.balancesOf(g.id)[me] ?? 0;
    final pending = t.pendingCount(g.id);
    final line = net > 0 ? 'You\'re owed ${formatCents(net)}' : net < 0 ? 'You owe ${formatCents(-net)}' : (t.expensesOf(g.id).isEmpty ? 'Nothing split yet' : 'All square ✓');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TickCard(
        onTap: () => context.push('/tally/${g.id}'),
        child: Row(children: [
          TickHero(tag: 'group-${g.id}', child: GroupBadge(g: g)),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(g.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.ts(TickType.bodyL)),
            Text(pending > 0 ? '$line · $pending to confirm' : line, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.ts(TickType.bodyS, color: net < 0 ? c.alert : c.textSecondary)),
          ])),
        ]),
      ),
    );
  }
}

/// New group or 1:1: name, then pick people (or add a friend by name).
Future<void> showNewGroupSheet(BuildContext context, {void Function(TallyGroup)? onCreated}) =>
    showTickSheet<void>(context, full: true, builder: (_) => _NewGroup(onCreated: onCreated));

class _NewGroup extends ConsumerStatefulWidget {
  const _NewGroup({this.onCreated});
  final void Function(TallyGroup)? onCreated;
  @override
  ConsumerState<_NewGroup> createState() => _NewGroupState();
}

class _NewGroupState extends ConsumerState<_NewGroup> {
  final _name = TextEditingController(), _friend = TextEditingController();
  final _picked = <String>{};
  final _invited = <String, FoundPerson>{};
  bool _busy = false;
  String? _emoji;
  String _color = 'shop';
  @override
  void dispose() { _name.dispose(); _friend.dispose(); super.dispose(); }

  Future<void> _addFriend() async {
    final n = _friend.text.trim();
    if (n.isEmpty) return;
    final p = await ref.read(tallyProvider.notifier).addPerson(n);
    _friend.clear();
    if (mounted) setState(() => _picked.add(p.id));
  }

  Future<void> _create() async {
    if ((_picked.isEmpty && _invited.isEmpty) || _busy) return;
    setState(() => _busy = true);
    final st = ref.read(tallyProvider);
    final direct = _picked.length + _invited.length == 1 && _name.text.trim().isEmpty;
    final name = _name.text.trim().isNotEmpty ? _name.text.trim() : _picked.isNotEmpty ? (st.contacts.where((p) => p.id == _picked.first).firstOrNull?.first ?? st.nameOf(_picked.first)) : _invited.values.first.name.split(' ').first;
    final g = await ref.read(tallyProvider.notifier).addGroup(name, _picked.toList(), direct: direct, invite: _invited.keys.toList(), emoji: _emoji, colorKey: _color);
    if (!mounted) return;
    TickHaptics.instance.confirm();
    Navigator.of(context).pop();
    widget.onCreated?.call(g);
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(tallyProvider);
    final c = context.c;
    return SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Text('New tally', style: context.ts(TickType.title)),
      const SizedBox(height: 12),
      TallyField(controller: _name, hint: 'Name it, like Roommates (optional for one friend)', onChanged: (_) => setState(() {})),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 4, children: [for (final e in const ['🏠', '✈️', '🍽️', '🎉', '🛒', '💼']) TickChip(e, on: _emoji == e, onTap: () => setState(() => _emoji = _emoji == e ? null : e))]),
      const SizedBox(height: 4),
      Wrap(spacing: 8, runSpacing: 4, children: [for (final k in const ['food', 'ride', 'sub', 'home', 'biz', 'shop']) Pressable(onTap: () => setState(() => _color = k), semanticLabel: 'Colour $k', minSize: 44, child: Opacity(opacity: _color == k ? 1 : 0.45, child: Avatar(k, k, size: 28)))]),
      const SizedBox(height: 16),
      Text('Who is in?', style: context.ts(TickType.bodyS, color: c.textSecondary)),
      const SizedBox(height: 4),
      Wrap(spacing: 8, children: [for (final p in st.contacts) TickChip(p.first, on: _picked.contains(p.id), onTap: () { TickHaptics.instance.selection(); setState(() { _picked.contains(p.id) ? _picked.remove(p.id) : _picked.add(p.id); }); })]),
      if (_invited.isNotEmpty) Wrap(spacing: 8, children: [for (final p in _invited.values) TickChip('${p.name.split(' ').first} (invite)', on: true, onTap: () => setState(() => _invited.remove(p.userId)))]),
      const SizedBox(height: 8),
      PeopleSearch(onPick: (p) => setState(() => _invited[p.userId] = p)),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: TallyField(controller: _friend, hint: 'Not on Tick? Add them by name')),
        const SizedBox(width: 8),
        PillButton('Add', expand: false, height: 52, style: PillStyle.quiet, onTap: _addFriend),
      ]),
      const SizedBox(height: 16),
      PillButton('Start tally', busy: _busy, onTap: _picked.isEmpty && _invited.isEmpty ? null : _create),
    ]));
  }
}
