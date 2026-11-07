/// Tally: splitting shared expenses with friends. Integer cents everywhere. Groups have members; the store turns MY member id in each group into [me],
/// so everything here reads the same whoever is looking. Ids are member ids in live mode.
/// Balances: positive = that person is owed, negative = they owe. The server computes the same numbers (`tally_balances`);
/// this Dart mirror powers demo/guest mode and the live screens' previews, and `simplify` is checked against the shared vectors in
/// api/tests/data/tally_simplify.json so Python and Dart always agree.
library;

const me = 'me';

enum SplitType { equal, exact, percent, shares }

class TallyPerson {
  const TallyPerson({required this.id, required this.name, this.colorKey = 'shop', this.phone, this.userId, this.status = 'active'});
  /// Set when this member is a Tick user; null for a guest.
  final String? userId;
  final String status; // active | left | removed
  bool get isGuest => userId == null;
  final String id;
  final String name;
  final String colorKey;
  final String? phone;
  String get first => name.trim().split(' ').first;
}

class TallyGroup {
  const TallyGroup({required this.id, required this.name, required this.memberIds, this.emoji, this.direct = false, this.colorKey = 'shop', this.isOwner = true, this.archived = false});
  final bool isOwner;   // only the owner renames, archives, deletes or removes members
  final bool archived;
  final String id;
  final String name;
  final String? emoji;
  final bool direct;
  final String colorKey;
  final List<String> memberIds; // people other than me
}

class TallyExpense {
  const TallyExpense({required this.id, required this.groupId, required this.description, required this.amountCents, required this.paidBy,
      required this.shares, required this.spentOn, this.splitType = SplitType.equal, this.transactionId, this.note, this.weights = const {}, this.createdBy, this.category, this.receiptPath});
  final String? createdBy; // user id of who added it; null for a local one
  final String? category;
  final String? receiptPath;
  /// What was typed per person (percent, share count) so editing shows it again; empty for equal and exact.
  final Map<String, num> weights;
  final String id;
  final String groupId;
  final String description;
  final int amountCents;
  final String paidBy; // person id or [me]
  final Map<String, int> shares; // person id or [me] -> cents owed
  final DateTime spentOn;
  final SplitType splitType;
  final String? transactionId;
  final String? note;
}

class TallySettlement {
  const TallySettlement({required this.id, required this.groupId, required this.from, required this.to, required this.amountCents, required this.on,
      this.method = 'zelle', this.status = 'confirmed', this.transactionId, this.createdBy});
  final String? createdBy;
  final String id;
  final String groupId;
  final String from; // who paid
  final String to; // who received
  final int amountCents;
  final DateTime on;
  final String method;
  final String status; // confirmed | pending | rejected
  final String? transactionId;
}

/// Splits [total] cents equally between [people]. The leftover cents go one each to the first people, so the shares always add to the total.
Map<String, int> splitEqual(int total, List<String> people) {
  if (people.isEmpty) return {};
  final base = total ~/ people.length, extra = total % people.length;
  return {for (var i = 0; i < people.length; i++) people[i]: base + (i < extra ? 1 : 0)};
}

/// Splits by weights (percent, or share counts) with the largest-remainder method: shares add to [total] exactly and never differ from the
/// ideal by more than one cent. Ties go to the earlier person. Returns null if the weights are unusable (empty, negative, or all zero).
Map<String, int>? splitWeighted(int total, Map<String, num> weights) {
  if (weights.isEmpty || weights.values.any((w) => w < 0)) return null;
  final sum = weights.values.fold<num>(0, (a, b) => a + b);
  if (sum <= 0) return null;
  final ids = weights.keys.toList();
  final floor = <String, int>{}, rem = <String, double>{};
  var used = 0;
  for (final id in ids) {
    final ideal = total * weights[id]! / sum;
    floor[id] = ideal.floor();
    rem[id] = ideal - ideal.floor();
    used += floor[id]!;
  }
  final order = [...ids]..sort((a, b) {
    final d = rem[b]!.compareTo(rem[a]!);
    return d != 0 ? d : ids.indexOf(a).compareTo(ids.indexOf(b));
  });
  for (var i = 0; i < total - used; i++) {
    floor[order[i % order.length]] = floor[order[i % order.length]]! + 1;
  }
  return floor;
}

