import 'merchant_name.dart';
import 'models.dart';

/// What Tick can see of my pay in the bank: who pays me, the last few deposits, and which account they land in. Suggestions only.
class PaycheckGuess {
  const PaycheckGuess({this.employer, this.amounts = const [], this.accountId});
  final String? employer;
  final List<int> amounts; // newest first, at most 3
  final String? accountId;
  /// The typical take-home: the middle of the last three.
  int? get typicalCents {
    if (amounts.isEmpty) return null;
    final s = [...amounts]..sort();
    return s[s.length ~/ 2];
  }
  bool get varies => amounts.length >= 2 && amounts.any((a) => (a - amounts.first).abs() > amounts.first ~/ 50);
}

final _payroll = RegExp(r'\b(payroll|direct dep|dir dep|salary|paycheck|adp)\b', caseSensitive: false);

PaycheckGuess guessPaychecks(List<Txn> txns, Map<String, Category> cats, List<Account> accounts, {DateTime? since}) {
  final cash = {for (final a in accounts) if (a.type == 'checking' || a.type == 'savings') a.id};
  final pay = txns.where((t) => t.amountCents > 0 && t.flow == null && cash.contains(t.accountId) && (since == null || !t.occurredAt.isBefore(since))
      && p2pName(t.merchant) == null && (cats[t.categoryId]?.name == 'Income' && !t.merchant.toLowerCase().contains('interest') || _payroll.hasMatch(t.merchant))).toList()
    ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
  if (pay.isEmpty) return const PaycheckGuess();
  final by = <String, int>{};
  for (final t in pay) { by[cleanMerchant(t.merchant)] = (by[cleanMerchant(t.merchant)] ?? 0) + 1; }
  final employer = (by.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
  final mine = pay.where((t) => cleanMerchant(t.merchant) == employer).toList();
  final acct = <String, int>{};
  for (final t in mine) { if (t.accountId != null) acct[t.accountId!] = (acct[t.accountId!] ?? 0) + 1; }
  return PaycheckGuess(employer: employer, amounts: [for (final t in mine.take(3)) t.amountCents],
      accountId: acct.isEmpty ? null : (acct.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key);
}
