import 'dart:async';
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
import '../design/widgets/scaffold.dart';
import '../design/widgets/swipe.dart';
import '../domain/flows.dart';
import '../domain/merchant_name.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import '../services/haptics.dart';
import 'ask_button.dart';
import 'common.dart';
import 'payback_card.dart';
import 'rule_cards.dart';
import 'splitwise_detail.dart';

/// Activity: ONE continuous list across every month (keyset pages of 40, prefetched ahead). A pinned month header carries that month's
/// in, out and net under the active filters and hands over to the next month as you scroll (light tick). Day headers carry the day's net.
class ActivityScreen extends ConsumerStatefulWidget {
  const ActivityScreen({super.key});
  @override
  ConsumerState<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends ConsumerState<ActivityScreen> {
  final _ctl = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  final _headerKeys = <DateTime, GlobalKey>{};
  Timer? _debounce;
  bool _searchOpen = false;
  DateTime? _activeMonth;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() { _debounce?.cancel(); _ctl.dispose(); _focus.dispose(); _scroll.dispose(); super.dispose(); }

  void _onScroll() {
    // Prefetch: ask for the next page while there are still about two screens of rows below.
    if (_scroll.hasClients && _scroll.position.extentAfter < 1600) ref.read(activityProvider.notifier).loadMore();
    _trackMonth();
  }

  /// The month whose pinned header is currently at the top; ticks lightly when it changes.
  void _trackMonth() {
    if (!mounted || _headerKeys.isEmpty) return;
    final top = MediaQuery.of(context).padding.top + _TitleBarHeight.bar + 2;
    DateTime? best;
    double bestY = -1e9;
    for (final e in _headerKeys.entries) {
      final box = e.value.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached) continue;
      final y = box.localToGlobal(Offset.zero).dy;
      if (y <= top && y > bestY) { best = e.key; bestY = y; }
    }
    if (best != null && best != _activeMonth) {
      final first = _activeMonth == null;
      _activeMonth = best;
      if (!first) TickHaptics.instance.selection();
    }
  }

  void _set(ActivityQuery q) => ref.read(activityProvider.notifier).setQuery(q);

  void _search(String v) {
    _debounce?.cancel();
    // Search runs on the server: wait for a pause in typing instead of querying every keystroke.
    _debounce = Timer(const Duration(milliseconds: 350), () => _set(ref.read(activityProvider).query.copyWith(query: v)));
    setState(() {});
  }

