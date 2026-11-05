import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:async';
import 'package:intl/intl.dart';
import 'package:go_router/go_router.dart';
import '../data/activity.dart';
import '../data/ledger.dart';
import '../domain/flows.dart';
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

class ActivityScreen extends ConsumerStatefulWidget {
  const ActivityScreen({super.key});
  @override
  ConsumerState<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends ConsumerState<ActivityScreen> {
  final _ctl = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      // Infinite scroll: ask for the next page when the end is within about two screens.
      if (_scroll.position.extentAfter < 900) ref.read(activityProvider.notifier).loadMore();
    });
  }

  @override
  void dispose() { _debounce?.cancel(); _ctl.dispose(); _focus.dispose(); _scroll.dispose(); super.dispose(); }

  void _set(ActivityQuery q) => ref.read(activityProvider.notifier).setQuery(q);

  void _search(String v) {
    setState(() {});
    _debounce?.cancel();
    // Search runs on the server: wait for a pause in typing instead of querying every keystroke.
    _debounce = Timer(const Duration(milliseconds: 350), () => _set(ref.read(activityProvider).query.copyWith(query: v)));
  }

  @override
  Widget build(BuildContext context) {
    final l = ref.watch(ledgerProvider);
    final a = ref.watch(activityProvider);
    final q = a.query;
    final now = ref.watch(clockProvider)();
    final c = context.c;
    final reviewCount = l.needsReview.length;
    final thisMonth = monthOf(now);
    final months = [thisMonth, ...a.months.map((m) => m.month).where((m) => m != thisMonth)]..sort((x, y) => y.compareTo(x));
    final visibleAccounts = l.accounts.where((x) => q.types.isEmpty || q.types.contains(x.type)).toList();
    // Group the loaded rows by day; each day's header total comes from the server (whole filter, not just loaded rows).
    final items = <Object>[];
    DateTime? last;
    for (final t in a.rows) {
      final d = etDay(t.occurredAt);
      if (d != last) { items.add(d); last = d; }
      items.add(t);
    }

    Set<String> toggle(Set<String> s, String v) => s.contains(v) ? ({...s}..remove(v)) : {...s, v};

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ScreenTitle('Activity', trailing: reviewCount == 0 ? null : TickChip('$reviewCount to check', icon: 'caught', onTap: () => context.push('/caught'))),
      // Month strip
      SizedBox(
        height: 36,
        child: ListView(scrollDirection: Axis.horizontal, clipBehavior: Clip.none, children: [
          for (final m in months) ...[
            TickChip(DateFormat('MMM y').format(m), on: q.month == m, onTap: () => _set(q.copyWith(month: m))),
            const SizedBox(width: 8),
          ],
          TickChip('All time', on: q.month == null, onTap: () => _set(q.copyWith(allTime: true))),
        ]),
      ),
      const SizedBox(height: 10),
      _TotalsLine(totals: a.totals, label: q.month == null ? 'All time' : DateFormat('MMMM').format(q.month!)),
      const SizedBox(height: 10),
      Container(
        height: 48, padding: const EdgeInsets.symmetric(horizontal: 16), decoration: BoxDecoration(color: c.surface1, borderRadius: BorderRadius.circular(999)),
        child: Row(children: [
          TickIcon('search', size: 20, color: c.textSecondary), const SizedBox(width: 8),
          Expanded(child: Stack(alignment: Alignment.centerLeft, children: [
            if (_ctl.text.isEmpty) IgnorePointer(child: Text('Search merchants, notes, categories', maxLines: 1, overflow: TextOverflow.ellipsis, style: context.ts(TickType.body, color: c.textSecondary))),
            EditableText(
              controller: _ctl, focusNode: _focus, style: context.ts(TickType.body), cursorColor: c.text, backgroundCursorColor: c.surface2, selectionColor: c.hairline,
              onChanged: _search,
            ),
          ])),
        ]),
      ),
      const SizedBox(height: 12),
      // Account types + accounts (multi-select), then the existing tag and category chips.
      SizedBox(
        height: 36,
        child: ListView(scrollDirection: Axis.horizontal, clipBehavior: Clip.none, children: [
          TickChip('All', on: !q.anyFilter, onTap: () { _ctl.clear(); _set(q.clearFilters()); }),
          for (final (type, label) in accountTypeChips)
            if (l.accounts.any((x) => x.type == type)) ...[
              const SizedBox(width: 8),
              TickChip(label, on: q.types.contains(type), onTap: () => _set(q.copyWith(types: toggle(q.types, type), accounts: {}))),
            ],
          for (final acct in visibleAccounts) ...[
            const SizedBox(width: 8),
            TickChip(acct.shortLabel, on: q.accounts.contains(acct.id), onTap: () => _set(q.copyWith(accounts: toggle(q.accounts, acct.id)))),
          ],
        ]),
      ),
      const SizedBox(height: 8),
      SizedBox(
        height: 36,
        child: ListView(scrollDirection: Axis.horizontal, clipBehavior: Clip.none, children: [
          TickChip('Business', on: q.business, onTap: () => _set(q.copyWith(business: !q.business))),
          const SizedBox(width: 8),
          TickChip('Needs review', on: q.review, onTap: () => _set(q.copyWith(review: !q.review))),
          for (final cat in l.categories.where((c) => c.kind == 'spend').take(8)) ...[
            const SizedBox(width: 8),
            TickChip(cat.name, on: q.categories.contains(cat.id), onTap: () => _set(q.copyWith(categories: toggle(q.categories, cat.id)))),
          ],
        ]),
      ),
      Expanded(
        child: () {
          final notifier = ref.read(activityProvider.notifier);
          if (a.loading && a.rows.isEmpty) return const ListSkeleton(rows: 8);
          if (a.error && a.rows.isEmpty) return ErrorState(onRetry: notifier.refresh);
          return TickScrollView(
            controller: _scroll,
            onRefresh: notifier.refresh,
            slivers: [
              if (a.offline) SliverToBoxAdapter(child: OfflineBanner(onRetry: notifier.refresh)),
              if (a.rows.isEmpty)
                SliverToBoxAdapter(child: EmptyState(q.anyFilter ? 'No matches' : 'Nothing here yet',
                    q.anyFilter ? 'Try a different search or clear the filters.' : (q.month == null ? 'Add your first one in three taps.' : 'Nothing this month yet.'), icon: 'search'))
              else
                SliverList.builder(
                  itemCount: items.length,
                  itemBuilder: (context, i) {
                    final it = items[i];
                    if (it is DateTime) {
                      final total = a.dayTotals[it];
                      return SectionLabel(dayLabel(it, now), trailing: total == null ? null : Text(formatCents(total, sign: true), style: context.ts(TickType.monoS, color: c.textSecondary)));
                    }
                    final t = it as Txn;
                    return _SwipeRow(t: t, ledger: l, child: TxRow(t: t, ledger: l, hero: true, onTap: () => context.push('/txn/${t.id}')));
                  },
                ),
              if (a.loadingMore || a.hasMore) SliverToBoxAdapter(child: Semantics(label: 'Loading more', child: const ListSkeleton(rows: 2))),
              const SliverToBoxAdapter(child: SizedBox(height: 130)),
            ],
          );
        }(),
      ),
    ]);
  }
}

