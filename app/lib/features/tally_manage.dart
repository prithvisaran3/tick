import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../data/tally_store.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../design/widgets/more.dart';
import '../design/widgets/pickers.dart';
import '../design/widgets/scaffold.dart';
import '../domain/money.dart';
import '../domain/tally.dart';
import '../services/api.dart';
import '../services/haptics.dart';
import 'common.dart';
import 'tally_expense_sheet.dart';
import 'tally_people.dart';
import 'tally_square.dart';

/// Five seconds to take it back, in a bar above the tab bar. Lives in the overlay so it outlasts the sheet or screen that closed.
void showUndo(OverlayState overlay, String text, Future<void> Function() onUndo) {
  late OverlayEntry entry;
  Timer? timer;
  void close() { timer?.cancel(); if (entry.mounted) entry.remove(); }
  entry = OverlayEntry(builder: (context) {
    final c = context.c;
    return Positioned(left: 16, right: 16, bottom: MediaQuery.of(context).padding.bottom + 96, child: Semantics(liveRegion: true, child: Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      decoration: BoxDecoration(color: c.surface2, borderRadius: BorderRadius.circular(TickRadius.card)),
      child: Row(children: [
        Expanded(child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.ts(TickType.body))),
        PillButton('Undo', expand: false, height: 40, style: PillStyle.inverse, onTap: () { close(); onUndo(); }),
      ]),
    )));
  });
  overlay.insert(entry);
  timer = Timer(const Duration(seconds: 5), close);
}

/// Settle up with one person: the simplified amount, or less. Tick records it; the money moves somewhere else.
Future<void> showSettleSheet(BuildContext context, {required TallyGroup g, required Transfer m}) => showTickSheet<void>(context, full: true, builder: (_) => SettleSheet(g: g, m: m, host: context));

const settleMethods = <(String, String)>[('zelle', 'Zelle'), ('venmo', 'Venmo'), ('cashapp', 'Cash App'), ('cash', 'Cash'), ('other', 'Other')];

class SettleSheet extends ConsumerStatefulWidget {
  const SettleSheet({super.key, required this.g, required this.m, required this.host});
  final TallyGroup g;
  final Transfer m;
  final BuildContext host;   // the screen under the sheet, which outlives it
  @override
  ConsumerState<SettleSheet> createState() => _SettleSheetState();
}

class _SettleSheetState extends ConsumerState<SettleSheet> {
  late final _amount = TextEditingController(text: formatCents(widget.m.cents, symbol: false, raw: true));
  String _method = 'zelle';
  bool _busy = false;
  String? _note;
  @override
  void dispose() { _amount.dispose(); super.dispose(); }

