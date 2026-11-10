import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../data/ledger.dart';
import '../data/paybacks.dart';
import '../data/review_snooze.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../design/widgets/more.dart';
import '../domain/money.dart';
import '../services/api.dart';
import '../services/haptics.dart';
import 'common.dart';
import 'rule_cards.dart';
import 'tally_manage.dart' show showUndo;

/// One more answer than Yes and No, like "Other bill".
class ReviewAnswer {
  const ReviewAnswer(this.label, this.effect, this.run);
  final String label;
  final String effect;
  final Future<void> Function(WidgetRef ref) run;
}

/// Every Yes/No question Tick asks, in one shape: what it asks, why, which rows, what each answer does, and how sure Tick is.
class ReviewQ {
  const ReviewQ({required this.key, required this.kind, required this.question, required this.line, required this.reason, required this.txnIds,
      required this.confidence, required this.yes, required this.no, this.extra = const [], this.stillUnsure = false});
  final String key;
  final String kind;
  final String question;
  final String line;
  final String reason;
  final List<String> txnIds;
  final double confidence;
  final ReviewAnswer yes;
  final ReviewAnswer no;
  final List<ReviewAnswer> extra;
  final bool stillUnsure;

  ReviewQ unsure() => ReviewQ(key: key, kind: kind, question: question, line: line, reason: reason, txnIds: txnIds, confidence: confidence, yes: yes, no: no, extra: extra, stillUnsure: true);
}

String confidenceWords(double c) => c >= 0.85 ? 'Very likely' : c >= 0.65 ? 'Likely' : 'Maybe';

String _d(DateTime d) => DateFormat('MMM d').format(d);
String _first(String name) => name.split(' ').first;

/// Built from the question sources; most sure first. Snoozed ones are left out, and come back once as "Still unsure?".
final reviewQuestionsProvider = Provider<List<ReviewQ>>((ref) {
  final paybacks = ref.watch(paybackSuggestionsProvider).value ?? const <PaybackSuggestion>[];
  final landed = ref.watch(landedSettlementsProvider).value ?? const <LandedSettlement>[];
  final balances = ref.watch(balanceMatchesProvider).value ?? const <BalanceMatch>[];
  final rules = ref.watch(ruleSuggestionsProvider).value ?? const <RuleSuggestion>[];
  final likely = ref.watch(likelySplitwiseProvider).value ?? const <LikelySplitwise>[];
  final snoozes = ref.watch(reviewSnoozesProvider);
  final now = ref.watch(clockProvider)();
  final all = <ReviewQ>[
    for (final s in landed) ReviewQ(
      key: 'land:${s.settlementId}', kind: 'Settle up', question: '${formatCents(s.amountCents)} from ${_first(s.from)} landed. Mark it received?',
      line: 'They marked it paid in Tally.', reason: '${s.from} said in Tally they paid ${formatCents(s.amountCents)}, and a payment of exactly that from them arrived.',
      txnIds: [s.paybackId], confidence: 0.92,
      yes: ReviewAnswer('Mark received', 'Their payment is recorded in Tally as received, and this deposit is matched to it.', (r) => r.read(paybackActionsProvider).received(s)),
      no: ReviewAnswer('Not this', 'Their payment stays pending in Tally, and Tick won\'t ask about this deposit again.', (r) => r.read(paybackActionsProvider).dismiss(s.paybackId)),
    ),
    for (final b in balances) ReviewQ(
      key: 'bal:${b.paybackId}', kind: 'Settle up', question: 'Mark ${b.first} as ${b.leftCents > 0 ? 'paid' : 'settled'}?',
      line: '${formatCents(b.amountCents)} from ${b.first} on ${_d(b.date)}, for ${b.groupName}.',
      reason: '${b.first} owed you ${formatCents(b.amountCents + b.leftCents)} in ${b.groupName}, and this payment is from them.',
      txnIds: [b.paybackId], confidence: b.leftCents == 0 ? 0.88 : 0.7,
      yes: ReviewAnswer(b.leftCents > 0 ? 'Mark paid' : 'Mark settled',
          b.leftCents > 0 ? 'Records ${formatCents(b.amountCents)} in ${b.groupName}; ${formatCents(b.leftCents)} is still left.' : 'Records it in ${b.groupName}, and you two are settled.',
          (r) => r.read(paybackActionsProvider).settleBalance(b)),
      no: ReviewAnswer('Not this', 'Tally stays as it is, and Tick won\'t ask about this payment again.', (r) => r.read(paybackActionsProvider).dismiss(b.paybackId)),
    ),
    for (final s in paybacks)
      if (s.candidates.isNotEmpty) _payback(s),
    for (final s in likely) ReviewQ(
      key: 'sw:${s.txnId}', kind: 'Splitwise', question: 'Is ${s.label} Splitwise?', line: formatCents(s.cents),
      reason: s.reason == 'paid_back' ? 'It looks shared, and a friend paid part of it back later.' : 'It\'s money with someone in your Tally groups.',
      txnIds: [s.txnId], confidence: s.confidence,
      yes: ReviewAnswer('Yes', 'It moves to Splitwise and counts as money with friends, not spending. Other payments with this person outside a rent rule follow.', (r) => _splitwise(r, s.txnId, true)),
      no: ReviewAnswer('No', 'It stays where it is, and Tick won\'t ask about this one again.', (r) => _splitwise(r, s.txnId, false)),
    ),
    for (final s in rules) ReviewQ(
      key: 'rule:${s.person}:${s.amountCents}', kind: 'Rent', question: 'Rent to ${_first(s.name)}, ${formatDollars(s.amountCents)} monthly?',
      line: 'Around the ${_ordinal(s.day)} each month.', reason: '${s.name} got about ${formatDollars(s.amountCents)} near the ${_ordinal(s.day)} for several months.',
      txnIds: const [], confidence: 0.75,
      yes: ReviewAnswer('Yes, rent', 'Payments to ${_first(s.name)} near that amount and day become Rent, now and later.', (r) => _rule(r, s, 'rent')),
      no: ReviewAnswer('Not recurring', 'They stay as they are, and Tick won\'t suggest this again.', (r) => _rule(r, s, 'no')),
      extra: [ReviewAnswer('Other bill', 'They become a bill instead of rent, now and later.', (r) => _rule(r, s, 'bill'))],
    ),
  ];
  final out = <ReviewQ>[];
  for (final q in all) {
    switch (snoozeState(snoozes[q.key], now)) {
      case SnoozeState.fresh: out.add(q);
      case SnoozeState.stillUnsure: out.add(q.unsure());
      case SnoozeState.hidden: break;
    }
  }
  final order = {for (var i = 0; i < out.length; i++) out[i].key: i};
  out.sort((a, b) => (b.confidence * 100).round().compareTo((a.confidence * 100).round()) != 0 ? (b.confidence * 100).round().compareTo((a.confidence * 100).round()) : order[a.key]!.compareTo(order[b.key]!));
  return out;
});