/// Exact amounts: valid only when they add up to [total]. Returns null otherwise (the sheet shows how much is left).
Map<String, int>? splitExact(int total, Map<String, int> amounts) =>
    amounts.values.any((v) => v < 0) || amounts.values.fold<int>(0, (a, b) => a + b) != total ? null : Map.of(amounts);

/// Net balance per person across [expenses] and confirmed [settlements] (pending and rejected ones never move a balance).
Map<String, int> balances(Iterable<TallyExpense> expenses, Iterable<TallySettlement> settlements) {
  final net = <String, int>{};
  void add(String p, int c) => net[p] = (net[p] ?? 0) + c;
  for (final e in expenses) {
    add(e.paidBy, e.amountCents);
    e.shares.forEach((p, c) => add(p, -c));
  }
  for (final s in settlements) {
    if (s.status != 'confirmed') continue;
    add(s.from, s.amountCents);
    add(s.to, -s.amountCents);
  }
  return net..removeWhere((_, v) => v == 0);
}

class Transfer {
  const Transfer(this.from, this.to, this.cents);
  final String from;
  final String to;
  final int cents;
  @override
  bool operator ==(Object other) => other is Transfer && other.from == from && other.to == to && other.cents == cents;
  @override
  int get hashCode => Object.hash(from, to, cents);
  @override
  String toString() => '$from→$to $cents';
}

/// Fewest-ish payments that settle everyone: the biggest debtor pays the biggest creditor. Same ordering as `simplify` in api/app/tally.py.
List<Transfer> simplify(Map<String, int> net) {
  int byAmountThenId(MapEntry<String, int> a, MapEntry<String, int> b) {
    final d = b.value.compareTo(a.value);
    return d != 0 ? d : a.key.compareTo(b.key);
  }
  final cred = [for (final e in net.entries) if (e.value > 0) MapEntry(e.key, e.value)]..sort(byAmountThenId);
  final debt = [for (final e in net.entries) if (e.value < 0) MapEntry(e.key, -e.value)]..sort(byAmountThenId);
  final c = [for (final e in cred) [e.key, e.value]], d = [for (final e in debt) [e.key, e.value]];
  final out = <Transfer>[];
  var i = 0, j = 0;
  while (i < d.length && j < c.length) {
    final pay = (d[i][1] as int) < (c[j][1] as int) ? d[i][1] as int : c[j][1] as int;
    out.add(Transfer(d[i][0] as String, c[j][0] as String, pay));
    d[i][1] = (d[i][1] as int) - pay;
    c[j][1] = (c[j][1] as int) - pay;
    if (d[i][1] == 0) i++;
    if (c[j][1] == 0) j++;
  }
  return out;
}

/// What I'm owed and what I owe across all groups (each group nets on its own: a debt in one group never cancels credit in another).
({int owedToMe, int iOwe}) summary(Iterable<TallyGroup> groups, Iterable<TallyExpense> expenses, Iterable<TallySettlement> settlements) {
  var owed = 0, owe = 0;
  for (final g in groups) {
    final n = balances(expenses.where((e) => e.groupId == g.id), settlements.where((s) => s.groupId == g.id))[me] ?? 0;
    if (n > 0) { owed += n; } else { owe += -n; }
  }
  return (owedToMe: owed, iOwe: owe);
}

bool isAllSquare(Iterable<TallyGroup> groups, Iterable<TallyExpense> expenses, Iterable<TallySettlement> settlements) =>
    expenses.isNotEmpty && groups.every((g) => balances(expenses.where((e) => e.groupId == g.id), settlements.where((s) => s.groupId == g.id)).isEmpty);

/// A Zelle (or Venmo, cash-app) row in Activity that looks like a settlement of a suggested transfer: right amount, within [days] days,
/// and the person's first name appears in the merchant text. Suggestions only; nothing is recorded until I confirm.
bool looksLikeSettlement({required Transfer t, required String personFirstName, required int txnCents, required String merchant, required DateTime txnAt, required DateTime since, int days = 14}) {
  final iPay = t.from == me; // I send money out (negative) or they send me money (positive)
  if (iPay ? txnCents != -t.cents : txnCents != t.cents) return false;
  if (txnAt.isBefore(since) || txnAt.difference(since).inDays > days + 30) return false;
  final m = merchant.toLowerCase();
  return m.contains(personFirstName.toLowerCase()); // the right person, not just any Zelle of the right amount
}