  int get _cents => parseCents(_amount.text) ?? 0;
  bool get _valid => _cents > 0 && _cents <= widget.m.cents;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: (_cents / 100).toStringAsFixed(2)));
    TickHaptics.instance.selection();
  }

  Future<void> _open() async {
    await _copy();
    final uri = _method == 'venmo' ? venmoLink(_cents, widget.g.name) : cashAppLink;
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication).catchError((_) => false);
    if (mounted) setState(() => _note = ok ? 'Amount copied. Come back here once it is sent.' : 'Couldn\'t open it. The amount is copied.');
  }

  Future<void> _record() async {
    setState(() => _busy = true);
    final n = ref.read(tallyProvider.notifier);
    final wasSquare = ref.read(tallyProvider).balancesOf(widget.g.id).isEmpty;
    await n.settle(widget.g.id, widget.m.from, widget.m.to, _cents, method: _method);
    if (!mounted) return;
    TickHaptics.instance.confirm();
    final square = ref.read(tallyProvider).balancesOf(widget.g.id).isEmpty;
    Navigator.of(context).pop();
    if (square && !wasSquare && widget.host.mounted) unawaited(showSquareUp(widget.host));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final t = ref.watch(tallyProvider);
    final iPay = widget.m.from == me;
    final other = t.nameOf(iPay ? widget.m.to : widget.m.from);
    return SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Text('Settle up with $other', style: context.ts(TickType.title)),
      const SizedBox(height: 4),
      Text(iPay ? 'You owe ${formatCents(widget.m.cents)}.' : '$other owes you ${formatCents(widget.m.cents)}.', style: context.ts(TickType.body, color: c.textSecondary)),
      const SizedBox(height: 12),
      TallyField(controller: _amount, hint: 'Amount', label: 'Amount in dollars', keyboard: const TextInputType.numberWithOptions(decimal: true), onChanged: (_) => setState(() {})),
      if (_cents > widget.m.cents) Padding(padding: const EdgeInsets.only(top: 6), child: Text('That\'s more than ${formatCents(widget.m.cents)}.', style: context.ts(TickType.bodyS, color: c.alert))),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 4, children: [for (final (k, l) in settleMethods) TickChip(l, on: _method == k, onTap: () { TickHaptics.instance.selection(); setState(() { _method = k; _note = null; }); })]),
      if (iPay && _valid) ...[
        const SizedBox(height: 12),
        if (_method == 'venmo') PillButton('Open Venmo', style: PillStyle.quiet, onTap: _open),
        if (_method == 'cashapp') PillButton('Open Cash App', style: PillStyle.quiet, onTap: _open),
        if (_method == 'zelle') ...[
          PillButton('Copy amount', style: PillStyle.quiet, onTap: () async { await _copy(); if (mounted) setState(() => _note = 'Amount copied.'); }),
          Padding(padding: const EdgeInsets.only(top: 6), child: Text('Open your bank app to send it with Zelle.', style: context.ts(TickType.bodyS, color: c.textSecondary))),
        ],
      ],
      if (_note != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(_note!, style: context.ts(TickType.bodyS, color: c.textSecondary))),
      const SizedBox(height: 16),
      PillButton(iPay ? 'I paid ${formatCents(_cents)}' : 'They paid ${formatCents(_cents)}', busy: _busy, onTap: _valid ? _record : null),
      const SizedBox(height: 8),
      Text('Tick never moves money. This records that it happened.', style: context.ts(TickType.bodyS, size: 12.5, color: c.textSecondary)),
    ]));
  }
}

/// Remind someone: an inbox item for a Tick user, a message I send myself for a guest.
Future<void> showRemindSheet(BuildContext context, {required TallyGroup g, required String member, required int cents}) => showTickSheet<void>(context, builder: (_) => RemindSheet(g: g, member: member, cents: cents));

class RemindSheet extends ConsumerStatefulWidget {
  const RemindSheet({super.key, required this.g, required this.member, required this.cents});
  final TallyGroup g;
  final String member;
  final int cents;
  @override
  ConsumerState<RemindSheet> createState() => _RemindSheetState();
}

class _RemindSheetState extends ConsumerState<RemindSheet> {
  ReminderTone _tone = ReminderTone.friendly;
  bool _busy = false;
  String? _error;

  Future<void> _send(TallyPerson? p, String text) async {
    setState(() { _busy = true; _error = null; });
    try {
      await ref.read(tallyProvider.notifier).remind(widget.g.id, widget.member, _tone);
      if (p?.isGuest ?? true) {
        String? link;
        try { link = (await ref.read(apiProvider).post('/tally/groups/${widget.g.id}/links', {'days': 30}))['url'] as String?; } catch (_) {/* the message still works without it */}
        final body = link == null ? text : '$text $link';
        final phone = p?.phone;
        final sms = Uri.parse('sms:${phone ?? ''}&body=${Uri.encodeComponent(body)}');
        final ok = phone != null && await launchUrl(sms).catchError((_) => false);
        if (!ok) await SharePlus.instance.share(ShareParams(text: body));
      }
      TickHaptics.instance.confirm();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() { _busy = false; _error = describeError(e, action: 'send that'); });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final t = ref.watch(tallyProvider);
    final p = t.person(widget.member);
    final name = t.nameOf(widget.member);
    final text = reminderText(_tone, name: name, amount: formatCents(widget.cents), group: widget.g.name);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Text('Remind $name', style: context.ts(TickType.title)),
      const SizedBox(height: 12),
      Segmented(options: const ['Friendly', 'Neutral', 'Firm'], index: _tone.index, onChanged: (i) { TickHaptics.instance.selection(); setState(() => _tone = ReminderTone.values[i]); }),
      const SizedBox(height: 12),
      TickCard(child: Text(text, style: context.ts(TickType.body))),
      if (_error != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(_error!, style: context.ts(TickType.bodyS, color: c.alert))),
      const SizedBox(height: 12),
      PillButton((p?.isGuest ?? true) ? 'Write the message' : 'Send to their inbox', busy: _busy, onTap: () => _send(p, text)),
    ]);
  }
}

