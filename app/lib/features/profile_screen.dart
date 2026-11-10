import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../data/ledger.dart';
import '../data/link_info.dart';
import '../data/paystubs.dart';
import '../data/profile_data.dart';
import '../data/remote.dart';
import '../data/settings.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../design/widgets/more.dart';
import '../design/widgets/pickers.dart';
import '../design/widgets/scaffold.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import '../domain/payday.dart';
import '../domain/paychecks.dart';
import '../services/api.dart';
import '../services/haptics.dart';
import '../services/session.dart';
import 'common.dart';
import 'payday_editor.dart';
import 'settings_screen.dart' show showTokenSheet, signInWithGoogle;
import 'tally_expense_sheet.dart' show TallyField;
import 'tally_manage.dart' show showUndo;
import 'tally_people.dart' show HandleSettings;

const _every = {PayFrequency.weekly: 'Every week', PayFrequency.biweekly: 'Every two weeks', PayFrequency.semimonthly: 'Twice a month', PayFrequency.monthly: 'Every month'};

String scheduleLine(PaydayRule r, DateTime today) => '${_every[r.frequency]} · next ${DateFormat('EEE, MMM d').format(nextPayday(r, today))}';

/// Everything onboarding asked, editable. One card per subject, one-line summaries, a focused sheet per change.
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final l = ref.watch(ledgerProvider);
    final now = ref.watch(clockProvider)();
    final signedIn = ref.watch(userIdProvider) != null;
    final rule = s.rule;
    final c = context.c;
    final goals = l.goals;
    final checking = l.accounts.where((a) => a.type == 'checking' || a.type == 'cash').toList();
    final counted = checking.where((a) => a.includeInSafe).length;
    final rules = ref.watch(categoryRulesProvider).value ?? const <RuleRow>[];
    final memory = ref.watch(askMemoryProvider).value;
    final link = ref.watch(linkInfoProvider).value;
    final owner = s.demoMode || link == null || link.canLink;
    return TickPage(title: 'Profile', onBack: () => context.pop(), bottomPad: 40,
      trailing: Pressable(onTap: () => context.push('/settings'), semanticLabel: 'Settings', minSize: 44, child: SizedBox(width: 40, height: 44, child: Center(child: TickIcon('sliders', size: 22, color: c.text)))),
      children: [
        // ---- You
        ProfileGroup(title: 'You', rows: [
          ProfileRow(title: 'Avatar', summary: 'How you look in Tally', leading: Avatar(s.name ?? 'P', 'biz', size: 40), onTap: () => context.push('/avatar')),
          ProfileRow(title: s.name ?? 'Add your name', summary: signedIn ? 'Signed in with Google' : 'Not signed in', onTap: () => _editName(context, ref)),
          if (!signedIn) ProfileRow(title: 'Sign in with Google', summary: 'To sync and link banks', onTap: () => signInWithGoogle(context, ref)),
        ]),
        if (signedIn) ...[const SizedBox(height: TickSpace.x2), const HandleSettings()],
        // ---- Pay
        ProfileGroup(title: 'Pay', rows: [
          ProfileRow(title: 'Schedule', summary: rule == null ? 'Not set' : scheduleLine(rule, now), onTap: () => showPaySchedule(context, ref)),
          ProfileRow(title: 'Take-home', summary: rule == null || rule.amountCents == 0 ? 'Not set' : '${rule.varies ? 'About ' : ''}${formatCents(rule.amountCents)}${rule.varies ? ' · it varies' : ''}', onTap: () => showTakeHome(context, ref)),
          ProfileRow(title: 'Lands in', summary: l.account(rule?.accountId)?.shortLabel ?? 'Not set', onTap: () => _pickAccount(context, ref)),
          ProfileRow(title: 'Who pays you', summary: rule?.employer ?? 'Not set', onTap: () => _editEmployer(context, ref)),
          ProfileRow(title: 'Second income', summary: rule?.second == null ? 'None' : scheduleLine(rule!.second!, now), onTap: () => showSecondIncome(context, ref)),
          ProfileRow(title: 'Pay statements', summary: ref.watch(payStatementSummaryProvider), onTap: () => context.push('/pay-statements')),
        ]),
        // ---- Money setup
        ProfileGroup(title: 'Money setup', rows: [
          ProfileRow(title: 'Goals', summary: goals.isEmpty ? 'None yet' : '${goals.length} ${goals.length == 1 ? 'goal' : 'goals'}${goals.any((g) => g.paused) ? ' · ${goals.where((g) => g.paused).length} paused' : ''}', onTap: () => _goals(context)),
          ProfileRow(title: 'Recurring bills', summary: l.recurring.isEmpty ? 'None yet' : '${l.recurring.length} ${l.recurring.length == 1 ? 'bill' : 'bills'}', onTap: () => _bills(context)),
          ProfileRow(title: 'Accounts in Cash', summary: checking.isEmpty ? 'No checking accounts' : '$counted of ${checking.length} count', onTap: () => _cashAccounts(context)),
        ]),
        // ---- Categories and rules
        ProfileGroup(title: 'Categories and rules', rows: [
          ProfileRow(title: 'Category rules', summary: rules.isEmpty ? 'None yet' : '${rules.length} ${rules.length == 1 ? 'rule' : 'rules'}', onTap: () => _rules(context)),
          ProfileRow(title: 'What Ask Tick learned', summary: (memory?.aliases ?? const []).isEmpty ? 'Nothing yet' : '${memory!.aliases.length} ${memory.aliases.length == 1 ? 'word' : 'words'}', onTap: () => _aliases(context)),
          if ((memory?.proposals ?? 0) > 0) ProfileRow(title: 'Suggested rules', summary: '${memory!.proposals} to review', onTap: () => context.push('/profile/suggested-rules')),
        ]),
        // ---- Banks and cards
        ProfileGroup(title: 'Banks and cards', rows: [
          if (owner) ProfileRow(title: 'Banks', summary: l.connections.isEmpty ? 'None linked' : '${l.connections.length} linked', onTap: () => context.push('/banks'))
          else const ProfileRow(title: 'Banks', summary: 'Banks are linked by this Tick\'s owner'),
          ProfileRow(title: 'Apple Card', summary: 'Capture and statements', onTap: () => context.push('/apple-card')),
          ProfileRow(title: 'Capture token for Shortcuts', summary: 'For Apple Pay and alerts', onTap: () => showTokenSheet(context, ref)),
        ]),
        // ---- Help
        ProfileGroup(title: 'Help', rows: [
          ProfileRow(title: 'Show tips again', summary: 'The four tips, where they belong', onTap: () {
            ref.read(settingsProvider.notifier).resetTips();
            showUndo(Overlay.of(context, rootOverlay: true), 'Tips will show again', () async => ref.read(settingsProvider.notifier).restoreTips());
          }),
          ProfileRow(title: 'Watch the intro', summary: 'Half a minute', onTap: () => context.push('/intro')),
        ]),
      ]);
  }

  Future<void> _editName(BuildContext context, WidgetRef ref) async {
    final v = await showTextSheet(context, title: 'Your name', initial: ref.read(settingsProvider).name ?? '', confirm: 'Save');
    if (v == null || v.trim().isEmpty) return;
    ref.read(settingsProvider.notifier).update((s) => s.copyWith(name: v.trim()));
    try { await ref.read(remoteProvider)?.setDisplayName(v.trim()); } catch (_) {/* saved on this phone */}
  }

  Future<void> _pickAccount(BuildContext context, WidgetRef ref) async {
    final rule = ref.read(settingsProvider).rule;
    if (rule == null) return showPaySchedule(context, ref);
    final accts = ref.read(ledgerProvider).accounts.where((a) => a.type == 'checking' || a.type == 'cash').toList();
    final id = await showTickSheet<String>(context, builder: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Text('Where does your pay land?', style: ctx.ts(TickType.title)),
      const SizedBox(height: TickSpace.x3),
      if (accts.isEmpty) Text('Link a checking account first.', style: ctx.ts(TickType.body, color: ctx.c.textSecondary)),
      Wrap(spacing: 8, runSpacing: 8, children: [for (final a in accts) TickChip(a.shortLabel, on: a.id == rule.accountId, onTap: () => Navigator.of(ctx).pop(a.id))]),
    ]));
    if (id != null && context.mounted) await saveRule(context, ref, rule.copyWith(accountId: id));
  }

  Future<void> _editEmployer(BuildContext context, WidgetRef ref) async {
    final rule = ref.read(settingsProvider).rule;
    if (rule == null) return showPaySchedule(context, ref);
    final l = ref.read(ledgerProvider);
    final guess = guessPaychecks(l.txns, {for (final c in l.categories) c.id: c}, l.accounts);
    final v = await showTickSheet<String>(context, builder: (ctx) => _TextWithSuggestion(title: 'Who pays you?', hint: 'As the deposit says it', initial: rule.employer ?? '', suggestion: guess.employer,
        note: 'Tick uses it to recognise your paycheck when it lands.'));
    if (v != null && context.mounted) await saveRule(context, ref, rule.copyWith(employer: v.trim()));
  }

  void _goals(BuildContext context) => showTickSheet<void>(context, full: true, builder: (_) => const _GoalsSheet());
  void _bills(BuildContext context) => showTickSheet<void>(context, full: true, builder: (_) => const _BillsSheet());
  void _cashAccounts(BuildContext context) => showTickSheet<void>(context, builder: (_) => const _CashAccountsSheet());
  void _rules(BuildContext context) => showTickSheet<void>(context, full: true, builder: (_) => const _RulesSheet());
  void _aliases(BuildContext context) => showTickSheet<void>(context, full: true, builder: (_) => const _AliasesSheet());
}

