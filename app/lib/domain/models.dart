import 'package:flutter/foundation.dart';

enum TxStatus { pending, posted }

@immutable
class Category {
  const Category({required this.id, required this.name, required this.colorKey, this.icon = 'card', this.kind = 'spend'});
  final String id;
  final String name;
  final String colorKey; // food | ride | sub | home | biz | inc | shop
  final String icon;
  final String kind; // spend | income | transfer
  factory Category.fromJson(Map<String, dynamic> j) => Category(
      id: j['id'] as String, name: j['name'] as String, colorKey: (j['color_key'] ?? 'shop') as String,
      icon: (j['icon'] ?? 'card') as String, kind: (j['kind'] ?? 'spend') as String);
}

@immutable
class Account {
  const Account({required this.id, required this.name, this.mask, this.type = 'checking', this.balanceCents, this.availableCents, this.includeInSafe = true, this.manual = false,
      this.institution, this.subtype, this.creditLimitCents, this.statementBalanceCents, this.minimumPaymentCents, this.dueDate, this.lastStatementDate,
      this.aprBps, this.interestRateBps, this.nextPaymentCents, this.lastPaymentCents, this.lastPaymentDate});
  final bool manual; // typed in by hand (no bank link)
  final String id;
  final String name;
  final String? mask;
  final String type; // checking | savings | credit | loan | cash | other
  /// Depository: what you have. Credit and loan: NEGATIVE, what you owe.
  final int? balanceCents;
  final int? availableCents;
  final bool includeInSafe;
  final String? institution; // "Discover"
  final String? subtype;
  final int? creditLimitCents;
  final int? statementBalanceCents; // positive = owed on the last statement
  final int? minimumPaymentCents;
  final DateTime? dueDate; // next payment due (cards and loans)
  final DateTime? lastStatementDate;
  final int? aprBps; // 2499 = 24.99%
  final int? interestRateBps;
  final int? nextPaymentCents; // loans
  final int? lastPaymentCents;
  final DateTime? lastPaymentDate;

  bool get isCard => type == 'credit';
  bool get isLoan => type == 'loan';
  bool get isCash => type == 'checking' || type == 'savings' || type == 'cash';
  /// Money owed on a card or loan, positive. 0 for cash accounts.
  int get owedCents => (isCard || isLoan) ? (-(balanceCents ?? 0)).clamp(0, 1 << 52) : 0;
  int? get availableCreditCents => creditLimitCents == null ? null : (creditLimitCents! - owedCents).clamp(0, creditLimitCents!);
  /// 0.0-1.0+ of the limit used, or null without a limit.
  double? get utilisation => (creditLimitCents == null || creditLimitCents == 0) ? null : owedCents / creditLimitCents!;
  /// What is still due on the last statement: the statement balance, but never more than you owe right now (a payment already made counts).
  int get statementDueCents {
    final s = statementBalanceCents;
    if (s == null) return owedCents;
    var due = s < owedCents ? s : owedCents;
    if (lastPaymentDate != null && lastStatementDate != null && lastPaymentDate!.isAfter(lastStatementDate!) && lastPaymentCents != null) {
      due = (s - lastPaymentCents!).clamp(0, due);
    }
    return due < 0 ? 0 : due;
  }

  String get _brand => institution ?? name.split(' ').first;
  String get label => mask == null ? name : '$_brand ••$mask';
  /// Short form for rows: institution (or first word) + last four, e.g. "Discover ••1234".
  String get shortLabel => mask == null ? name.split(' ').first : '$_brand ••$mask';
  static DateTime? _date(Object? v) => v is String && v.isNotEmpty ? DateTime.tryParse(v) : null;
  factory Account.fromJson(Map<String, dynamic> j) => Account(
      id: j['id'] as String, name: j['name'] as String, mask: j['mask'] as String?, type: (j['type'] ?? 'checking') as String,
      balanceCents: (j['balance_cents'] as num?)?.toInt(), availableCents: (j['available_cents'] as num?)?.toInt(),
      includeInSafe: (j['include_in_safe'] ?? true) as bool, manual: (j['is_manual'] ?? false) as bool,
      institution: j['institution'] as String?, subtype: j['subtype'] as String?, creditLimitCents: (j['credit_limit_cents'] as num?)?.toInt(),
      statementBalanceCents: (j['statement_balance_cents'] as num?)?.toInt(), minimumPaymentCents: (j['minimum_payment_cents'] as num?)?.toInt(),
      dueDate: _date(j['next_payment_due_date']), lastStatementDate: _date(j['last_statement_date']), aprBps: (j['apr_bps'] as num?)?.toInt(),
      interestRateBps: (j['interest_rate_bps'] as num?)?.toInt(), nextPaymentCents: (j['next_payment_cents'] as num?)?.toInt(),
      lastPaymentCents: (j['last_payment_cents'] as num?)?.toInt(), lastPaymentDate: _date(j['last_payment_date']));
  Map<String, dynamic> toJson() => {
        'id': id, 'name': name, 'mask': mask, 'type': type, 'balance_cents': balanceCents, 'available_cents': availableCents, 'include_in_safe': includeInSafe,
        'is_manual': manual, 'institution': institution, 'subtype': subtype, 'credit_limit_cents': creditLimitCents, 'statement_balance_cents': statementBalanceCents,
        'minimum_payment_cents': minimumPaymentCents, 'next_payment_due_date': dueDate?.toIso8601String().substring(0, 10),
        'last_statement_date': lastStatementDate?.toIso8601String().substring(0, 10), 'apr_bps': aprBps, 'interest_rate_bps': interestRateBps,
        'next_payment_cents': nextPaymentCents, 'last_payment_cents': lastPaymentCents, 'last_payment_date': lastPaymentDate?.toIso8601String().substring(0, 10)};
}

