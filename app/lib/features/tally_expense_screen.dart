import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../data/tally_store.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../design/widgets/more.dart';
import '../design/widgets/motion.dart';
import '../design/widgets/scaffold.dart';
import '../domain/money.dart';
import '../services/api.dart';
import 'common.dart';
import 'tally_expense_sheet.dart';
import 'tally_manage.dart';

/// One expense: who paid, who owes what, and the receipt if there is one.
class TallyExpenseScreen extends ConsumerStatefulWidget {
  const TallyExpenseScreen({super.key, required this.groupId, required this.id});
  final String groupId;
  final String id;
  @override
  ConsumerState<TallyExpenseScreen> createState() => _State();
}

class _State extends ConsumerState<TallyExpenseScreen> {
  String? _error;

  Future<void> _receipt() async {
    setState(() => _error = null);
    try {
      final j = await ref.read(apiProvider).get('/tally/expenses/${widget.id}/receipt');
      await launchUrl(Uri.parse(j['url'] as String), mode: LaunchMode.inAppBrowserView);
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e, action: 'open the receipt'));
    }
  }

  Widget _kv(String k, String v) => SizedBox(height: 48, child: Row(children: [
        Text(k, style: context.ts(TickType.body, color: context.c.textSecondary)),
        const SizedBox(width: 12),
        Expanded(child: Text(v, textAlign: TextAlign.right, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.ts(TickType.body))),
      ]));

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(tallyProvider);
    final c = context.c;
    final e = t.expenses.where((x) => x.id == widget.id).firstOrNull;
    final g = t.groups.where((x) => x.id == widget.groupId).firstOrNull;
    if (e == null || g == null) return TickPage(title: 'Expense', onBack: () => context.pop(), children: const [EmptyState('Not found', 'This expense is gone.', icon: 'tally')]);
    final canEdit = t.canEdit(g, e.createdBy);
    return TickPage(title: '', onBack: () => context.pop(), bottomPad: 40, children: [
      Row(children: [
        TickHero(tag: 'expense-${e.id}', child: Avatar(e.description, 'shop', size: 56)),
        const SizedBox(width: 16),
        Expanded(child: Text(e.description, style: context.ts(TickType.displayM))),
      ]),
      const SizedBox(height: 16),
      FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(formatCents(e.amountCents), style: context.ts(TickType.hero, size: 48))),
      Text('${t.nameOf(e.paidBy)} paid on ${DateFormat('MMM d').format(e.spentOn)}', style: context.ts(TickType.body, color: c.textSecondary)),
      const SectionLabel('Split'),
      TickCard(padding: const EdgeInsets.symmetric(horizontal: 16), child: Column(children: [
        for (final (i, s) in e.shares.entries.indexed) ...[
          if (i > 0) const Hairline(),
          Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Row(children: [
            Expanded(child: Text(t.nameOf(s.key), maxLines: 1, overflow: TextOverflow.ellipsis, style: context.ts(TickType.body))),
            Text(formatCents(s.value), style: context.ts(TickType.mono)),
          ])),
        ],
      ])),
      if (e.category != null || e.note != null) ...[
        const SizedBox(height: 12),
        TickCard(padding: const EdgeInsets.symmetric(horizontal: 16), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (e.category != null) _kv('Category', e.category!),
          if (e.category != null && e.note != null) const Hairline(),
          if (e.note != null) Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(e.note!, style: context.ts(TickType.body))),
        ])),
      ],
      if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: context.ts(TickType.bodyS, color: c.alert))),
      const SizedBox(height: 16),
      if (e.receiptPath != null) ...[PillButton('See receipt', icon: 'receipt', style: PillStyle.quiet, onTap: _receipt), const SizedBox(height: 8)],
      if (canEdit) ...[
        PillButton('Edit', onTap: () => showExpenseSheet(context, group: g, edit: e)),
        const SizedBox(height: 8),
        PillButton('Delete', style: PillStyle.quiet, onTap: () async {
          final router = GoRouter.of(context);
          await deleteExpenseWithUndo(context, ref, e);
          router.pop();
        }),
      ],
    ]);
  }
}