/// "Latest: Nov 13 · $X net" once pay statements arrive (Phase 3); a quiet line until then.
final payStatementSummaryProvider = Provider<String>((ref) => payStatementSummary(ref.watch(payStatementsProvider).value ?? const []));

class ProfileGroup extends StatelessWidget {
  const ProfileGroup({super.key, required this.title, required this.rows});
  final String title;
  final List<Widget> rows;
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SectionLabel(title),
        TickCard(padding: const EdgeInsets.symmetric(horizontal: TickSpace.x4), child: Column(children: [
          for (final (i, r) in rows.indexed) ...[if (i > 0) const Hairline(), r],
        ])),
      ]);
}

class ProfileRow extends StatelessWidget {
  const ProfileRow({super.key, required this.title, required this.summary, this.onTap, this.leading});
  final String title;
  final String summary;
  final VoidCallback? onTap;
  final Widget? leading;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final row = ConstrainedBox(constraints: const BoxConstraints(minHeight: 56), child: Padding(padding: const EdgeInsets.symmetric(vertical: TickSpace.x2), child: Row(children: [
      if (leading != null) ...[leading!, const SizedBox(width: TickSpace.x3)],
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: context.ts(TickType.body)),
        Text(summary, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.ts(TickType.bodyS, color: c.textSecondary)),
      ])),
      if (onTap != null) TickIcon('chevron-right', size: 18, color: c.textSecondary),
    ])));
    return onTap == null ? Semantics(label: '$title. $summary', child: ExcludeSemantics(child: row)) : Pressable(onTap: onTap, scale: 0.99, semanticLabel: '$title. $summary', child: row);
  }
}

