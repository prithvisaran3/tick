import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'ledger.dart';
import 'remote.dart';
import 'settings.dart';

class RuleRow {
  const RuleRow({required this.id, required this.person, required this.category, this.amountCents, this.day, this.ignored = false});
  final String id;
  final String person;
  final String category;
  final int? amountCents;
  final int? day;
  final bool ignored;
}

class AliasRow {
  const AliasRow(this.key, this.meaning);
  final String key;
  final String meaning;
}

/// My category rules (category_rules) with category names. Owner-only by RLS.
final categoryRulesProvider = FutureProvider<List<RuleRow>>((ref) async {
  ref.watch(ledgerRevisionProvider);
  final r = ref.watch(remoteProvider);
  if (r == null || ref.watch(settingsProvider.select((s) => s.demoMode))) return const [];
  final cats = {for (final c in ref.read(ledgerProvider).categories) c.id: c.name};
  final rows = await r.db.from('category_rules').select('id,person_key,display_name,category_id,amount_cents,day_of_month,ignored').order('created_at');
  return [for (final j in rows) RuleRow(id: j['id'] as String, person: (j['display_name'] ?? j['person_key']) as String, category: j['ignored'] == true ? 'Not recurring' : (cats[j['category_id']] ?? 'Category'),
      amountCents: (j['amount_cents'] as num?)?.toInt(), day: (j['day_of_month'] as num?)?.toInt(), ignored: j['ignored'] == true)];
});

/// What Ask Tick learned: aliases, and proposals waiting for my approval (Phase 10).
final askMemoryProvider = FutureProvider<({List<AliasRow> aliases, int proposals})>((ref) async {
  final r = ref.watch(remoteProvider);
  if (r == null || ref.watch(settingsProvider.select((s) => s.demoMode))) return (aliases: const <AliasRow>[], proposals: 0);
  final rows = await r.db.from('ask_memory').select('kind,key,value');
  String meaning(Object? v) {
    final m = (v as Map?) ?? const {};
    if (m['categories'] is List) return (m['categories'] as List).join(', ');
    return (m['person'] ?? '') as String;
  }
  return (aliases: [for (final j in rows) if (j['kind'] == 'alias') AliasRow(j['key'] as String, meaning(j['value']))], proposals: rows.where((j) => j['kind'] == 'proposal').length);
});
