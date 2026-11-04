import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:go_router/go_router.dart';
import '../data/ledger.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../design/widgets/more.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import '../domain/payday.dart';
import '../services/haptics.dart';
import 'common.dart';

class ActivityFilter {
  const ActivityFilter({this.query = '', this.business = false, this.review = false, this.categoryId, this.accountId});
  final String query;
  final bool business;
  final bool review;
  final String? categoryId;
  final String? accountId;
  bool get any => business || review || categoryId != null || accountId != null || query.isNotEmpty;
  ActivityFilter copyWith({String? query, bool? business, bool? review, String? categoryId, String? accountId, bool clearCat = false, bool clearAcct = false}) => ActivityFilter(
      query: query ?? this.query, business: business ?? this.business, review: review ?? this.review, categoryId: clearCat ? null : categoryId ?? this.categoryId, accountId: clearAcct ? null : accountId ?? this.accountId);
  bool matches(Txn t, LedgerState l) {
    if (business && !t.isBusiness) return false;
    if (review && !t.needsReview) return false;
    if (categoryId != null && t.categoryId != categoryId) return false;
    if (accountId != null && t.accountId != accountId) return false;
    if (query.isNotEmpty) {
      final q = query.toLowerCase();
      final hay = '${t.merchant} ${t.note ?? ''} ${l.category(t.categoryId)?.name ?? ''}'.toLowerCase();
      if (!hay.contains(q)) return false;
    }
    return true;
  }
}

final activityFilterProvider = StateProvider<ActivityFilter>((ref) => const ActivityFilter());

class ActivityScreen extends ConsumerStatefulWidget {
  const ActivityScreen({super.key});
  @override
  ConsumerState<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends ConsumerState<ActivityScreen> {
  final _ctl = TextEditingController();
  final _focus = FocusNode();
  @override
  void dispose() { _ctl.dispose(); _focus.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final l = ref.watch(ledgerProvider);
    final f = ref.watch(activityFilterProvider);
    final now = ref.watch(clockProvider)();
    final c = context.c;
    final list = l.txns.where((t) => f.matches(t, l)).toList();
    // Group by day
    final groups = <DateTime, List<Txn>>{};
    for (final t in list) { groups.putIfAbsent(dayOnly(t.occurredAt), () => []).add(t); }
    final days = groups.keys.toList()..sort((a, b) => b.compareTo(a));
    final reviewCount = l.needsReview.length;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ScreenTitle('Activity', trailing: reviewCount == 0 ? null : TickChip('$reviewCount to check', icon: 'caught', onTap: () => context.push('/caught'))),
      Container(
        height: 48, padding: const EdgeInsets.symmetric(horizontal: 16), decoration: BoxDecoration(color: c.surface1, borderRadius: BorderRadius.circular(999)),
        child: Row(children: [
          TickIcon('search', size: 20, color: c.textSecondary), const SizedBox(width: 8),
          Expanded(child: Stack(alignment: Alignment.centerLeft, children: [
            if (_ctl.text.isEmpty) IgnorePointer(child: Text('Search merchants, notes', style: context.ts(TickType.body, color: c.textSecondary))),
            EditableText(
              controller: _ctl, focusNode: _focus, style: context.ts(TickType.body), cursorColor: c.text, backgroundCursorColor: c.surface2, selectionColor: c.hairline,
              onChanged: (v) => ref.read(activityFilterProvider.notifier).state = f.copyWith(query: v),
            ),
          ])),
        ]),
      ),
      const SizedBox(height: 12),
      SizedBox(
        height: 36,
        child: ListView(scrollDirection: Axis.horizontal, clipBehavior: Clip.none, children: [
          TickChip('All', on: !f.any, onTap: () { _ctl.clear(); ref.read(activityFilterProvider.notifier).state = const ActivityFilter(); }),
          const SizedBox(width: 8),
          TickChip('Business', on: f.business, onTap: () => ref.read(activityFilterProvider.notifier).state = f.copyWith(business: !f.business)),
          const SizedBox(width: 8),
          TickChip('Needs review', on: f.review, onTap: () => ref.read(activityFilterProvider.notifier).state = f.copyWith(review: !f.review)),
          for (final cat in l.categories.where((c) => c.kind == 'spend').take(6)) ...[
            const SizedBox(width: 8),
            TickChip(cat.name, on: f.categoryId == cat.id, onTap: () => ref.read(activityFilterProvider.notifier).state = f.categoryId == cat.id ? f.copyWith(clearCat: true) : f.copyWith(categoryId: cat.id)),
          ],
          for (final a in l.accounts.where((a) => a.type != 'savings')) ...[
            const SizedBox(width: 8),
            TickChip(a.name, on: f.accountId == a.id, onTap: () => ref.read(activityFilterProvider.notifier).state = f.accountId == a.id ? f.copyWith(clearAcct: true) : f.copyWith(accountId: a.id)),
          ],
        ]),
      ),
      Expanded(
        child: l.loading
            ? const ListSkeleton(rows: 7)
            : list.isEmpty
                ? EmptyState(f.any ? 'No matches' : 'Nothing here yet', f.any ? 'Try a different search or clear the filters.' : 'Add your first one in three taps.', icon: 'search')
                : ListView(padding: const EdgeInsets.only(bottom: 130), children: [
                    for (final d in days) ...[
                      SectionLabel(dayLabel(d, now), trailing: Text(formatCents(groups[d]!.fold(0, (s, t) => s + t.amountCents), sign: true), style: context.ts(TickType.monoS, color: c.textSecondary))),
                      for (final t in groups[d]!)
                        _SwipeRow(t: t, ledger: l, child: TxRow(t: t, ledger: l, onTap: () => context.push('/txn/${t.id}'))),
                    ],
                  ]),
      ),
    ]);
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
