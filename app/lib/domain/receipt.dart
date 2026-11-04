import 'models.dart';
import 'payday.dart';
import 'money.dart';

class ReceiptLine {
  const ReceiptLine(this.merchant, this.cents);
  final String merchant;
  final int cents; // positive magnitude
}

class ReceiptData {
  const ReceiptData({required this.day, required this.lines, required this.moreCount, required this.totalCents, required this.captures});
  final DateTime day;
  final List<ReceiptLine> lines;
  final int moreCount;
  final int totalCents;
  final int captures;
}

/// Yesterday's spending as receipt lines (largest first, max [maxLines], the rest folded into "and N more").
ReceiptData buildReceipt(List<Txn> txns, DateTime now, {int maxLines = 6}) {
  final y = dayOnly(now).subtract(const Duration(days: 1));
  final ys = txns.where((t) => t.amountCents < 0 && dayOnly(t.occurredAt) == y).toList()..sort((a, b) => a.amountCents.compareTo(b.amountCents));
  final total = ys.fold<int>(0, (s, t) => s - t.amountCents);
  final shown = ys.take(maxLines).map((t) => ReceiptLine(t.merchant, -t.amountCents)).toList();
  return ReceiptData(day: y, lines: shown, moreCount: ys.length - shown.length, totalCents: total, captures: ys.length);
}

/// Local fallback for the one-line advice (the server writes a nicer one with Gemini).
String fallbackAdvice(ReceiptData r, int safeCents, int daysToPayday) {
  if (r.captures == 0) return 'Quiet day. Your wallet says thanks.';
  if (safeCents < 0) return 'Bills and goals are ahead of your cash. Hold off on extras until payday.';
  final perDay = daysToPayday <= 0 ? safeCents : safeCents ~/ daysToPayday;
  if (r.totalCents > perDay * 1.5 && perDay > 0) return 'A bigger day than your pace. About ${formatDollars(perDay)} a day keeps you on track.';
  return 'You are on pace. About ${formatDollars(perDay)} a day keeps it that way.';
}