  void _toggleSearch() {
    setState(() => _searchOpen = !_searchOpen);
    if (_searchOpen) {
      Future<void>.delayed(const Duration(milliseconds: 60), () { if (mounted) _focus.requestFocus(); });
    } else {
      _ctl.clear();
      _focus.unfocus();
      _set(ref.read(activityProvider).query.copyWith(query: ''));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = ref.watch(ledgerProvider);
    final a = ref.watch(activityProvider);
    final q = a.query;
    final now = ref.watch(clockProvider)();
    final c = context.c;
    final reviewCount = l.needsReview.length;
    final notifier = ref.read(activityProvider.notifier);

    // Group the loaded rows into months, then days.
    final months = <DateTime, List<Txn>>{};
    for (final t in a.rows) {
      (months[monthOf(etDay(t.occurredAt))] ??= []).add(t);
    }
    _headerKeys.removeWhere((m, _) => !months.containsKey(m));
    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) { _onScroll(); } });

    final trailing = Row(mainAxisSize: MainAxisSize.min, children: [
      Pressable(onTap: _toggleSearch, semanticLabel: _searchOpen ? 'Close search' : 'Search', minSize: 44, child: SizedBox(width: 40, height: 44, child: Center(child: TickIcon(_searchOpen ? 'x' : 'search', size: 22, color: c.text)))),
      _FilterButton(count: q.filterCount, onTap: () => showActivityFilters(context)),
      const AskButton(),
    ]);

    return TickPage(
      title: 'Activity', trailing: trailing, controller: _scroll, onRefresh: notifier.refresh, bottomPad: 130,
      slivers: [
        for (final entry in months.entries)
          SliverMainAxisGroup(slivers: [
            SliverPersistentHeader(pinned: true, delegate: _MonthHeader(month: entry.key, filters: q, colors: c, textScaler: MediaQuery.of(context).textScaler, headerKey: _headerKeys.putIfAbsent(entry.key, GlobalKey.new))),
            SliverPadding(padding: const EdgeInsets.symmetric(horizontal: 20), sliver: _MonthRows(rows: entry.value, a: a, ledger: l, now: now)),
          ]),
        if (a.rows.isNotEmpty && (a.loadingMore || a.hasMore))
          SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: Semantics(label: 'Loading more', child: const ListSkeleton(rows: 2)))),
        if (a.rows.isNotEmpty && !a.hasMore && !a.loadingMore)
          SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.fromLTRB(20, 20, 20, 0), child: Text('That\'s everything Tick has.', textAlign: TextAlign.center, style: context.ts(TickType.bodyS, color: c.textSecondary)))),
      ],
      children: [
        if (reviewCount > 0)
          Align(alignment: Alignment.centerLeft, child: Padding(padding: const EdgeInsets.only(bottom: 8), child: TickChip('$reviewCount to check', icon: 'caught', onTap: () => context.push('/caught')))),
        AnimatedSize(
          duration: context.reduceMotion ? Duration.zero : const Duration(milliseconds: 220), curve: Curves.easeOutCubic, alignment: Alignment.topCenter,
          child: !_searchOpen ? const SizedBox(width: double.infinity) : Padding(padding: const EdgeInsets.only(bottom: 8), child: _SearchField(controller: _ctl, focus: _focus, onChanged: _search)),
        ),
        if (q.anyFilter || q.upTo != null)
          Padding(padding: const EdgeInsets.only(bottom: 4), child: _ActiveFilters(q: q, ledger: l, onChange: _set)),
        if (a.offline) OfflineBanner(onRetry: notifier.refresh),
        if (!q.anyFilter) const PaybackBanner(),
        if (a.loading && a.rows.isEmpty) const ListSkeleton(rows: 8)
        else if (a.error && a.rows.isEmpty) ErrorState(onRetry: notifier.refresh)
        else if (a.rows.isEmpty)
          EmptyState(q.anyFilter ? 'No matches' : 'Nothing here yet', q.anyFilter ? 'Try a different search or clear the filters.' : 'Add your first one in three taps.', icon: 'search'),
      ]
    );
  }
}

class _TitleBarHeight {
  static const bar = 52.0;
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.focus, required this.onChanged});
  final TextEditingController controller;
  final FocusNode focus;
  final ValueChanged<String> onChanged;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      constraints: const BoxConstraints(minHeight: 48), padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), decoration: BoxDecoration(color: c.surface1, borderRadius: BorderRadius.circular(999)),
      child: Row(children: [
        TickIcon('search', size: 20, color: c.textSecondary), const SizedBox(width: 8),
        Expanded(child: Semantics(
          textField: true, label: 'Search merchants, notes and categories',
          child: Stack(alignment: Alignment.centerLeft, children: [
            if (controller.text.isEmpty) IgnorePointer(child: Text('Search merchants, notes, categories', maxLines: 1, overflow: TextOverflow.ellipsis, style: context.ts(TickType.body, color: c.textSecondary))),
            EditableText(controller: controller, focusNode: focus, style: context.ts(TickType.body), cursorColor: c.text, backgroundCursorColor: c.surface2, selectionColor: c.hairline, onChanged: onChanged),
          ]),
        )),
      ]),
    );
  }
}

