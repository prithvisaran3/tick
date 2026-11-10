import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/api.dart';
import 'ledger.dart';
import 'remote.dart';
import 'settings.dart';

/// One answer to "what was this Splitwise row?": a Splitwise email, a Tally expense, or an open Tally balance.
class SplitwiseGuess {
  const SplitwiseGuess({required this.source, required this.ref, required this.label, required this.where, required this.cents, required this.confidence, this.date});
  final String source;   // splitwise | tally | balance
  final String ref;
  final String label;
  final String where;
  final int cents;
  final double confidence;
  final DateTime? date;

  /// Words, not a percentage: how much to trust it.
  String get confidenceLabel => confidence >= 0.85 ? 'Very likely' : confidence >= 0.65 ? 'Likely' : 'Maybe';

  factory SplitwiseGuess.fromJson(Map<String, dynamic> j) => SplitwiseGuess(source: j['source'] as String, ref: j['ref'] as String, label: j['label'] as String,
      where: (j['where'] as String?) ?? '', cents: (j['cents'] as num).toInt(), confidence: (j['confidence'] as num).toDouble(),
      date: j['date'] == null ? null : DateTime.tryParse(j['date'] as String));
}

class SettleItem {
  const SettleItem(this.label, this.groupName, this.cents, this.date);
  final String label;
  final String groupName;
  final int cents;
  final DateTime? date;
}

/// A Zelle to a friend: the expenses my share of could be settling.
class CouldSettle {
  const CouldSettle({required this.person, required this.exact, required this.totalCents, required this.items});
  final String person;
  final bool exact;
  final int totalCents;
  final List<SettleItem> items;
}

class SplitwiseExplain {
  const SplitwiseExplain({this.best, this.more = 0, this.gmailConnected = false, this.tag, this.couldSettle});
  final SplitwiseGuess? best;
  final int more;
  final bool gmailConnected;
  final String? tag;
  final CouldSettle? couldSettle;

  factory SplitwiseExplain.fromJson(Map<String, dynamic> j) {
    final cs = j['could_settle'] as Map<String, dynamic>?;
    return SplitwiseExplain(
      best: j['best'] == null ? null : SplitwiseGuess.fromJson((j['best'] as Map).cast<String, dynamic>()),
      more: (j['more'] as num?)?.toInt() ?? 0,
      gmailConnected: j['gmail_connected'] == true,
      tag: j['tag'] as String?,
      couldSettle: cs == null ? null : CouldSettle(person: cs['person'] as String, exact: cs['exact'] == true, totalCents: (cs['total_cents'] as num).toInt(), items: [
        for (final i in (cs['items'] as List)) SettleItem(i['label'] as String, (i['group_name'] as String?) ?? '', (i['cents'] as num).toInt(), DateTime.tryParse('${i['date']}')),
      ]),
    );
  }
}

bool _offline(Ref ref) => ref.watch(settingsProvider.select((s) => s.demoMode)) || ref.watch(remoteProvider) == null;

/// Errors surface (the detail shows a reason and Retry); demo mode has nothing to explain.
final splitwiseExplainProvider = FutureProvider.family<SplitwiseExplain, String>((ref, txnId) async {
  ref.watch(ledgerRevisionProvider);
  if (_offline(ref)) return const SplitwiseExplain();
  return SplitwiseExplain.fromJson(await ref.read(apiProvider).get('/splitwise/explain/$txnId'));
}, retry: _noRetry);

/// The card has its own Try again; a silent retry loop would just keep the skeleton up.
Duration? _noRetry(int _, Object _) => null;

class SplitwiseOptions {
  const SplitwiseOptions(this.groups, this.friends);
  final List<({String id, String name})> groups;
  final List<String> friends;
  bool get isEmpty => groups.isEmpty && friends.isEmpty;
}

final splitwiseOptionsProvider = FutureProvider<SplitwiseOptions>((ref) async {
  if (_offline(ref)) return const SplitwiseOptions([], []);
  final j = await ref.read(apiProvider).get('/splitwise/options');
  return SplitwiseOptions([for (final g in (j['groups'] as List? ?? const [])) (id: g['id'] as String, name: g['name'] as String)], [for (final f in (j['friends'] as List? ?? const [])) f as String]);
}, retry: _noRetry);

class SplitwiseActions {
  SplitwiseActions(this.ref);
  final Ref ref;
  Future<void> tag(String txnId, {String? groupId, String? person}) async {
    await ref.read(apiProvider).post('/splitwise/tag', {'txn_id': txnId, 'group_id': groupId, 'person': person});
    ref.invalidate(splitwiseExplainProvider(txnId));
  }
  Future<void> notThis(String txnId, String guessRef) async {
    await ref.read(apiProvider).post('/splitwise/not', {'txn_id': txnId, 'ref': guessRef});
    ref.invalidate(splitwiseExplainProvider(txnId));
  }
}

final splitwiseActionsProvider = Provider<SplitwiseActions>(SplitwiseActions.new);