class SettlementRow extends ConsumerWidget {
  const SettlementRow({super.key, required this.s, required this.g});
  final TallySettlement s;
  final TallyGroup g;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(tallyProvider);
    final c = context.c;
    final method = settleMethods.where((m) => m.$1 == s.method).firstOrNull?.$2 ?? 'Other';
    return Pressable(
      onTap: !t.canEdit(g, s.createdBy) ? null : () async {
        final overlay = Overlay.of(context, rootOverlay: true);
        final n = ref.read(tallyProvider.notifier);
        final pick = await showTickSheet<String>(context, builder: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          PillButton('Change amount', style: PillStyle.quiet, onTap: () => Navigator.of(ctx).pop('edit')),
          const SizedBox(height: 8),
          PillButton('Delete payment', style: PillStyle.quiet, onTap: () => Navigator.of(ctx).pop('delete')),
        ]));
        try {
          if (pick == 'delete') {
            await n.deleteSettlement(s.id);
            showUndo(overlay, 'Payment deleted', () => n.restoreSettlement(s));
          } else if (pick == 'edit' && context.mounted) {
            final v = await showTextSheet(context, title: 'Amount', initial: formatCents(s.amountCents, symbol: false, raw: true), confirm: 'Save');
            final cents = v == null ? null : parseCents(v);
            if (cents != null && cents > 0) await n.editSettlement(s, cents);
          }
        } catch (_) {/* nothing changed */}
      },
      semanticLabel: '${t.nameOf(s.from)} paid ${t.nameOf(s.to)} ${formatCents(s.amountCents)}. Tap to change',
      child: Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Row(children: [
        Expanded(child: Text('${t.nameOf(s.from)} paid ${t.nameOf(s.to)} · $method · ${DateFormat('MMM d').format(s.on)}', maxLines: 2, overflow: TextOverflow.ellipsis, style: context.ts(TickType.bodyS, color: c.textSecondary))),
        const SizedBox(width: 8),
        Text(formatCents(s.amountCents), style: context.ts(TickType.mono)),
      ])),
    );
  }
}

/// Members, and everything only the owner can do.
class TallyGroupSettingsScreen extends ConsumerStatefulWidget {
  const TallyGroupSettingsScreen({super.key, required this.id});
  final String id;
  @override
  ConsumerState<TallyGroupSettingsScreen> createState() => _GroupSettingsState();
}

class _GroupSettingsState extends ConsumerState<TallyGroupSettingsScreen> {
  String? _error;
  final _guest = TextEditingController();
  @override
  void dispose() { _guest.dispose(); super.dispose(); }