/// Saves the pay rule; the database is the truth, so the pay period, Safe to spend, Payday plan and nudges recompute from it. Past rows never change.
Future<void> saveRule(BuildContext context, WidgetRef ref, PaydayRule r) async {
  final overlay = Overlay.of(context, rootOverlay: true);
  ref.read(settingsProvider.notifier).update((s) => s.copyWith(rule: r));
  TickHaptics.instance.confirm();
  await Future<void>.delayed(const Duration(milliseconds: 600));
  ref.invalidate(payPeriodProvider);
  final next = nextPayday(r, ref.read(clockProvider)());
  showToast(overlay, 'Next payday ${DateFormat('EEE, MMM d').format(next)}${r.amountCents > 0 ? ' · ${formatCents(r.amountCents)} expected' : ''}');
}

/// A quiet confirmation above the tab bar.
void showToast(OverlayState overlay, String text) => showUndo(overlay, text, () async {}, action: null);

Future<void> showPaySchedule(BuildContext context, WidgetRef ref) async {
  final now = ref.read(clockProvider)();
  final current = ref.read(settingsProvider).rule;
  PaydayRule? draft;
  final ok = await showTickSheet<bool>(context, full: true, builder: (ctx) => SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
    Text('How often are you paid?', style: ctx.ts(TickType.title)),
    const SizedBox(height: TickSpace.x3),
    PaydayEditor(today: now, initial: current, onChanged: (r) => draft = r),
    const SizedBox(height: TickSpace.x2),
    Text('Paydays on a weekend or bank holiday count as the business day before. Past transactions don\'t change.', style: ctx.ts(TickType.bodyS, color: ctx.c.textSecondary)),
    const SizedBox(height: TickSpace.x4),
    PillButton('Save', onTap: () => Navigator.of(ctx).pop(true)),
  ])));
  final d = draft;
  if (ok == true && d != null && context.mounted) {
    final base = current ?? PaydayRule(frequency: d.frequency, anchor: d.anchor, amountCents: 0);
    await saveRule(context, ref, base.copyWith(frequency: d.frequency, anchor: d.anchor, days: d.days));
  }
}