/// In, out and net for the selected month (or all time), from the server's totals.
class _TotalsLine extends StatelessWidget {
  const _TotalsLine({required this.totals, required this.label});
  final Totals? totals;
  final String label;
  @override
  Widget build(BuildContext context) {
    final t = totals;
    final c = context.c;
    if (t == null) return const SizedBox(height: 22, child: Align(alignment: Alignment.centerLeft, child: SizedBox(width: 220, height: 14, child: Skeleton())));
    return Semantics(
      label: '$label: ${formatCents(t.inCents)} in, ${formatCents(t.outCents)} out, net ${formatCents(t.netCents.abs())} ${t.netCents >= 0 ? 'ahead' : 'behind'}',
      excludeSemantics: true,
      child: Wrap(spacing: 14, runSpacing: 4, children: [
        Row(mainAxisSize: MainAxisSize.min, children: [Text('In ', style: context.ts(TickType.monoS, color: c.textSecondary)), Money(t.inCents, kind: MoneyKind.income, sign: false, style: context.ts(TickType.monoS))]),
        Text('Out ${formatCents(t.outCents)}', style: context.ts(TickType.monoS)),
        Text('Net ${formatCents(t.netCents, sign: true)}', style: context.ts(TickType.monoS, color: c.textSecondary)),
      ]),
    );
  }
}

/// Swipe right = tag Business, swipe left = recategorize. Actions fire haptics and never remove the row.
class _SwipeRow extends ConsumerWidget {
  const _SwipeRow({required this.t, required this.ledger, required this.child});
  final Txn t;
  final LedgerState ledger;
  final Widget child;
  @override
  Widget build(BuildContext context, WidgetRef ref) => Dismissible(
        key: ValueKey(t.id),
        background: Container(alignment: Alignment.centerLeft, padding: const EdgeInsets.only(left: 8), child: Row(children: [TickIcon('briefcase', color: context.c.text), const SizedBox(width: 8), Text(t.isBusiness ? 'Remove Business' : 'Business', style: context.ts(TickType.label))])),
        secondaryBackground: Container(alignment: Alignment.centerRight, padding: const EdgeInsets.only(right: 8), child: Row(mainAxisSize: MainAxisSize.min, children: [Text('Fix', style: context.ts(TickType.label)), const SizedBox(width: 8), TickIcon('edit', color: context.c.text)])),
        confirmDismiss: (dir) async {
          if (dir == DismissDirection.startToEnd) {
            TickHaptics.instance.sortUp();
            await ref.read(ledgerProvider.notifier).toggleBusiness(t.id);
          } else {
            TickHaptics.instance.sortLeft();
            if (context.mounted) await showCategorySheet(context, ref, t);
          }
          return false;
        },
        child: child,
      );
}

Future<void> showCategorySheet(BuildContext context, WidgetRef ref, Txn t) {
  final cats = ref.read(ledgerProvider).categories.where((c) => c.kind != 'transfer').toList();
  return showTickSheet<void>(context, builder: (ctx) => SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Fix category', style: ctx.ts(TickType.displayM)),
          const SizedBox(height: 4),
          Text(t.merchant, style: ctx.ts(TickType.body, color: ctx.c.textSecondary)),
          const SizedBox(height: 16),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final c in cats)
              TickChip(c.name, on: c.id == t.categoryId, onTap: () { ref.read(ledgerProvider.notifier).recategorize(t.id, c.id); Navigator.of(ctx).pop(); }),
          ]),
        ]),
      ));
}
