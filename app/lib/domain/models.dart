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
  const Account({required this.id, required this.name, this.mask, this.type = 'checking', this.balanceCents, this.availableCents, this.includeInSafe = true, this.manual = false});
  final bool manual; // typed in by hand (no bank link)
  final String id;
  final String name;
  final String? mask;
  final String type; // checking | savings | credit | cash | other
  final int? balanceCents;
  final int? availableCents;
  final bool includeInSafe;
  String get label => mask == null ? name : '$name ••$mask';
  /// Short form for rows: first word + last four, e.g. "Chase ••1180".
  String get shortLabel => mask == null ? name.split(' ').first : '${name.split(' ').first} ••$mask';
  factory Account.fromJson(Map<String, dynamic> j) => Account(
      id: j['id'] as String, name: j['name'] as String, mask: j['mask'] as String?, type: (j['type'] ?? 'checking') as String,
      balanceCents: (j['balance_cents'] as num?)?.toInt(), availableCents: (j['available_cents'] as num?)?.toInt(),
      includeInSafe: (j['include_in_safe'] ?? true) as bool, manual: (j['is_manual'] ?? false) as bool);
}

@immutable
class Txn {
  const Txn({
    required this.id, required this.amountCents, required this.occurredAt, required this.merchant,
    this.categoryId, this.accountId, this.status = TxStatus.posted, this.confidence = 1.0, this.needsReview = false,
    this.tags = const [], this.note, this.source = 'manual', this.cardLast4, this.receiptPath,
  });
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
      needsReview: needsReview ?? this.needsReview, tags: tags ?? this.tags, note: note ?? this.note, source: source, cardLast4: cardLast4, receiptPath: receiptPath);
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
      cardLast4: j['card_last4'] as String?, receiptPath: j['receipt_path'] as String?);
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