Future<void> showTakeHome(BuildContext context, WidgetRef ref) async {
  final rule = ref.read(settingsProvider).rule;
  if (rule == null) return showPaySchedule(context, ref);
  final l = ref.read(ledgerProvider);
  final guess = guessPaychecks(l.txns, {for (final c in l.categories) c.id: c}, l.accounts);
  final r = await showTickSheet<(int, bool)>(context, builder: (_) => _TakeHomeSheet(rule: rule, guess: guess));
  if (r != null && context.mounted) await saveRule(context, ref, rule.copyWith(amountCents: r.$1, varies: r.$2));
}

class _TakeHomeSheet extends StatefulWidget {
  const _TakeHomeSheet({required this.rule, required this.guess});
  final PaydayRule rule;
  final PaycheckGuess guess;
  @override
  State<_TakeHomeSheet> createState() => _TakeHomeSheetState();
}

class _TakeHomeSheetState extends State<_TakeHomeSheet> {
  late final _a = TextEditingController(text: widget.rule.amountCents == 0 ? '' : formatCents(widget.rule.amountCents, symbol: false, raw: true));
  late bool _varies = widget.rule.varies;
  String? _error;
  @override
  void dispose() { _a.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final g = widget.guess;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Text('Take-home per paycheck', style: context.ts(TickType.title)),
      const SizedBox(height: TickSpace.x3),
      TallyField(controller: _a, hint: _varies ? 'A typical paycheck' : 'Amount', label: 'Take-home in dollars', keyboard: const TextInputType.numberWithOptions(decimal: true), onChanged: (_) => setState(() => _error = null)),
      if (g.typicalCents != null) Padding(padding: const EdgeInsets.only(top: TickSpace.x2), child: Align(alignment: Alignment.centerLeft, child: TickChip(
          'Use ${formatCents(g.typicalCents!)} from your last ${g.amounts.length == 1 ? 'paycheck' : '${g.amounts.length} paychecks'}', onTap: () => setState(() { _a.text = formatCents(g.typicalCents!, symbol: false, raw: true); _varies = g.varies; })))),
      const SizedBox(height: TickSpace.x2),
      Row(children: [
        Expanded(child: Text('It varies', style: context.ts(TickType.body))),
        TickToggle(on: _varies, label: 'It varies', onChanged: (v) => setState(() => _varies = v)),
      ]),
      if (_error != null) Text(_error!, style: context.ts(TickType.bodyS, color: c.alert)),
      const SizedBox(height: TickSpace.x3),
      PillButton('Save', onTap: () {
        final cents = parseCents(_a.text);
        if (cents == null || cents <= 0) { setState(() => _error = 'Enter an amount, like 2310.00.'); return; }
        Navigator.of(context).pop((cents, _varies));
      }),
    ]);
  }
}