ReviewQ _payback(PaybackSuggestion s) {
  final c = s.candidates.first;
  final who = s.from == null ? '' : ' from ${_first(s.from!)}';
  final days = s.date.difference(c.date).inDays;
  return ReviewQ(
    key: 'pb:${s.paybackId}', kind: 'Payback', question: 'Payback for ${c.merchant}?',
    line: '${formatCents(s.amountCents)}$who on ${_d(s.date)}. ${c.merchant} was ${formatCents(c.amountCents)}.',
    reason: '${formatCents(s.amountCents)}$who came ${days <= 0 ? 'the same day as' : '$days ${days == 1 ? 'day' : 'days'} after'} ${c.merchant}, and it fits a split of it.'
        '${s.candidates.length > 1 ? ' ${s.candidates.length - 1} other purchase${s.candidates.length > 2 ? 's' : ''} could fit too.' : ''}',
    txnIds: [s.paybackId, c.purchaseId], confidence: s.candidates.length == 1 ? 0.75 : 0.55,
    yes: ReviewAnswer('Link it', '${c.merchant} counts as ${formatCents((c.amountCents - s.amountCents).clamp(0, c.amountCents))} of your spending, and the ${formatCents(s.amountCents)} isn\'t income.',
        (r) => r.read(paybackActionsProvider).link(c.purchaseId, s.paybackId)),
    no: ReviewAnswer('Not a payback', 'Both stay as they are, and Tick won\'t ask about this ${formatCents(s.amountCents)} again.', (r) => r.read(paybackActionsProvider).dismiss(s.paybackId)),
  );
}

String _ordinal(int d) => '$d${d % 100 >= 11 && d % 100 <= 13 ? 'th' : const {1: 'st', 2: 'nd', 3: 'rd'}[d % 10] ?? 'th'}';