class _FilterButton extends StatelessWidget {
  const _FilterButton({required this.count, required this.onTap});
  final int count;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Pressable(
      onTap: onTap, semanticLabel: count == 0 ? 'Filters' : 'Filters, $count active', minSize: 44,
      child: SizedBox(width: 44, height: 44, child: Stack(alignment: Alignment.center, children: [
        TickIcon('sliders', size: 22, color: c.text),
        if (count > 0)
          Positioned(top: 6, right: 4, child: Container(
            constraints: const BoxConstraints(minWidth: 16, minHeight: 16), padding: const EdgeInsets.symmetric(horizontal: 4), alignment: Alignment.center,
            decoration: BoxDecoration(color: c.accent, borderRadius: BorderRadius.circular(999)),
            child: Text('$count', style: TextStyle(fontFamily: TickFamilies.mono, fontWeight: FontWeight.w700, fontSize: 10.5, height: 1.2, color: c.onAccent, decoration: TextDecoration.none)),
          )),
      ])),
    );
  }
}

/// One compact row of removable pills, only while a filter is set.
class _ActiveFilters extends StatelessWidget {
  const _ActiveFilters({required this.q, required this.ledger, required this.onChange});
  final ActivityQuery q;
  final LedgerState ledger;
  final ValueChanged<ActivityQuery> onChange;
  @override
  Widget build(BuildContext context) {
    final typeLabel = {for (final (t, label) in accountTypeChips) t: label};
    final pills = <(String, ActivityQuery)>[
      for (final t in q.types) (typeLabel[t] ?? t, q.copyWith(types: {...q.types}..remove(t))),
      for (final id in q.accounts) (ledger.account(id)?.shortLabel ?? 'Account', q.copyWith(accounts: {...q.accounts}..remove(id))),
      for (final id in q.categories) (ledger.category(id)?.name ?? 'Category', q.copyWith(categories: {...q.categories}..remove(id))),
      if (q.review) ('Needs review', q.copyWith(review: false)),
      if (q.business) ('Business', q.copyWith(business: false)),
      if (q.query.trim().isNotEmpty) ('“${q.query.trim()}”', q.copyWith(query: '')),
      if (q.upTo != null) ('Up to ${DateFormat('MMM y').format(q.upTo!)}', q.copyWith(clearUpTo: true)),
    ];
    return ChipRow(children: [
      for (final (label, next) in pills) _RemovablePill(label: label, onTap: () => onChange(next)),
      if (pills.length > 1) _RemovablePill(label: 'Clear all', onTap: () => onChange(const ActivityQuery()), quiet: true),
    ]);
  }
}

class _RemovablePill extends StatelessWidget {
  const _RemovablePill({required this.label, required this.onTap, this.quiet = false});
  final String label;
  final VoidCallback onTap;
  final bool quiet;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Pressable(
      onTap: onTap, semanticLabel: quiet ? label : 'Remove filter $label', minSize: 44,
      child: Container(
        constraints: const BoxConstraints(minHeight: 32), padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(color: quiet ? const Color(0x00000000) : c.surface1, borderRadius: BorderRadius.circular(999), border: Border.all(color: c.hairline)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(label, style: context.ts(TickType.bodyS, size: 13, color: quiet ? c.textSecondary : c.text).copyWith(fontWeight: FontWeight.w700)),
          if (!quiet) ...[const SizedBox(width: 6), TickIcon('x', size: 14, color: c.textSecondary)],
        ]),
      ),
    );
  }
}

/// A month's rows: day headers (with the day's net from the server) and swipeable rows.
class _MonthRows extends StatelessWidget {
  const _MonthRows({required this.rows, required this.a, required this.ledger, required this.now});
  final List<Txn> rows;
  final ActivityState a;
  final LedgerState ledger;
  final DateTime now;
  @override
  Widget build(BuildContext context) {
    final items = <Object>[];
    DateTime? last;
    for (final t in rows) {
      final d = etDay(t.occurredAt);
      if (d != last) { items.add(d); last = d; }
      items.add(t);
    }
    final c = context.c;
    return SliverList.builder(
      itemCount: items.length,
      itemBuilder: (context, i) {
        final it = items[i];
        if (it is DateTime) {
          final total = a.dayTotals[it];
          return SectionLabel(dayLabel(it, now), trailing: total == null ? null : Text(formatCents(total, sign: true), style: context.ts(TickType.monoS, color: total == 0 ? c.textSecondary : c.text)));
        }
        return ActivityRow(t: it as Txn, ledger: ledger);
      },
    );
  }
}