class _TextWithSuggestion extends StatefulWidget {
  const _TextWithSuggestion({required this.title, required this.hint, required this.initial, this.suggestion, this.note});
  final String title, hint, initial;
  final String? suggestion, note;
  @override
  State<_TextWithSuggestion> createState() => _TextWithSuggestionState();
}

class _TextWithSuggestionState extends State<_TextWithSuggestion> {
  late final _t = TextEditingController(text: widget.initial);
  @override
  void dispose() { _t.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Text(widget.title, style: context.ts(TickType.title)),
        if (widget.note != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(widget.note!, style: context.ts(TickType.bodyS, color: context.c.textSecondary))),
        const SizedBox(height: TickSpace.x3),
        TallyField(controller: _t, hint: widget.hint, label: widget.title),
        if (widget.suggestion != null && widget.suggestion != _t.text) Padding(padding: const EdgeInsets.only(top: TickSpace.x2), child: Align(alignment: Alignment.centerLeft, child: TickChip('Use ${widget.suggestion}', onTap: () => setState(() => _t.text = widget.suggestion!)))),
        const SizedBox(height: TickSpace.x3),
        PillButton('Save', onTap: () => Navigator.of(context).pop(_t.text)),
      ]);
}

Future<void> showSecondIncome(BuildContext context, WidgetRef ref) async {
  final rule = ref.read(settingsProvider).rule;
  if (rule == null) return showPaySchedule(context, ref);
  final now = ref.read(clockProvider)();
  final cur = rule.second;
  PaydayRule? draft;
  final amount = TextEditingController(text: cur == null || cur.amountCents == 0 ? '' : formatCents(cur.amountCents, symbol: false, raw: true));
  final who = TextEditingController(text: cur?.employer ?? '');
  final res = await showTickSheet<String>(context, full: true, builder: (ctx) => SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
    Text('Second income', style: ctx.ts(TickType.title)),
    const SizedBox(height: TickSpace.x3),
    PaydayEditor(today: now, initial: cur, onChanged: (r) => draft = r),
    const SizedBox(height: TickSpace.x3),
    TallyField(controller: amount, hint: 'Take-home per payment', label: 'Second income take-home', keyboard: const TextInputType.numberWithOptions(decimal: true)),
    const SizedBox(height: TickSpace.x2),
    TallyField(controller: who, hint: 'Who pays it', label: 'Who pays the second income'),
    const SizedBox(height: TickSpace.x4),
    PillButton('Save', onTap: () => Navigator.of(ctx).pop('save')),
    if (cur != null) ...[const SizedBox(height: TickSpace.x2), PillButton('Remove second income', style: PillStyle.quiet, onTap: () => Navigator.of(ctx).pop('remove'))],
  ])));
  if (!context.mounted) return;
  if (res == 'remove') {
    await saveRule(context, ref, rule.copyWith(clearSecond: true));
    if (context.mounted) showUndo(Overlay.of(context, rootOverlay: true), 'Second income removed', () => saveRule(context, ref, rule));
  } else if (res == 'save' && draft != null) {
    await saveRule(context, ref, rule.copyWith(second: PaydayRule(frequency: draft!.frequency, anchor: draft!.anchor, days: draft!.days, amountCents: parseCents(amount.text) ?? 0, employer: who.text.trim().isEmpty ? null : who.text.trim())));
  }
}

class _GoalsSheet extends ConsumerWidget {
  const _GoalsSheet();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final goals = ref.watch(ledgerProvider).goals;
    final c = context.c;
    return SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Text('Goals', style: context.ts(TickType.title)),
      const SizedBox(height: TickSpace.x3),
      if (goals.isEmpty) const EmptyState('No goals yet', 'Name one, set a target, and choose what you move each payday.', icon: 'goal'),
      for (final g in goals) ProfileRow(title: g.paused ? '${g.name} · paused' : g.name, summary: '${formatCents(g.savedCents)} of ${formatCents(g.targetCents)} · ${formatCents(g.perPaydayCents)} each payday', onTap: () => _editGoal(context, ref, g)),
      const SizedBox(height: TickSpace.x3),
      PillButton('Add a goal', icon: 'plus', style: PillStyle.quiet, onTap: () => _editGoal(context, ref, null)),
      Padding(padding: const EdgeInsets.only(top: TickSpace.x2), child: Text('Paused goals plan nothing until you resume them.', style: context.ts(TickType.bodyS, color: c.textSecondary))),
    ]));
  }
}

