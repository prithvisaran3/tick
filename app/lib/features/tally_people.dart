import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../data/remote.dart';
import '../data/settings.dart';
import '../data/tally_store.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../design/widgets/more.dart';
import '../design/widgets/scaffold.dart';
import '../domain/money.dart';
import '../services/api.dart';
import '../services/haptics.dart';
import 'common.dart';
import 'tally_expense_sheet.dart';

/// Type-ahead over the server's search. Shows a name, a handle and an avatar: nothing else about anyone.
class PeopleSearch extends ConsumerStatefulWidget {
  const PeopleSearch({super.key, required this.onPick});
  final ValueChanged<FoundPerson> onPick;
  @override
  ConsumerState<PeopleSearch> createState() => _PeopleSearchState();
}

class _PeopleSearchState extends ConsumerState<PeopleSearch> {
  final _q = TextEditingController();
  Timer? _debounce;
  List<FoundPerson> _hits = const [];
  String? _error;
  bool _searched = false;
  @override
  void dispose() { _debounce?.cancel(); _q.dispose(); super.dispose(); }

  void _changed(String v) {
    _debounce?.cancel();
    final q = v.trim();
    final worth = q.contains('@') && !q.startsWith('@') || q.replaceAll('@', '').length >= 3;
    if (!worth) { setState(() { _hits = const []; _searched = false; _error = null; }); return; }
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      try {
        final r = await ref.read(tallyProvider.notifier).search(q);
        if (mounted && _q.text.trim() == q) setState(() { _hits = r; _searched = true; _error = null; });
      } catch (e) {
        if (mounted) setState(() => _error = describeError(e, action: 'search'));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TallyField(controller: _q, hint: '@handle, email or phone', label: 'Find someone on Tick', onChanged: _changed),
      for (final p in _hits) Pressable(
        onTap: () { TickHaptics.instance.selection(); widget.onPick(p); _q.clear(); setState(() { _hits = const []; _searched = false; }); },
        semanticLabel: 'Add ${p.name}', scale: 0.99,
        child: Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Row(children: [
          Avatar(p.name, 'shop', size: 36), const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.ts(TickType.title, size: 15.5)),
            if (p.handle != null) Text('@${p.handle}', style: context.ts(TickType.bodyS, size: 12.5, color: c.textSecondary)),
          ])),
        ])),
      ),
      if (_searched && _hits.isEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text('No one found. Add them by name instead.', style: context.ts(TickType.bodyS, color: c.textSecondary))),
      if (_error != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(_error!, style: context.ts(TickType.bodyS, color: c.alert))),
    ]);
  }
}

/// Invites to accept or decline, and (from phase 3) reminders.
class TallyInboxScreen extends ConsumerWidget {
  const TallyInboxScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(tallyProvider);
    if (t.inbox.any((r) => !r.read)) Future.microtask(() => ref.read(tallyProvider.notifier).markInboxSeen().catchError((_) {}));
    return TickPage(title: 'Inbox', onBack: () => context.pop(), onRefresh: () => ref.read(tallyProvider.notifier).refresh(), children: [
      if (t.invites.isEmpty && t.inbox.isEmpty) const EmptyState('Nothing waiting', 'Invites and reminders land here.', icon: 'tally'),
      for (final i in t.invites) _Invite(i: i),
      for (final r in t.inbox) Padding(padding: const EdgeInsets.only(bottom: 8), child: TickCard(onTap: () => context.push('/tally/${r.groupId}'), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${formatCents(r.amountCents)} for ${r.groupName}', style: context.ts(TickType.title, size: 16)),
        Text('${r.fromName} sent a reminder.', style: context.ts(TickType.bodyS, color: context.c.textSecondary)),
      ]))),
    ]);
  }
}

class _Invite extends ConsumerStatefulWidget {
  const _Invite({required this.i});
  final TallyInvite i;
  @override
  ConsumerState<_Invite> createState() => _InviteState();
}

class _InviteState extends ConsumerState<_Invite> {
  bool _busy = false;
  String? _error;
  Future<void> _go(bool accept) async {
    setState(() { _busy = true; _error = null; });
    try {
      await ref.read(tallyProvider.notifier).respondToInvite(widget.i.id, accept: accept);
      TickHaptics.instance.confirm();
    } catch (e) {
      if (mounted) setState(() { _busy = false; _error = describeError(e, action: 'answer that'); });
    }
  }
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Padding(padding: const EdgeInsets.only(bottom: 8), child: TickCard(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(widget.i.groupName, style: context.ts(TickType.title, size: 16)),
      Text('${widget.i.inviterName} added you to this tally.', style: context.ts(TickType.bodyS, color: c.textSecondary)),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(child: PillButton('Join', height: 44, busy: _busy, onTap: () => _go(true))),
        const SizedBox(width: 8),
        Expanded(child: PillButton('Decline', height: 44, style: PillStyle.quiet, onTap: _busy ? null : () => _go(false))),
      ]),
      if (_error != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(_error!, style: context.ts(TickType.bodyS, size: 12.5, color: c.alert))),
    ])));
  }
}

