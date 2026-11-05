import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../data/ledger.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../design/widgets/more.dart';
import '../domain/money.dart';
import 'activity_screen.dart';
import 'common.dart';

class TxnDetailScreen extends ConsumerWidget {
  const TxnDetailScreen({super.key, required this.id});
  final String id;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = ref.watch(ledgerProvider);
    final t = l.txns.where((x) => x.id == id).firstOrNull;
    final c = context.c;
    if (t == null) {
      return TickScreen(child: Column(children: [ScreenTitle('Purchase', onBack: () => context.pop()), if (l.loading) const ListSkeleton(rows: 3) else const EmptyState('Not found', 'This one moved or was deleted.')]));
    }
    final cat = l.category(t.categoryId);
    final acct = l.account(t.accountId);
    return TickScreen(
      child: ListView(children: [
        ScreenTitle('', onBack: () => context.pop()),
        Row(children: [
          Hero(tag: 'av-${t.id}', child: Avatar(t.merchant, t.isIncome ? 'inc' : (cat?.colorKey ?? 'shop'), size: 56)),
          const SizedBox(width: 16),
          Expanded(child: Text(t.merchant, style: context.ts(TickType.displayM))),
        ]),
        const SizedBox(height: 24),
        Center(child: Sticker(hole: true, padding: const EdgeInsets.fromLTRB(48, 14, 40, 14), child: Text(formatCents(t.amountCents, sign: true), style: context.ts(TickType.hero, color: c.onAccent, size: 52)))),
        const SizedBox(height: 24),
        TickCard(padding: const EdgeInsets.symmetric(horizontal: 16), child: Column(children: [
          _kv(context, 'When', DateFormat('EEE MMM d, h:mm a').format(t.occurredAt)),
          const Hairline(),
          _kv(context, 'Category', cat?.name ?? 'Other', onTap: () => showCategorySheet(context, ref, t)),
          const Hairline(),
          _kv(context, 'Account', acct?.label ?? 'Not set'),
          const Hairline(),
          _kv(context, 'Captured by', sourceLabel(t.source)),
          if (t.confidence < 1) ...[const Hairline(), _kv(context, 'Match', '${(t.confidence * 100).round()}% sure')],
        ])),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: PillButton(t.isBusiness ? 'Business ✓' : 'Mark Business', style: t.isBusiness ? PillStyle.primary : PillStyle.quiet, icon: 'briefcase', onTap: () => ref.read(ledgerProvider.notifier).toggleBusiness(t.id))),
        ]),
        if (t.needsReview) ...[
          const SizedBox(height: 8),
          PillButton('Looks right', style: PillStyle.inverse, icon: 'check', onTap: () => ref.read(ledgerProvider.notifier).markLooksRight(t.id)),
        ],
      ]),
    );
  }

  Widget _kv(BuildContext context, String k, String v, {VoidCallback? onTap}) => Pressable(
        onTap: onTap, scale: 1,
        child: SizedBox(height: 52, child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(k, style: context.ts(TickType.body, color: context.c.textSecondary)),
          Text(v + (onTap != null ? '  ›' : ''), style: context.ts(TickType.title, size: 16)),
        ])),
      );
}
