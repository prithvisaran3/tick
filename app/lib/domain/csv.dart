import '../data/ledger.dart';

/// Quotes a CSV cell and neutralises spreadsheet formulas: a merchant named "=HYPERLINK(...)" must not run when the file is opened.
String csvCell(String s) {
  final safe = RegExp(r'^[=+\-@\t\r]').hasMatch(s) ? "'$s" : s;
  return '"${safe.replaceAll('"', '""')}"';
}

String buildCsv(LedgerState l) {
  final b = StringBuffer('date,merchant,amount,category,account,business,note\n');
  for (final t in l.txns) {
    b.writeln([
      t.occurredAt.toIso8601String(), csvCell(t.merchant), (t.amountCents / 100).toStringAsFixed(2), csvCell(l.category(t.categoryId)?.name ?? ''),
      csvCell(l.account(t.accountId)?.label ?? ''), t.isBusiness, csvCell(t.note ?? ''),
    ].join(','));
  }
  return b.toString();
}