Future<void> _splitwise(WidgetRef ref, String txnId, bool yes) async {
  await ref.read(apiProvider).post('/splitwise/answer', {'txn_id': txnId, 'yes': yes});
  await ref.read(ledgerProvider.notifier).refresh();
  ref.invalidate(likelySplitwiseProvider);
}

Future<void> _rule(WidgetRef ref, RuleSuggestion s, String kind) async {
  await ref.read(apiProvider).post('/rules/accept', {'person': s.person, 'amount_cents': s.amountCents, 'day': s.day, 'kind': kind});
  await ref.read(ledgerProvider.notifier).refresh();
  ref.invalidate(ruleSuggestionsProvider);
}

/// "Not sure": hidden for a week, back once. Nothing is sent, so nothing is learned.
void notSure(BuildContext context, WidgetRef ref, ReviewQ q) {
  final overlay = Overlay.of(context, rootOverlay: true);   // before the card disappears
  final before = ref.read(reviewSnoozesProvider)[q.key];
  ref.read(reviewSnoozesProvider.notifier).notSure(q.key);
  TickHaptics.instance.selection();
  showUndo(overlay, q.stillUnsure ? 'Tick won\'t ask again' : 'Tick will ask again in $snoozeDays days',
      () async => ref.read(reviewSnoozesProvider.notifier).restore(q.key, before));
}

/// A question card. Tapping it (not a button) opens the detail sheet.
class ReviewCard extends ConsumerStatefulWidget {
  const ReviewCard({super.key, required this.q, this.onDone});
  final ReviewQ q;
  final VoidCallback? onDone;
  @override
  ConsumerState<ReviewCard> createState() => _ReviewCardState();
}

class _ReviewCardState extends ConsumerState<ReviewCard> {
  bool _busy = false;
  String? _error;

  Future<void> _answer(ReviewAnswer a) async {
    setState(() { _busy = true; _error = null; });
    try {
      await a.run(ref);
      TickHaptics.instance.confirm();
      widget.onDone?.call();
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e, action: 'save that'));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final q = widget.q;
    return Pressable(
      onTap: _busy ? null : () => showReviewSheet(context, ref, q),
      scale: 0.99,
      child: TickCard(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (q.stillUnsure) Padding(padding: const EdgeInsets.only(bottom: 4), child: Text('Still unsure?', style: context.ts(TickType.bodyS, color: c.textSecondary))),
        Text(q.question, style: context.ts(TickType.title, size: 15.5)),
        const SizedBox(height: 2),
        Text(q.line, style: context.ts(TickType.bodyS, color: c.textSecondary)),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: PillButton(q.yes.label, height: 44, busy: _busy, onTap: () => _answer(q.yes))),
          const SizedBox(width: 8),
          Expanded(child: PillButton(q.no.label, height: 44, style: PillStyle.quiet, onTap: _busy ? null : () => _answer(q.no))),
        ]),
        Center(child: Pressable(
          onTap: _busy ? null : () => notSure(context, ref, q),
          child: Padding(padding: const EdgeInsets.only(top: 10, bottom: 2, left: 16, right: 16), child: Text('Not sure', style: context.ts(TickType.bodyS, color: c.textSecondary))),
        )),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(_error!, style: context.ts(TickType.bodyS, color: c.alert))),
      ])),
    );
  }
}

/// The transactions, why Tick asks, what each answer does, and how sure it is.
Future<void> showReviewSheet(BuildContext context, WidgetRef ref, ReviewQ q) => showTickSheet<void>(context, builder: (ctx) => _ReviewSheet(q: q));

class _ReviewSheet extends ConsumerStatefulWidget {
  const _ReviewSheet({required this.q});
  final ReviewQ q;
  @override
  ConsumerState<_ReviewSheet> createState() => _ReviewSheetState();
}

class _ReviewSheetState extends ConsumerState<_ReviewSheet> {
  bool _busy = false;
  String? _error;