  Future<void> _run(Future<void> Function() f, {String action = 'do that'}) async {
    setState(() => _error = null);
    try {
      await f();
    } on TallyBlocked catch (b) {
      if (mounted) setState(() => _error = b.netCents < 0 ? 'Still owes ${formatCents(-b.netCents)}. Settle up first.' : 'Still owed ${formatCents(b.netCents)}. Settle up first.');
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e, action: action));
    }
  }

  Future<void> _inviteByMessage(String name) async {
    final j = await ref.read(apiProvider).post('/tally/groups/${widget.id}/links', {'days': 30});
    await SharePlus.instance.share(ShareParams(text: 'Hey $name, I added you to a tally on Tick. Here\'s where we stand: ${j['url']}'));
  }

  Future<void> _leave(String gid) {
    final router = GoRouter.of(context);
    return _run(() async { await ref.read(tallyProvider.notifier).leaveGroup(gid); router.go('/tally'); }, action: 'leave');
  }

  Future<void> _delete(TallyGroup g) async {
    final yes = await showTickSheet<bool>(context, builder: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Text('Delete ${g.name}?', style: ctx.ts(TickType.title)),
      const SizedBox(height: 4),
      Text('It goes for everyone in the group.', style: ctx.ts(TickType.body, color: ctx.c.textSecondary)),
      const SizedBox(height: 12),
      PillButton('Delete', onTap: () => Navigator.of(ctx).pop(true)),
      const SizedBox(height: 6),
      PillButton('Keep it', style: PillStyle.quiet, onTap: () => Navigator.of(ctx).pop(false)),
    ]));
    if (yes != true || !mounted) return;
    final overlay = Overlay.of(context, rootOverlay: true);
    final n = ref.read(tallyProvider.notifier);
    final router = GoRouter.of(context);
    await _run(() async {
      await n.deleteGroup(g.id);
      router.go('/tally');
      showUndo(overlay, '${g.name} deleted', () => n.restoreGroup(g));
    }, action: 'delete it');
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(tallyProvider);
    final c = context.c;
    final g = t.groups.where((x) => x.id == widget.id).firstOrNull;
    if (g == null) return TickPage(title: 'Group', onBack: () => context.pop(), children: const [EmptyState('Not found', 'This tally is gone.')]);
    final n = ref.read(tallyProvider.notifier);
    return TickPage(title: g.name, onBack: () => context.pop(), bottomPad: 40, children: [
      if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(_error!, style: context.ts(TickType.body, color: c.alert))),
      const SectionLabel('Members'),
      TickCard(padding: const EdgeInsets.symmetric(horizontal: 16), child: Column(children: [
        Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Row(children: [
          Avatar('You', 'biz', size: 32), const SizedBox(width: 12),
          Expanded(child: Text(g.isOwner ? 'You (owner)' : 'You', style: context.ts(TickType.body))),
        ])),
        for (final m in g.memberIds) ...[
          const Hairline(),
          Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Row(children: [
            Avatar(t.nameOf(m), t.person(m)?.colorKey ?? 'shop', size: 32), const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.person(m)?.name ?? t.nameOf(m), maxLines: 1, overflow: TextOverflow.ellipsis, style: context.ts(TickType.body)),
              if (t.person(m)?.isGuest ?? false) Text('Guest', style: context.ts(TickType.bodyS, size: 12.5, color: c.textSecondary)),
            ])),
            if (t.person(m)?.isGuest ?? false) PillButton('Invite', expand: false, height: 40, style: PillStyle.quiet, onTap: () => _run(() => _inviteByMessage(t.nameOf(m)), action: 'make a link')),
            if (g.isOwner) ...[const SizedBox(width: 6), PillButton('Remove', expand: false, height: 40, style: PillStyle.quiet, onTap: () => _run(() => n.removeMember(g.id, m), action: 'remove them'))],
          ])),
        ],
      ])),
      const SectionLabel('Add someone'),
      PeopleSearch(onPick: (p) => _run(() => n.inviteUser(g.id, p.userId), action: 'invite them')),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: TallyField(controller: _guest, hint: 'Not on Tick? Add them by name')),
        const SizedBox(width: 8),
        PillButton('Add', expand: false, height: 52, style: PillStyle.quiet, onTap: () { final v = _guest.text.trim(); if (v.isEmpty) return; _guest.clear(); _run(() => n.addGuest(g.id, v), action: 'add them'); }),
      ]),
      const SizedBox(height: 20),
      if (g.isOwner) ...[
        PillButton('Rename', style: PillStyle.quiet, onTap: () async {
          final v = await showTextSheet(context, title: 'Rename', initial: g.name, confirm: 'Save');
          if (v != null && v.trim().isNotEmpty) await _run(() => n.renameGroup(g.id, v), action: 'rename it');
        }),
        const SizedBox(height: 8),
        PillButton(g.archived ? 'Bring back' : 'Archive', style: PillStyle.quiet, onTap: () => _run(() => n.archiveGroup(g.id, archived: !g.archived), action: 'archive it')),
        const SizedBox(height: 8),
        PillButton('Delete group', style: PillStyle.quiet, onTap: () => _delete(g)),
      ] else
        PillButton('Leave group', style: PillStyle.quiet, onTap: () => _leave(g.id)),
    ]);
  }
}