class HandleInfo {
  const HandleInfo(this.handle, this.discoverable, this.suggestion);
  final String? handle;
  final bool discoverable;
  final String? suggestion;
}

final handleProvider = FutureProvider<HandleInfo?>((ref) async {
  if (ref.watch(remoteProvider) == null || ref.watch(settingsProvider.select((s) => s.demoMode))) return null;
  final j = await ref.read(apiProvider).get('/people/handle');
  return HandleInfo(j['handle'] as String?, j['discoverable'] != false, j['suggestion'] as String?);
});

/// Choose a handle. Skippable: Tick works without one, friends just can't search for you by it.
Future<void> showHandleSheet(BuildContext context) => showTickSheet<void>(context, builder: (_) => const _HandleSheet());

class _HandleSheet extends ConsumerStatefulWidget {
  const _HandleSheet();
  @override
  ConsumerState<_HandleSheet> createState() => _HandleSheetState();
}

class _HandleSheetState extends ConsumerState<_HandleSheet> {
  final _h = TextEditingController();
  bool _busy = false, _seeded = false;
  String? _error;
  @override
  void dispose() { _h.dispose(); super.dispose(); }
  Future<void> _save() async {
    setState(() { _busy = true; _error = null; });
    try {
      await ref.read(apiProvider).post('/people/handle', {'handle': _h.text.trim()});
      ref.invalidate(handleProvider);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() { _busy = false; _error = describeError(e, action: 'save that handle'); });
    }
  }
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final info = ref.watch(handleProvider).value;
    if (!_seeded && info != null) { _seeded = true; _h.text = info.handle ?? info.suggestion ?? ''; }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Text('Pick a handle', style: context.ts(TickType.title)),
      const SizedBox(height: 4),
      Text('Friends use it to add you to a tally. Nobody can browse who is on Tick.', style: context.ts(TickType.bodyS, color: c.textSecondary)),
      const SizedBox(height: 12),
      TallyField(controller: _h, hint: 'your_handle', label: 'Handle', onChanged: (_) => setState(() {})),
      if (_error != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(_error!, style: context.ts(TickType.bodyS, color: c.alert))),
      const SizedBox(height: 12),
      PillButton('Save', busy: _busy, onTap: _h.text.trim().length < 3 ? null : _save),
      const SizedBox(height: 6),
      PillButton('Not now', style: PillStyle.quiet, onTap: () => Navigator.of(context).pop()),
    ]);
  }
}

/// Settings: the handle, and whether search can find me at all.
class HandleSettings extends ConsumerStatefulWidget {
  const HandleSettings({super.key});
  @override
  ConsumerState<HandleSettings> createState() => _HandleSettingsState();
}

class _HandleSettingsState extends ConsumerState<HandleSettings> {
  String? _error;
  Future<void> _discoverable(bool v) async {
    setState(() => _error = null);
    try {
      final r = ref.read(remoteProvider);
      await r?.db.from('profiles').update({'discoverable': v}).eq('user_id', r.db.auth.currentUser!.id);
      ref.invalidate(handleProvider);
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e, action: 'change that'));
    }
  }
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final info = ref.watch(handleProvider).value;
    return TickCard(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Pressable(onTap: () => showHandleSheet(context), scale: 0.99, semanticLabel: 'Change your handle', child: SizedBox(height: 44, child: Row(children: [
        Expanded(child: Text('Handle', style: context.ts(TickType.body))),
        Text(info?.handle == null ? 'Pick one' : '@${info!.handle}', style: context.ts(TickType.mono, color: c.textSecondary)),
      ]))),
      const Hairline(),
      Row(children: [
        Expanded(child: Text('Friends can find me', style: context.ts(TickType.body))),
        TickToggle(on: info?.discoverable ?? true, label: 'Friends can find me', onChanged: _discoverable),
      ]),
      Text((info?.discoverable ?? true) ? 'By exact handle, email or phone.' : 'Hidden from search. You can still be added by a share link.', style: context.ts(TickType.bodyS, size: 12.5, color: c.textSecondary)),
      if (_error != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(_error!, style: context.ts(TickType.bodyS, size: 12.5, color: c.alert))),
    ]));
  }
}

/// On Tally, until a handle exists.
class HandleNudge extends ConsumerWidget {
  const HandleNudge({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(handleProvider).value;
    if (info == null || info.handle != null) return const SizedBox.shrink();
    return Padding(padding: const EdgeInsets.only(bottom: 12), child: TickCard(onTap: () => showHandleSheet(context), child: Text('Pick a handle so friends can add you.', style: context.ts(TickType.body))));
  }
}