/// A transaction row with swipe actions (categorise, split with Tally, mark reviewed) and the hero transition to its detail.
class ActivityRow extends ConsumerWidget {
  const ActivityRow({super.key, required this.t, required this.ledger});
  final Txn t;
  final LedgerState ledger;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SwipeActions(
      onThreshold: TickHaptics.instance.selection,
      onOpen: () => TickHaptics.instance.sortLeft(),
      actions: [
        SwipeAction('Categorise', 'edit', () => showCategorySheet(context, ref, t)),
        SwipeAction('Split', 'split', () => context.push('/tally/split/${t.id}')),
        if (t.needsReview) SwipeAction('Reviewed', 'check', () { TickHaptics.instance.sortRight(); ref.read(ledgerProvider.notifier).markLooksRight(t.id); }, emphasis: true)
        else SwipeAction(t.isBusiness ? 'Not business' : 'Business', 'briefcase', () { TickHaptics.instance.sortUp(); ref.read(ledgerProvider.notifier).toggleBusiness(t.id); }),
      ],
      child: TxRow(t: t, ledger: ledger, hero: true, onTap: () => context.push('/txn/${t.id}')),
    );
  }
}

Future<void> showCategorySheet(BuildContext context, WidgetRef ref, Txn t) {
  final cats = ref.read(ledgerProvider).categories.where((c) => c.kind != 'transfer').toList();
  return showTickSheet<void>(context, builder: (ctx) => SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Fix category', style: ctx.ts(TickType.displayM)),
          const SizedBox(height: 4),
          Text(cleanMerchant(t.merchant), style: ctx.ts(TickType.body, color: ctx.c.textSecondary)),
          const SizedBox(height: 16),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final c in cats)
              TickChip(c.name, on: c.id == t.categoryId, onTap: () {
                final root = Navigator.of(context, rootNavigator: true).context;
                ref.read(ledgerProvider.notifier).recategorize(t.id, c.id);
                Navigator.of(ctx).pop();
                final who = p2pName(t.merchant);
                if (who != null && c.name == 'Rent' && t.amountCents < 0 && root.mounted) showRuleOffer(root, ref, t, c, who);
                if (c.name == 'Splitwise' && root.mounted) askSplitwiseWho(root, ref, t);
              }),
          ]),
        ]),
      ));
}

/// The pinned month header: the month, then in / out / net for that month under the active filters, crossfading when the numbers arrive.
class _MonthHeader extends SliverPersistentHeaderDelegate {
  _MonthHeader({required this.month, required this.filters, required this.colors, required this.textScaler, required this.headerKey});
  final DateTime month;
  final ActivityQuery filters;
  final TickColors colors;
  final TextScaler textScaler;
  final GlobalKey headerKey;

  double get _h => 20 + textScaler.scale(20) * 1.2 + textScaler.scale(14) * 1.3 + 6;
  @override
  double get minExtent => _h;
  @override
  double get maxExtent => _h;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) => KeyedSubtree(
        key: headerKey,
        child: Container(
          decoration: BoxDecoration(color: colors.bg, border: overlapsContent ? Border(bottom: BorderSide(color: colors.hairline)) : null),
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
          alignment: Alignment.centerLeft,
          child: _MonthSummary(month: month, filters: filters),
        ),
      );

  @override
  bool shouldRebuild(_MonthHeader old) => old.month != month || old.filters != filters || old.colors != colors || old.textScaler != textScaler;
}

