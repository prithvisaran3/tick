import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../domain/money.dart';
import 'ledger.dart';
import 'remote.dart';
import 'settings.dart';

class PayLine {
  const PayLine(this.kind, this.label, this.cents, this.ytdCents);
  final String kind; // earning | tax | deduction
  final String label;
  final int cents;
  final int? ytdCents;
}

class PayStatement {
  const PayStatement({required this.id, required this.employer, required this.payDate, required this.grossCents, required this.taxesCents, required this.deductionsCents,
      required this.netCents, this.lines = const [], this.ytd = const {}, this.review = false, this.matchedTxn});
  final String id;
  final String employer;
  final DateTime payDate;
  final int grossCents, taxesCents, deductionsCents, netCents;
  final List<PayLine> lines;
  final Map<String, dynamic> ytd;
  final bool review;
  final String? matchedTxn;
  int get retirementCents => lines.where((l) => l.kind == 'deduction' && RegExp(r'401|403|retire', caseSensitive: false).hasMatch(l.label)).fold(0, (s, l) => s + l.cents);
}

/// Owner-only by RLS. Newest first.
final payStatementsProvider = FutureProvider<List<PayStatement>>((ref) async {
  ref.watch(ledgerRevisionProvider);
  final r = ref.watch(remoteProvider);
  if (r == null || ref.watch(settingsProvider.select((s) => s.demoMode))) return const [];
  final rows = await r.db.from('pay_statements').select().order('pay_date', ascending: false).limit(60);
  if (rows.isEmpty) return const [];
  final lines = await r.db.from('pay_statement_lines').select('statement_id,kind,label,cents,ytd_cents,sort').order('sort');
  return [for (final j in rows) PayStatement(id: j['id'] as String, employer: j['employer'] as String, payDate: DateTime.parse(j['pay_date'] as String),
      grossCents: (j['gross_cents'] as num).toInt(), taxesCents: (j['taxes_cents'] as num).toInt(), deductionsCents: (j['deductions_cents'] as num).toInt(), netCents: (j['net_cents'] as num).toInt(),
      ytd: ((j['ytd'] as Map?) ?? const {}).cast<String, dynamic>(), review: j['status'] == 'review', matchedTxn: j['matched_txn'] as String?,
      lines: [for (final l in lines) if (l['statement_id'] == j['id']) PayLine(l['kind'] as String, l['label'] as String, (l['cents'] as num).toInt(), (l['ytd_cents'] as num?)?.toInt())])];
});

/// "Latest: Nov 13 · $2,477.07 net" for Profile > Pay.
String payStatementSummary(List<PayStatement> s) => s.isEmpty ? 'None yet' : 'Latest: ${DateFormat('MMM d').format(s.first.payDate)} · ${formatCents(s.first.netCents)} net';

/// This year's totals for the Insights card.
({int gross, int taxes, int retirement, int net, int count}) payThisYear(List<PayStatement> s, int year) {
  final y = s.where((p) => p.payDate.year == year).toList();
  return (gross: y.fold(0, (a, p) => a + p.grossCents), taxes: y.fold(0, (a, p) => a + p.taxesCents), retirement: y.fold(0, (a, p) => a + p.retirementCents), net: y.fold(0, (a, p) => a + p.netCents), count: y.length);
}
