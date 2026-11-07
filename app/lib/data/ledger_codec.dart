import '../domain/models.dart';
import 'ledger.dart';

/// JSON codec for the offline snapshot. Pure Dart so it can run in a background isolate via `compute`.
const _maxCachedTxns = 1200;

Map<String, dynamic> encodeLedger(LedgerState l, {String? userId}) {
  final txns = l.txns.length > _maxCachedTxns ? l.txns.sublist(0, _maxCachedTxns) : l.txns;
  return {
    'v': 1,
    'userId': userId,
    'savedAt': DateTime.now().toUtc().toIso8601String(),
    'linksUsed': l.linksUsed,
    'categories': [for (final c in l.categories) {'id': c.id, 'name': c.name, 'color_key': c.colorKey, 'icon': c.icon, 'kind': c.kind}],
    'accounts': [for (final a in l.accounts) a.toJson()],
    'txns': [for (final t in txns) encodeTxn(t)],
    'recurring': [for (final r in l.recurring) {'id': r.id, 'm': r.merchant, 'cad': r.cadence.name, 'e': r.expectedCents, 'next': r.nextDate.toIso8601String(), 'c': r.categoryId, 'h': r.priceHistory}],
    'expected': [for (final e in l.expected) {'id': e.id, 'k': e.kind.name, 'l': e.label, 'a': e.amountCents, 'd': e.date.toIso8601String()}],
    'goals': [for (final g in l.goals) {'id': g.id, 'n': g.name, 't': g.targetCents, 's': g.savedCents, 'p': g.perPaydayCents}],
    'budgets': [for (final b in l.budgets) {'id': b.id, 'c': b.categoryId, 'cap': b.capCents}],
    'connections': [for (final c in l.connections) c.toJson()],
    'rules': [for (final r in l.rules) {'id': r.id, 'p': r.pattern, 'c': r.categoryId}],
  };
}

/// Returns null for anything unreadable: a corrupt or older cache must never crash launch.
LedgerState? decodeLedger(Map<String, dynamic> j) {
  try {
    if (j['v'] != 1) return null;
    List<Map<String, dynamic>> list(String k) => ((j[k] as List?) ?? const []).cast<Map<String, dynamic>>();
    return LedgerState(
      categories: [for (final c in list('categories')) Category.fromJson(c)],
      accounts: [for (final a in list('accounts')) Account.fromJson(a)],
      txns: [for (final t in list('txns')) decodeTxn(t)],
      recurring: [
        for (final r in list('recurring'))
          Recurring(
            id: r['id'] as String, merchant: r['m'] as String, cadence: Cadence.values.firstWhere((c) => c.name == r['cad'], orElse: () => Cadence.monthly),
            expectedCents: (r['e'] as num).toInt(), nextDate: DateTime.parse(r['next'] as String), categoryId: r['c'] as String?,
            priceHistory: ((r['h'] as List?) ?? const []).map((e) => (e as num).toInt()).toList(),
          ),
      ],
      expected: [for (final e in list('expected')) Expected(id: e['id'] as String, kind: ExpectedKind.values.firstWhere((k) => k.name == e['k'], orElse: () => ExpectedKind.refund), label: e['l'] as String, amountCents: (e['a'] as num).toInt(), date: DateTime.parse(e['d'] as String))],
      goals: [for (final g in list('goals')) Goal(id: g['id'] as String, name: g['n'] as String, targetCents: (g['t'] as num).toInt(), savedCents: (g['s'] as num).toInt(), perPaydayCents: (g['p'] as num).toInt())],
      budgets: [for (final b in list('budgets')) Budget(id: b['id'] as String, categoryId: b['c'] as String, capCents: (b['cap'] as num).toInt())],
      connections: [for (final c in list('connections')) Connection.fromCache(c)],
      rules: [for (final r in list('rules')) LearnedRule(id: r['id'] as String, pattern: r['p'] as String, categoryId: r['c'] as String)],
      linksUsed: (j['linksUsed'] as num?)?.toInt() ?? 0,
    );
  } catch (_) {
    return null;
  }
}

Map<String, dynamic> encodeTxn(Txn t) => {
      'id': t.id, 'a': t.amountCents, 'at': t.occurredAt.toUtc().toIso8601String(), 'm': t.merchant, 'c': t.categoryId, 'acc': t.accountId,
      'p': t.status == TxStatus.pending, 'cf': t.confidence, 'r': t.needsReview, 'tg': t.tags, 'n': t.note, 's': t.source, 'l4': t.cardLast4, 'f': t.flow, 'rb': t.reimbursedCents, 'sh': t.sharedCents,
    };

Txn decodeTxn(Map<String, dynamic> t) => Txn(
      id: t['id'] as String, amountCents: (t['a'] as num).toInt(), occurredAt: DateTime.parse(t['at'] as String).toLocal(), merchant: t['m'] as String,
      categoryId: t['c'] as String?, accountId: t['acc'] as String?, status: t['p'] == true ? TxStatus.pending : TxStatus.posted,
      confidence: (t['cf'] as num?)?.toDouble() ?? 1.0, needsReview: t['r'] == true, tags: ((t['tg'] as List?) ?? const []).cast<String>(), note: t['n'] as String?,
      source: (t['s'] ?? 'manual') as String, cardLast4: t['l4'] as String?, flow: t['f'] as String?,
    );