Future<void> _editGoal(BuildContext context, WidgetRef ref, Goal? g) async {
  final name = TextEditingController(text: g?.name ?? '');
  final target = TextEditingController(text: g == null ? '' : formatCents(g.targetCents, symbol: false, raw: true));
  final per = TextEditingController(text: g == null ? '' : formatCents(g.perPaydayCents, symbol: false, raw: true));
  String? error;
  final res = await showTickSheet<String>(context, builder: (ctx) => StatefulBuilder(builder: (ctx, set) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
    Text(g == null ? 'New goal' : 'Edit goal', style: ctx.ts(TickType.title)),
    const SizedBox(height: TickSpace.x3),
    TallyField(controller: name, hint: 'Name, like Japan trip', label: 'Goal name'),
    const SizedBox(height: TickSpace.x2),
    TallyField(controller: target, hint: 'Target', label: 'Target in dollars', keyboard: const TextInputType.numberWithOptions(decimal: true)),
    const SizedBox(height: TickSpace.x2),
    TallyField(controller: per, hint: 'Each payday', label: 'Each payday in dollars', keyboard: const TextInputType.numberWithOptions(decimal: true)),
    if (error != null) Padding(padding: const EdgeInsets.only(top: TickSpace.x2), child: Text(error!, style: ctx.ts(TickType.bodyS, color: ctx.c.alert))),
    const SizedBox(height: TickSpace.x3),
    PillButton('Save', onTap: () {
      if (name.text.trim().isEmpty || (parseCents(target.text) ?? 0) <= 0) { set(() => error = 'A name and a target, please.'); return; }
      Navigator.of(ctx).pop('save');
    }),
    if (g != null) ...[
      const SizedBox(height: TickSpace.x2),
      PillButton(g.paused ? 'Resume' : 'Pause', style: PillStyle.quiet, onTap: () => Navigator.of(ctx).pop('pause')),
      const SizedBox(height: TickSpace.x2),
      PillButton('Delete goal', style: PillStyle.quiet, onTap: () => Navigator.of(ctx).pop('delete')),
    ],
  ])));
  if (!context.mounted || res == null) return;
  final n = ref.read(ledgerProvider.notifier);
  final overlay = Overlay.of(context, rootOverlay: true);
  switch (res) {
    case 'save':
      await n.saveGoal(Goal(id: g?.id ?? 'local-g-${DateTime.now().microsecondsSinceEpoch}', name: name.text.trim(), targetCents: parseCents(target.text)!, savedCents: g?.savedCents ?? 0, perPaydayCents: parseCents(per.text) ?? 0, paused: g?.paused ?? false));
    case 'pause':
      await n.saveGoal(g!.copyWith(paused: !g.paused));
    case 'delete':
      final ok = await showTickSheet<bool>(context, builder: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Text('Delete ${g!.name}?', style: ctx.ts(TickType.title)),
        const SizedBox(height: TickSpace.x3),
        PillButton('Delete', onTap: () => Navigator.of(ctx).pop(true)),
        const SizedBox(height: TickSpace.x2),
        PillButton('Keep it', style: PillStyle.quiet, onTap: () => Navigator.of(ctx).pop(false)),
      ]));
      if (ok == true) {
        await n.deleteGoal(g!.id);
        showUndo(overlay, '${g.name} deleted', () => n.saveGoal(Goal(id: 'local-g-${DateTime.now().microsecondsSinceEpoch}', name: g.name, targetCents: g.targetCents, savedCents: g.savedCents, perPaydayCents: g.perPaydayCents, paused: g.paused)));
      }
  }
}