  Future<void> _answer(ReviewAnswer a) async {
    setState(() { _busy = true; _error = null; });
    try {
      await a.run(ref);
      TickHaptics.instance.confirm();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() { _busy = false; _error = describeError(e, action: 'save that'); });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final q = widget.q;
    final l = ref.watch(ledgerProvider);
    final rows = [for (final id in q.txnIds) ?l.txns.where((t) => t.id == id).firstOrNull];
    Widget effect(String when, String what) => Padding(padding: const EdgeInsets.only(top: 10), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(when, style: context.ts(TickType.bodyS, color: c.textSecondary)),
          const SizedBox(height: 2),
          Text(what, style: context.ts(TickType.body)),
        ]));
    return SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: Text(q.question, style: context.ts(TickType.title))),
        const SizedBox(width: 8),
        TickChip(confidenceWords(q.confidence), on: q.confidence >= 0.85),
      ]),
      const SizedBox(height: 8),
      Text(q.reason, style: context.ts(TickType.body, color: c.textSecondary)),
      if (rows.isNotEmpty) ...[
        const SizedBox(height: 12),
        for (final t in rows) Pressable(
          onTap: () { Navigator.of(context).pop(); context.push('/txn/${t.id}'); },
          scale: 0.99,
          child: Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Row(children: [
            Expanded(child: Text('${t.merchant} · ${_d(t.occurredAt)}', maxLines: 2, overflow: TextOverflow.ellipsis, style: context.ts(TickType.body))),
            const SizedBox(width: 8),
            Text(formatCents(t.amountCents, sign: true), style: context.ts(TickType.mono)),
          ])),
        ),
      ],
      const SizedBox(height: 4),
      const Hairline(),
      effect('If you say ${q.yes.label}', q.yes.effect),
      for (final x in q.extra) effect('If you say ${x.label}', x.effect),
      effect('If you say ${q.no.label}', q.no.effect),
      effect('If you\'re not sure', q.stillUnsure ? 'Tick stops asking. Nothing is learned either way.' : 'Tick asks again in $snoozeDays days, once. Nothing is learned.'),
      const SizedBox(height: 16),
      PillButton(q.yes.label, busy: _busy, onTap: () => _answer(q.yes)),
      for (final x in q.extra) ...[const SizedBox(height: 8), PillButton(x.label, style: PillStyle.quiet, onTap: _busy ? null : () => _answer(x))],
      const SizedBox(height: 8),
      PillButton(q.no.label, style: PillStyle.quiet, onTap: _busy ? null : () => _answer(q.no)),
      Center(child: Pressable(
        onTap: _busy ? null : () { notSure(context, ref, q); Navigator.of(context).pop(); },
        child: Padding(padding: const EdgeInsets.all(12), child: Text('Not sure', style: context.ts(TickType.body, color: c.textSecondary))),
      )),
      if (_error != null) Text(_error!, textAlign: TextAlign.center, style: context.ts(TickType.bodyS, color: c.alert)),
    ]));
  }
}

/// Top of Activity: one question, and how many are behind it.
class ReviewDeck extends ConsumerWidget {
  const ReviewDeck({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final qs = ref.watch(reviewQuestionsProvider);
    if (qs.isEmpty) return const SizedBox.shrink();
    return Padding(padding: const EdgeInsets.only(bottom: 8), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ReviewCard(key: ValueKey(qs.first.key), q: qs.first),
      if (qs.length > 1) Pressable(
        onTap: () => context.push('/review'),
        child: Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Text('${qs.length - 1} more to review  ›', style: context.ts(TickType.bodyS, color: context.c.textSecondary))),
      ),
    ]));
  }
}

/// Every open question, one per page. Answering moves to the next; swiping skips without answering.
class ReviewQueueScreen extends ConsumerStatefulWidget {
  const ReviewQueueScreen({super.key});
  @override
  ConsumerState<ReviewQueueScreen> createState() => _ReviewQueueScreenState();
}

class _ReviewQueueScreenState extends ConsumerState<ReviewQueueScreen> {
  final _pages = PageController(viewportFraction: 0.92);
  int _at = 0;
  @override
  void dispose() { _pages.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    final qs = ref.watch(reviewQuestionsProvider);
    final c = context.c;
    if (_at >= qs.length && qs.isNotEmpty) _at = qs.length - 1;
    return TickScreen(horizontal: 0, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: ScreenTitle('To review', onBack: () => context.pop())),
      if (qs.isEmpty)
        const EmptyState('All reviewed', 'New questions show up at the top of Activity.')
      else ...[
        Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 12), child: Text('${_at + 1} of ${qs.length}', style: context.ts(TickType.bodyS, color: c.textSecondary))),
        Expanded(child: PageView.builder(
          controller: _pages,
          itemCount: qs.length,
          onPageChanged: (i) { TickHaptics.instance.selection(); setState(() => _at = i); },
          itemBuilder: (ctx, i) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Align(alignment: Alignment.topCenter, child: SingleChildScrollView(child: ReviewCard(key: ValueKey(qs[i].key), q: qs[i]))),
          ),
        )),
      ],
    ]));
  }
}