class _MonthSummary extends ConsumerWidget {
  const _MonthSummary({required this.month, required this.filters});
  final DateTime month;
  final ActivityQuery filters;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final totals = ref.watch(monthTotalsProvider(MonthKey(filters, month))).value;
    final reduce = context.reduceMotion;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Semantics(header: true, child: Text(DateFormat('MMMM y').format(month), maxLines: 1, overflow: TextOverflow.ellipsis, style: context.ts(TickType.title, size: 20))),
      AnimatedSwitcher(
        duration: reduce ? Duration.zero : const Duration(milliseconds: 220),
        child: totals == null
            ? Text(' ', key: const ValueKey('wait'), style: context.ts(TickType.monoS))
            : Semantics(
                key: ValueKey('${totals.inCents}/${totals.outCents}'), excludeSemantics: true,
                label: '${DateFormat('MMMM').format(month)}: ${formatCents(totals.inCents)} in, ${formatCents(totals.outCents)} out, net ${formatCents(totals.netCents.abs())} ${totals.netCents >= 0 ? 'ahead' : 'behind'}',
                child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(
                    'In ${formatCents(totals.inCents)}   Out ${formatCents(totals.outCents)}   Net ${formatCents(totals.netCents, sign: true)}', maxLines: 1, style: context.ts(TickType.monoS, size: 13, color: c.textSecondary))),
              ),
      ),
    ]);
  }
}

/// Filters sheet: account type, accounts, categories, needs review, and jump to a month. Applies as you tap.
Future<void> showActivityFilters(BuildContext context) => showTickSheet<void>(context, full: true, builder: (ctx) => const _FilterSheet());

class _FilterSheet extends ConsumerWidget {
  const _FilterSheet();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = ref.watch(activityProvider);
    final q = a.query;
    final l = ref.watch(ledgerProvider);
    final c = context.c;
    final n = ref.read(activityProvider.notifier);
    Set<String> toggle(Set<String> s, String v) => s.contains(v) ? ({...s}..remove(v)) : {...s, v};
    Widget group(String title, Widget body) => Padding(padding: const EdgeInsets.only(bottom: 20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: context.ts(TickType.bodyS, size: 13, color: c.textSecondary).copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          body,
        ]));
    final accountOptions = l.accounts.where((x) => q.types.isEmpty || q.types.contains(x.type)).toList();
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(child: Text('Filters', style: context.ts(TickType.displayM))),
        if (q.filterCount > 0) TickChip('Clear all', onTap: () => n.setQuery(q.clearFilters())),
      ]),
      const SizedBox(height: 16),
      Flexible(child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        group('Account type', Wrap(spacing: 8, runSpacing: 4, children: [
          for (final (type, label) in accountTypeChips) if (l.accounts.any((x) => x.type == type)) TickChip(label, on: q.types.contains(type), onTap: () => n.setQuery(q.copyWith(types: toggle(q.types, type), accounts: {}))),
        ])),
        if (accountOptions.isNotEmpty)
          group('Accounts', Wrap(spacing: 8, runSpacing: 4, children: [
            for (final x in accountOptions) TickChip(x.shortLabel, on: q.accounts.contains(x.id), onTap: () => n.setQuery(q.copyWith(accounts: toggle(q.accounts, x.id)))),
          ])),
        group('Categories', Wrap(spacing: 8, runSpacing: 4, children: [
          for (final cat in l.categories.where((x) => x.kind != 'income')) TickChip(cat.name, on: q.categories.contains(cat.id), onTap: () => n.setQuery(q.copyWith(categories: toggle(q.categories, cat.id)))),
        ])),
        group('Show only', Wrap(spacing: 8, runSpacing: 4, children: [
          TickChip('Needs review', on: q.review, onTap: () => n.setQuery(q.copyWith(review: !q.review))),
          TickChip('Business', on: q.business, onTap: () => n.setQuery(q.copyWith(business: !q.business))),
        ])),
        if (a.months.isNotEmpty)
          group('Jump to month', Wrap(spacing: 8, runSpacing: 4, children: [
            for (final m in a.months.take(24)) TickChip(DateFormat('MMM y').format(m.month), on: q.upTo == m.month, onTap: () { n.setQuery(q.copyWith(upTo: m.month)); Navigator.of(context).pop(); }),
          ])),
      ]))),
      const SizedBox(height: 8),
      PillButton('Done', onTap: () => Navigator.of(context).pop()),
    ]);
  }
}