/// Everything between me and one person in this group.
class TallyPersonScreen extends ConsumerWidget {
  const TallyPersonScreen({super.key, required this.groupId, required this.member});
  final String groupId;
  final String member;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(tallyProvider);
    final c = context.c;
    final lines = personLedger(member, t.expensesOf(groupId), t.settlementsOf(groupId));
    return TickPage(title: t.nameOf(member), onBack: () => context.pop(), children: [
      if (lines.isEmpty) const EmptyState('Nothing yet', 'Nothing between you two in this tally.', icon: 'tally'),
      if (lines.isNotEmpty) TickCard(padding: const EdgeInsets.symmetric(horizontal: 16), child: Column(children: [
        for (final (i, l) in lines.reversed.indexed) ...[
          if (i > 0) const Hairline(),
          Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.label, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.ts(TickType.body)),
              Text(DateFormat('MMM d').format(l.on), style: context.ts(TickType.bodyS, size: 12.5, color: c.textSecondary)),
            ])),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(formatCents(l.deltaCents, sign: true), style: context.ts(TickType.mono)),
              Text(formatCents(l.runningCents), style: context.ts(TickType.bodyS, size: 12.5, color: c.textSecondary)),
            ]),
          ])),
        ],
      ])),
    ]);
  }
}

String activityLine(TallyActivity a) {
  final who = a.actor ?? 'Someone';
  final l = a.label ?? '';
  final was = a.oldCents == null ? '' : formatCents(a.oldCents!);
  final now = a.newCents == null ? '' : formatCents(a.newCents!);
  return switch (a.action) {
    'expense_added' => '$who added $l, $now',
    'expense_edited' => a.oldCents == a.newCents ? '$who edited $l' : '$who changed $l from $was to $now',
    'expense_deleted' => '$who deleted $l, $was',
    'expense_restored' => '$who brought back $l, $now',
    'settlement_added' => '$who recorded $l, $now',
    'settlement_edited' => '$who changed $l from $was to $now',
    'settlement_deleted' => '$who deleted a payment, $l, $was',
    'settlement_restored' => '$who brought back a payment, $l, $now',
    'settlement_confirmed' => '$who confirmed $l, $now',
    'settlement_rejected' => '$who turned down $l, $now',
    'member_added' => '$who added $l',
    'member_joined' => '$l joined',
    'member_left' => '$l left',
    'member_removed' => '$who removed $l',
    'group_created' => '$who started $l',
    'group_renamed' => '$who renamed this to $l',
    'group_archived' => '$who archived this',
    'group_unarchived' => '$who brought this back',
    'group_deleted' => '$who deleted this',
    'group_restored' => '$who restored this',
    'reminded' => '$who reminded $l, $now',
    'imported' => '$who imported from Splitwise',
    _ => '$who made a change',
  };
}

final _activityProvider = FutureProvider.family<List<TallyActivity>, String>((ref, id) {
  ref.watch(tallyProvider);
  return ref.read(tallyProvider.notifier).activity(id);
});

class TallyActivityScreen extends ConsumerWidget {
  const TallyActivityScreen({super.key, required this.id});
  final String id;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final a = ref.watch(_activityProvider(id));
    return TickPage(title: 'Activity', onBack: () => context.pop(), children: [
      switch (a) {
        AsyncData(:final value) when value.isEmpty => const EmptyState('Nothing yet', 'Every change in this tally shows up here.', icon: 'tally'),
        AsyncData(:final value) => TickCard(padding: const EdgeInsets.symmetric(horizontal: 16), child: Column(children: [
            for (final (i, x) in value.indexed) ...[
              if (i > 0) const Hairline(),
              Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Row(children: [
                Expanded(child: Text(activityLine(x), style: context.ts(TickType.body))),
                const SizedBox(width: 8),
                Text(DateFormat('MMM d').format(x.at), style: context.ts(TickType.bodyS, size: 12.5, color: c.textSecondary)),
              ])),
            ],
          ])),
        AsyncError() => ErrorState(onRetry: () async => ref.invalidate(_activityProvider(id))),
        _ => const ListSkeleton(rows: 6),
      },
    ]);
  }
}
