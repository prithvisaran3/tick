import 'models.dart';
import 'safe_to_spend.dart';

enum SplitKind { percent, fixed, rest }

/// One destination for a paycheck. [value]: basis points for percent, cents for fixed, 0 for the rest.
class PaySplit {
  const PaySplit({this.accountId, this.label, this.mask, required this.kind, this.value = 0});
  final String? accountId;   // null: an account Tick doesn't see
  final String? label;
  final String? mask;
  final SplitKind kind;
  final int value;
  PaySplit copyWith({SplitKind? kind, int? value}) => PaySplit(accountId: accountId, label: label, mask: mask, kind: kind ?? this.kind, value: value ?? this.value);
  Map<String, dynamic> toJson() => {'account_id': accountId, 'label': label, 'mask': mask, 'kind': kind.name, 'value': kind == SplitKind.rest ? 0 : value};
  factory PaySplit.fromJson(Map<String, dynamic> j) => PaySplit(accountId: j['account_id'] as String?, label: j['label'] as String?, mask: j['mask'] as String?,
      kind: SplitKind.values.firstWhere((k) => k.name == j['kind'], orElse: () => SplitKind.rest), value: (j['value'] as num?)?.toInt() ?? 0);
}

/// The same arithmetic as SQL `pay_split_amounts` and Python `split_amounts` (vectors: api/tests/data/pay_splits.json).
/// Fixed lines first in order, then percents of the whole net, and the one "rest" line takes what is left.
List<int> splitAmounts(int net, List<PaySplit> splits) {
  final n = net < 0 ? 0 : net;
  var left = n;
  final out = List<int>.filled(splits.length, 0);
  for (var i = 0; i < splits.length; i++) {
    if (splits[i].kind == SplitKind.fixed) { out[i] = splits[i].value < left ? splits[i].value : left; left -= out[i]; }
  }
  for (var i = 0; i < splits.length; i++) {
    if (splits[i].kind == SplitKind.percent) { final c = n * splits[i].value ~/ 10000; out[i] = c < left ? c : left; left -= out[i]; }
  }
  for (var i = 0; i < splits.length; i++) {
    if (splits[i].kind == SplitKind.rest) { out[i] = left; left = 0; }
  }
  return out;
}

/// Why this set can't be saved, in words, or null when it can. Checked as you type.
String? splitProblem(int net, List<PaySplit> splits) {
  if (splits.isEmpty) return null;
  final rests = splits.where((s) => s.kind == SplitKind.rest).length;
  if (rests == 0) return 'One line needs to take the rest.';
  if (rests > 1) return 'Only one line can take the rest.';
  if (splits.any((s) => s.kind != SplitKind.rest && s.value <= 0)) return 'Enter an amount or a percent on every line.';
  final pct = splits.where((s) => s.kind == SplitKind.percent).fold<int>(0, (a, s) => a + s.value);
  if (pct > 10000) return 'The percents add up to ${(pct / 100).toStringAsFixed(pct % 100 == 0 ? 0 : 2)}%. Keep them at 100% or less.';
  final fixed = splits.where((s) => s.kind == SplitKind.fixed).fold<int>(0, (a, s) => a + s.value);
  if (net > 0 && fixed > net) return 'The fixed amounts are more than one paycheck.';
  final ids = [for (final s in splits) if (s.accountId != null) s.accountId];
  if (ids.toSet().length != ids.length) return 'Each account can have one line.';
  return null;
}

/// How much of one paycheck lands in Cash: split lines into checking accounts that count. With no splits it is the whole paycheck,
/// unless it lands in an account that doesn't count (savings, or one switched off).
int paycheckIntoCash(int net, List<PaySplit> splits, List<Account> accounts, {String? landsIn}) {
  Account? of(String? id) => id == null ? null : accounts.where((a) => a.id == id).firstOrNull;
  if (splits.isEmpty) {
    final a = of(landsIn);
    return a == null || countsAsCash(a) ? net : 0;
  }
  final amounts = splitAmounts(net, splits);
  var sum = 0;
  for (var i = 0; i < splits.length; i++) {
    final a = of(splits[i].accountId);
    if (a != null && countsAsCash(a)) sum += amounts[i];
  }
  return sum;
}