class _BillsSheet extends ConsumerWidget {
  const _BillsSheet();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bills = [...ref.watch(ledgerProvider).recurring]..sort((a, b) => a.nextDate.compareTo(b.nextDate));
    return SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Text('Recurring bills', style: context.ts(TickType.title)),
      const SizedBox(height: TickSpace.x3),
      if (bills.isEmpty) const EmptyState('No bills yet', 'Tick spots them after two of the same charge a month apart.', icon: 'repeat'),
      for (final r in bills) ProfileRow(title: r.merchant, summary: '${formatCents(r.expectedCents)} · next ${DateFormat('MMM d').format(r.nextDate)}', onTap: () => _editBill(context, ref, r)),
    ]));
  }
}

Future<void> _editBill(BuildContext context, WidgetRef ref, Recurring r) async {
  final res = await showTickSheet<String>(context, builder: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
    Text(r.merchant, style: ctx.ts(TickType.title)),
    const SizedBox(height: TickSpace.x3),
    PillButton('Change amount', style: PillStyle.quiet, onTap: () => Navigator.of(ctx).pop('amount')),
    const SizedBox(height: TickSpace.x2),
    PillButton('Change next date', style: PillStyle.quiet, onTap: () => Navigator.of(ctx).pop('date')),
    const SizedBox(height: TickSpace.x2),
    PillButton('Not recurring', style: PillStyle.quiet, onTap: () => Navigator.of(ctx).pop('end')),
  ]));
  if (!context.mounted || res == null) return;
  final n = ref.read(ledgerProvider.notifier);
  if (res == 'amount') {
    final c = await showAmountSheet(context, title: r.merchant, initialCents: r.expectedCents, confirm: 'Save');
    if (c != null && c > 0) await n.updateRecurring(r, cents: c);
  } else if (res == 'date') {
    final d = await showDateSheet(context, initial: r.nextDate);
    if (d != null) await n.updateRecurring(r, next: dayOnly(d));
  } else {
    final overlay = Overlay.of(context, rootOverlay: true);
    await n.updateRecurring(r, ended: true);
    showUndo(overlay, '${r.merchant} isn\'t recurring', () => n.updateRecurring(r, ended: false));
  }
}

class _CashAccountsSheet extends ConsumerWidget {
  const _CashAccountsSheet();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accts = ref.watch(ledgerProvider).accounts.where((a) => a.type == 'checking' || a.type == 'cash').toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Text('Accounts in Cash', style: context.ts(TickType.title)),
      const SizedBox(height: 4),
      Text('Cash on Home and Safe to spend count the accounts switched on. Savings is always separate.', style: context.ts(TickType.bodyS, color: context.c.textSecondary)),
      const SizedBox(height: TickSpace.x3),
      for (final a in accts) Row(children: [
        Expanded(child: Text(a.shortLabel, style: context.ts(TickType.body))),
        TickToggle(on: a.includeInSafe, label: 'Count ${a.shortLabel} in Cash', onChanged: (v) => ref.read(ledgerProvider.notifier).setIncludeInSafe(a.id, v)),
      ]),
      if (accts.any((a) => !a.includeInSafe)) Padding(padding: const EdgeInsets.only(top: TickSpace.x2), child: Text('An account that\'s off still shows its own transactions; its balance just isn\'t in Cash.', style: context.ts(TickType.bodyS, color: context.c.textSecondary))),
    ]);
  }
}

class _RulesSheet extends ConsumerWidget {
  const _RulesSheet();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rules = ref.watch(categoryRulesProvider);
    return SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Text('Category rules', style: context.ts(TickType.title)),
      const SizedBox(height: TickSpace.x3),
      switch (rules) {
        AsyncData(:final value) when value.isEmpty => const EmptyState('No rules yet', 'Move a Zelle to Rent and Tick offers to make it a rule.', icon: 'repeat'),
        AsyncData(:final value) => Column(children: [
            for (final r in value) ProfileRow(title: '${r.person} → ${r.category}', summary: [if (r.amountCents != null) 'about ${formatCents(r.amountCents!)}', if (r.day != null) 'around day ${r.day}'].join(' · ').ifEmpty('Any amount, any day'),
                onTap: () => _editRule(context, ref, r)),
          ]),
        AsyncError(:final error) => ErrorState(title: 'Rules didn\'t load', body: describeError(error, action: 'load your rules'), onRetry: () async => ref.invalidate(categoryRulesProvider)),
        _ => const ListSkeleton(rows: 3),
      },
    ]));
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

