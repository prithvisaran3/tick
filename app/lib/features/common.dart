import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';
import '../data/ledger.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import '../domain/payday.dart';

enum MoneyKind { out, income, expected, alert }

/// List amounts in plain Geist Mono: Volt for money in (Ink in light), default for out, Sky for expected, Clay only for alerts.
class Money extends StatelessWidget {
  const Money(this.cents, {super.key, this.kind, this.style, this.sign = true, this.whole = false});
  final int cents;
  final MoneyKind? kind;
  final TextStyle? style;
  final bool sign;
  final bool whole;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final k = kind ?? (cents > 0 ? MoneyKind.income : MoneyKind.out);
    final color = switch (k) { MoneyKind.income => c.moneyIn, MoneyKind.expected => c.incoming, MoneyKind.alert => c.alert, MoneyKind.out => c.moneyOut };
    final base = (style ?? context.ts(TickType.mono)).copyWith(color: color, fontWeight: k == MoneyKind.income && !context.isDark ? FontWeight.w700 : null);
    return Text(formatCents(cents, sign: sign, whole: whole), style: base);
  }
}

String dayLabel(DateTime d, DateTime now) {
  final t = dayOnly(now), x = dayOnly(d);
  final diff = t.difference(x).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  return DateFormat(diff < 7 ? 'EEEE' : 'EEE MMM d').format(x);
}

String weekdayName(DateTime d, DateTime now) {
  final diff = dayOnly(d).difference(dayOnly(now)).inDays;
  if (diff == 0) return 'today';
  if (diff == 1) return 'tomorrow';
  if (diff < 7) return DateFormat('EEEE').format(d);
  return DateFormat('EEE MMM d').format(d);
}

String sourceLabel(String s) => switch (s) { 'applepay' => 'Apple Pay', 'sms' => 'Text alert', 'plaid' => 'Bank', 'receipt' => 'Receipt', _ => 'Added by you' };

class TxRow extends StatelessWidget {
  const TxRow({super.key, required this.t, required this.ledger, this.onTap, this.sticker = false, this.showDate = false, this.subtitle});
  final Txn t;
  final LedgerState ledger;
  final VoidCallback? onTap;
  final bool sticker;
  final bool showDate;
  final String? subtitle;
  @override
  Widget build(BuildContext context) {
    final cat = ledger.category(t.categoryId);
    final acct = ledger.account(t.accountId);
    final sub = subtitle ?? [if (t.isBusiness) 'Business' else if (cat != null) cat.name, if (acct != null) acct.shortLabel else sourceLabel(t.source)].join(' · ');
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(children: [
        Hero(tag: 'av-${t.id}', child: Avatar(t.merchant, t.isIncome ? 'inc' : (cat?.colorKey ?? 'shop'))),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.merchant, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.ts(TickType.title, size: 16)),
            const SizedBox(height: 1),
            Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.ts(TickType.bodyS, color: context.c.textSecondary)),
          ]),
        ),
        const SizedBox(width: 8),
        if (sticker)
          Sticker(glow: false, tilt: 2, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5), child: Text(formatCents(t.amountCents, sign: true), style: context.ts(TickType.mono, color: context.c.onAccent).copyWith(fontWeight: FontWeight.w600)))
        else
          Money(t.amountCents),
      ]),
    );
    return Semantics(
      label: '${t.merchant}, ${formatCents(t.amountCents.abs())} ${t.isIncome ? 'in' : 'out'}, ${cat?.name ?? ''}', button: onTap != null,
      child: onTap == null ? row : Pressable(onTap: onTap, scale: 0.985, child: row),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState(this.title, this.body, {super.key, this.icon = 'check'});
  final String title;
  final String body;
  final String icon;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
        child: Column(children: [
          TickIcon(icon, size: 36, color: context.c.textSecondary),
          const SizedBox(height: 12),
          Text(title, textAlign: TextAlign.center, style: context.ts(TickType.title)),
          const SizedBox(height: 4),
          Text(body, textAlign: TextAlign.center, style: context.ts(TickType.body, color: context.c.textSecondary)),
        ]),
      );
}

/// Shown while data loads; never a spinner.
class ListSkeleton extends StatelessWidget {
  const ListSkeleton({super.key, this.rows = 5});
  final int rows;
  @override
  Widget build(BuildContext context) => Column(children: [
        for (var i = 0; i < rows; i++)
          const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Row(children: [
            Skeleton(width: 40, height: 40, radius: 20), SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Skeleton(width: 140, height: 14), SizedBox(height: 6), Skeleton(width: 90, height: 11)])),
            Skeleton(width: 56, height: 14),
          ])),
      ]);
}
