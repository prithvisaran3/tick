import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/api.dart';

class ImportAccount {
  const ImportAccount(this.id, this.label, this.type);
  final String id;
  final String label;
  final String type;
}

class SampleRow {
  const SampleRow(this.date, this.merchant, this.cents);
  final DateTime date;
  final String merchant;
  final int cents;
}

/// What the server says about a statement file before anything is saved.
class ImportPreview {
  const ImportPreview({required this.source, required this.label, this.accountId, this.accounts = const [], this.needsAccount = false, this.mappingColumns,
      this.mappingHeaderRow = 0, this.mappingSample = const [], this.fresh = 0, this.duplicates = 0, this.already = 0, this.unreadable = 0, this.sample = const [], this.from, this.to, this.empty = false,
      this.batchId, this.imported, this.paystub, this.members = const [], this.meGuess, this.groupName, this.balances = const {}});
  /// Splitwise export: the group's members, who Tick thinks is me, the suggested group name and each member's final net.
  final List<String> members;
  final String? meGuess;
  final String? groupName;
  final Map<String, int> balances;
  bool get isSplitwise => source == 'splitwise';
  /// A pay statement read from a PDF: {employer, pay_date, gross_cents, taxes_cents, deductions_cents, net_cents, adds_up}.
  final Map<String, dynamic>? paystub;
  bool get isPaystub => source == 'paystub';
  final String source;
  final String label;
  final String? accountId;
  final List<ImportAccount> accounts;
  final bool needsAccount;
  final List<String>? mappingColumns;
  final int mappingHeaderRow;
  final List<List<String>> mappingSample;
  final int fresh; // new rows
  final int duplicates; // skipped because Tick already has them
  final int already; // skipped because an earlier import added them
  final int unreadable;
  final List<SampleRow> sample;
  final DateTime? from;
  final DateTime? to;
  final bool empty;
  final String? batchId;
  final int? imported;

  bool get needsMapping => mappingColumns != null;
  int get skipped => duplicates + already;

  factory ImportPreview.fromJson(Map<String, dynamic> j) {
    final nm = j['needs_mapping'] as Map?;
    return ImportPreview(
      source: (j['source'] ?? 'generic') as String, label: (j['label'] ?? 'Statement') as String, accountId: j['account_id'] as String?,
      accounts: [for (final a in (j['accounts'] as List? ?? const [])) ImportAccount(a['id'] as String, a['label'] as String, a['type'] as String)],
      needsAccount: j['needs_account'] == true,
      mappingColumns: nm == null ? null : [for (final c in (nm['columns'] as List)) '$c'], mappingHeaderRow: (nm?['header_row'] as num?)?.toInt() ?? 0,
      mappingSample: nm == null ? const [] : [for (final r in (nm['sample'] as List)) [for (final c in (r as List)) '$c']],
      fresh: (j['new'] as num?)?.toInt() ?? 0, duplicates: (j['duplicates'] as num?)?.toInt() ?? (j['skipped_duplicates'] as num?)?.toInt() ?? 0,
      already: (j['already_imported'] as num?)?.toInt() ?? 0, unreadable: (j['unreadable'] as num?)?.toInt() ?? 0,
      sample: [for (final r in (j['sample'] as List? ?? const [])) SampleRow(DateTime.parse(r['date'] as String), r['merchant'] as String, (r['cents'] as num).toInt())],
      from: DateTime.tryParse('${j['date_from']}'), to: DateTime.tryParse('${j['date_to']}'), empty: j['empty'] == true,
      batchId: j['batch_id'] as String?, imported: (j['imported'] as num?)?.toInt(), paystub: j['source'] == 'paystub' ? j : null,
      members: [for (final m in (j['members'] as List? ?? const [])) '$m'], meGuess: j['me_guess'] as String?, groupName: j['group_name'] as String?,
      balances: {for (final e in ((j['balances'] as Map?) ?? const {}).entries) e.key as String: (e.value as num).toInt()});
  }
}

class StatementImportApi {
  StatementImportApi(this.api);
  final Api api;

  Future<ImportPreview> send(List<int> bytes, String name, {required bool commit, String? accountId, Map<String, dynamic>? mapping, String? meMember}) async =>
      ImportPreview.fromJson(await api.postFile('/import/statement', 'file', bytes, name, fields: {
        'mode': commit ? 'commit' : 'preview', 'account_id': ?accountId, 'me_member': ?meMember, if (mapping != null) 'mapping': _json(mapping),
      }));

  Future<int> undo(String batchId) async => ((await api.post('/import/$batchId/undo'))['removed'] as num?)?.toInt() ?? 0;
}

String _json(Map<String, dynamic> m) => '{${m.entries.map((e) => '"${e.key}":${e.value is String ? '"${(e.value as String).replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"' : e.value}').join(',')}}';

final statementImportApiProvider = Provider<StatementImportApi>((ref) => StatementImportApi(ref.watch(apiProvider)));