Future<void> _editRule(BuildContext context, WidgetRef ref, RuleRow r) async {
  final res = await showTickSheet<String>(context, builder: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
    Text('${r.person} → ${r.category}', style: ctx.ts(TickType.title)),
    const SizedBox(height: TickSpace.x3),
    if (!r.ignored) ...[PillButton('Change the amount', style: PillStyle.quiet, onTap: () => Navigator.of(ctx).pop('amount')), const SizedBox(height: TickSpace.x2)],
    PillButton('Delete rule', style: PillStyle.quiet, onTap: () => Navigator.of(ctx).pop('delete')),
  ]));
  if (!context.mounted || res == null) return;
  final api = ref.read(apiProvider);
  try {
    if (res == 'amount') {
      final c = await showAmountSheet(context, title: 'About how much?', initialCents: r.amountCents ?? 0, confirm: 'Save');
      if (c != null && c > 0) await api.post('/rules/${r.id}/amount', {'amount_cents': c});
    } else {
      final ok = await showTickSheet<bool>(context, builder: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Text('Delete this rule?', style: ctx.ts(TickType.title)),
        const SizedBox(height: 4),
        Text('Payments it moved go back to Friends and family, unless you changed them by hand.', style: ctx.ts(TickType.body, color: ctx.c.textSecondary)),
        const SizedBox(height: TickSpace.x3),
        PillButton('Delete', onTap: () => Navigator.of(ctx).pop(true)),
        const SizedBox(height: TickSpace.x2),
        PillButton('Keep it', style: PillStyle.quiet, onTap: () => Navigator.of(ctx).pop(false)),
      ]));
      if (ok == true) {
        final j = await api.post('/rules/${r.id}/delete');
        if (context.mounted) showUndo(Overlay.of(context, rootOverlay: true), 'Rule deleted', () async { await api.post('/rules/restore', {'rule': j['rule']}); await ref.read(ledgerProvider.notifier).refresh(); });
      }
    }
    await ref.read(ledgerProvider.notifier).refresh();
    ref.invalidate(categoryRulesProvider);
  } catch (_) {/* nothing changed */}
}

class _AliasesSheet extends ConsumerWidget {
  const _AliasesSheet();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = ref.watch(askMemoryProvider);
    return SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Text('What Ask Tick learned', style: context.ts(TickType.title)),
      const SizedBox(height: TickSpace.x3),
      switch (m) {
        AsyncData(:final value) when value.aliases.isEmpty => const EmptyState('Nothing yet', 'When you correct an answer, the words you use land here.', icon: 'ask'),
        AsyncData(:final value) => Column(children: [
            for (final a in value.aliases) ProfileRow(title: '"${a.key}"', summary: 'means ${a.meaning}', onTap: () async {
              final api = ref.read(apiProvider);
              final overlay = Overlay.of(context, rootOverlay: true);
              try {
                final j = await api.post('/ask/memory/delete', {'key': a.key});
                ref.invalidate(askMemoryProvider);
                showUndo(overlay, '"${a.key}" forgotten', () async { await api.post('/ask/memory/restore', {'row': j['row']}); ref.invalidate(askMemoryProvider); });
              } catch (_) {/* nothing changed */}
            }),
            Padding(padding: const EdgeInsets.only(top: TickSpace.x2), child: Text('Tap a word to forget it.', style: context.ts(TickType.bodyS, color: context.c.textSecondary))),
          ]),
        AsyncError(:final error) => ErrorState(body: describeError(error, action: 'load this'), onRetry: () async => ref.invalidate(askMemoryProvider)),
        _ => const ListSkeleton(rows: 3),
      },
    ]));
  }
}