@immutable
class Txn {
  const Txn({
    required this.id, required this.amountCents, required this.occurredAt, required this.merchant,
    this.categoryId, this.accountId, this.status = TxStatus.posted, this.confidence = 1.0, this.needsReview = false,
    this.tags = const [], this.note, this.source = 'manual', this.cardLast4, this.receiptPath, this.flow,
  });
  /// 'transfer' = between my own accounts (never spending or income); 'bill' = a loan payment (cash out, a bill); null = ordinary.
  final String? flow;
  bool get isTransfer => flow == 'transfer';
  final String id;
  final int amountCents;
  final DateTime occurredAt; // local wall-clock time
  final String merchant;
  final String? categoryId;
  final String? accountId;
  final TxStatus status;
  final double confidence;
  final bool needsReview;
  final List<String> tags;
  final String? note;
  final String source;
  final String? cardLast4;
  final String? receiptPath;
  bool get isIncome => amountCents > 0;
  bool get isBusiness => tags.contains('business');
  Txn copyWith({int? amountCents, DateTime? occurredAt, String? merchant, String? categoryId, bool? needsReview, List<String>? tags, String? note, double? confidence, String? accountId}) => Txn(
      id: id, amountCents: amountCents ?? this.amountCents, occurredAt: occurredAt ?? this.occurredAt, merchant: merchant ?? this.merchant,
      categoryId: categoryId ?? this.categoryId, accountId: accountId ?? this.accountId, status: status, confidence: confidence ?? this.confidence,
      needsReview: needsReview ?? this.needsReview, tags: tags ?? this.tags, note: note ?? this.note, source: source, cardLast4: cardLast4, receiptPath: receiptPath, flow: flow);
  factory Txn.fromJson(Map<String, dynamic> j) {
    final srcs = (j['sources'] as List?) ?? const [];
    return Txn(
      id: j['id'] as String, amountCents: (j['amount_cents'] as num).toInt(),
      occurredAt: DateTime.parse(j['occurred_at'] as String).toLocal(),
      merchant: (j['merchant_clean'] ?? j['merchant_raw'] ?? 'Unknown') as String,
      categoryId: j['category_id'] as String?, accountId: j['account_id'] as String?,
      status: j['status'] == 'pending' ? TxStatus.pending : TxStatus.posted,
      confidence: (j['confidence'] as num?)?.toDouble() ?? 1.0, needsReview: (j['needs_review'] ?? false) as bool,
      tags: ((j['tags'] as List?) ?? const []).cast<String>(), note: j['note'] as String?,
      source: srcs.isEmpty ? 'manual' : ((srcs.first as Map)['source'] as String? ?? 'manual'),
      cardLast4: j['card_last4'] as String?, receiptPath: j['receipt_path'] as String?, flow: j['flow'] as String?);
  }
}

enum Cadence { weekly, biweekly, monthly, yearly }

@immutable
class Recurring {
  const Recurring({required this.id, required this.merchant, required this.cadence, required this.expectedCents, required this.nextDate, this.categoryId, this.priceHistory = const []});
  final String id;
  final String merchant;
  final Cadence cadence;
  final int expectedCents; // positive magnitude
  final DateTime nextDate;
  final String? categoryId;
  final List<int> priceHistory; // cents, oldest first
  int? get previousPrice => priceHistory.length >= 2 ? priceHistory[priceHistory.length - 2] : null;
  bool get priceWentUp => previousPrice != null && expectedCents > previousPrice!;
}

enum ExpectedKind { paycheck, refund, iou }

@immutable
class Expected {
  const Expected({required this.id, required this.kind, required this.label, required this.amountCents, required this.date});
  final String id;
  final ExpectedKind kind;
  final String label;
  final int amountCents;
  final DateTime date;
}

@immutable
class Goal {
  const Goal({required this.id, required this.name, required this.targetCents, required this.savedCents, required this.perPaydayCents});
  final String id;
  final String name;
  final int targetCents;
  final int savedCents;
  final int perPaydayCents;
}

enum PayFrequency { weekly, biweekly, semimonthly, monthly }

@immutable
class PaydayRule {
  const PaydayRule({required this.frequency, required this.anchor, required this.amountCents});
  final PayFrequency frequency;
  final DateTime anchor; // any known payday
  final int amountCents;
}

@immutable
class Connection {
  const Connection({required this.id, required this.institution, required this.status});
  final String id;
  final String institution;
  final String status; // active | login_required | error | removed
  bool get needsRelink => status == 'login_required';
  factory Connection.fromJson(Map<String, dynamic> j) => Connection(id: j['id'] as String, institution: (j['institution'] ?? 'Bank') as String, status: (j['status'] ?? 'active') as String);
}

@immutable
class Budget {
  const Budget({required this.id, required this.categoryId, required this.capCents});
  final String id;
  final String categoryId;
  final int capCents;
}

@immutable
class LearnedRule {
  const LearnedRule({required this.id, required this.pattern, required this.categoryId});
  final String id;
  final String pattern;
  final String categoryId;
}
