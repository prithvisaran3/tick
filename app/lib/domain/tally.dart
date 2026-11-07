/// Tally: splitting shared expenses with friends. Integer cents everywhere. Groups have members; the store turns MY member id in each group into [me],
/// so everything here reads the same whoever is looking. Ids are member ids in live mode.
/// Balances: positive = that person is owed, negative = they owe. The server computes the same numbers (`tally_balances`);
/// this Dart mirror powers demo/guest mode and the live screens' previews, and `simplify` is checked against the shared vectors in
/// api/tests/data/tally_simplify.json so Python and Dart always agree.
library;

const me = 'me';

/// The custom group icons (design/icons/tally), in picker order.
const tallyIcons = ['home', 'trip', 'food', 'drinks', 'party', 'groceries', 'rent', 'utilities', 'car', 'gym', 'movie', 'concert', 'coffee', 'gift', 'pets', 'work', 'study', 'game', 'beach', 'ski', 'camping', 'wedding', 'baby', 'misc'];

/// A group from before icons: the nearest one to its emoji.
String? iconForEmoji(String? e) => e == null ? null : const {'🏠': 'home', '✈️': 'trip', '🍽️': 'food', '🎉': 'party', '🛒': 'groceries', '💼': 'work'}[e] ?? 'misc';

enum SplitType { equal, exact, percent, shares }

class TallyPerson {
  const TallyPerson({required this.id, required this.name, this.colorKey = 'shop', this.phone, this.userId, this.status = 'active', this.personId, this.email, this.avatar});
  final Map<String, dynamic>? avatar;
  final String? email;
  final String? personId; // my address book entry for this guest, when it is mine
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
  const TallyGroup({required this.id, required this.name, required this.memberIds, this.emoji, this.direct = false, this.colorKey = 'shop', this.isOwner = true, this.archived = false, this.iconKey});
  final String? iconKey;   // a key in [tallyIcons]
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

enum ReminderTone { friendly, neutral, firm }

/// A prefilled message. Sentence case, the amount first or near it; firm is plain, never rude.
String reminderText(ReminderTone tone, {required String name, required String amount, required String group, String? link, String? zelle}) {
  final body = switch (tone) {
    ReminderTone.friendly => 'Hey $name, when you get a chance: $amount for $group.',
    ReminderTone.neutral => '$name, you owe $amount for $group.',
    ReminderTone.firm => '$name, $amount for $group is still outstanding. Please pay it this week.',
  };
  final parts = [body, if (zelle != null && zelle.trim().isNotEmpty) 'My Zelle is ${zelle.trim()}.', ?link];
  return parts.join(' ');
}

/// "Reminded 2 days ago". Null when there is no reminder to mention.
String? remindedAgo(DateTime? at, DateTime now) {
  if (at == null) return null;
  final d = now.difference(at);
  if (d.inHours < 1) return 'Reminded just now';
  if (d.inHours < 24) return 'Reminded ${d.inHours} ${d.inHours == 1 ? 'hour' : 'hours'} ago';
  return 'Reminded ${d.inDays} ${d.inDays == 1 ? 'day' : 'days'} ago';
}

/// 24 hours between reminders to one person in one group. The server enforces it; this only greys out the button.
bool canRemind(DateTime? last, DateTime now) => last == null || now.difference(last) >= const Duration(hours: 24);

/// Venmo's documented web payment link (venmo.com/paymentlinks). Recipient is left out because Tick doesn't know Venmo usernames.
Uri venmoLink(int cents, String note) => Uri.https('venmo.com', '/', {'txn': 'pay', 'amount': (cents / 100).toStringAsFixed(2), 'note': note});

/// Cash App documents no amount-in-URL format, so this only opens the app; the amount is on the clipboard first.
final cashAppLink = Uri.https('cash.app', '/');

/// Everything between me and one person in a group, oldest first, with the running balance from my side (positive = they owe me).
class LedgerLine {
  const LedgerLine(this.on, this.label, this.deltaCents, this.runningCents);
  final DateTime on;
  final String label;
  final int deltaCents;
  final int runningCents;
}

List<LedgerLine> personLedger(String person, Iterable<TallyExpense> expenses, Iterable<TallySettlement> settlements) {
  final rows = <(DateTime, String, int)>[];
  for (final e in expenses) {
    if (e.paidBy == me && e.shares.containsKey(person)) rows.add((e.spentOn, e.description, e.shares[person]!));
    if (e.paidBy == person && e.shares.containsKey(me)) rows.add((e.spentOn, e.description, -e.shares[me]!));
  }
  for (final s in settlements) {
    if (s.status != 'confirmed') continue;
    if (s.from == person && s.to == me) rows.add((s.on, 'They paid you', -s.amountCents));
    if (s.from == me && s.to == person) rows.add((s.on, 'You paid them', s.amountCents));
  }
  rows.sort((a, b) => a.$1.compareTo(b.$1));
  var run = 0;
  return [for (final r in rows) LedgerLine(r.$1, r.$2, r.$3, run += r.$3)];
}

/// One line on a receipt. [people]: who had it; empty means it isn't assigned yet.
class ReceiptItem {
  const ReceiptItem(this.name, this.cents, [this.people = const {}]);
  final String name;
  final int cents;
  final Set<String> people;
  ReceiptItem withPeople(Set<String> p) => ReceiptItem(name, cents, p);
}

/// Each person's cents: their items (shared items split equally), plus tax and tip in proportion to what they had. Always adds up to the receipt exactly.
/// Null until every item has someone on it.
Map<String, int>? itemisedSplit(List<ReceiptItem> items, int extraCents) {
  if (items.isEmpty || items.any((i) => i.people.isEmpty)) return null;
  final sub = <String, int>{};
  for (final i in items) {
    splitEqual(i.cents, i.people.toList()..sort()).forEach((p, c) => sub[p] = (sub[p] ?? 0) + c);
  }
  final extra = extraCents <= 0 ? const <String, int>{} : splitWeighted(extraCents, sub)!;
  return {for (final e in sub.entries) e.key: e.value + (extra[e.key] ?? 0)};
}

/// One person across every group: how much moves between us, and which group balances it clears. A debt in one group and credit in another become one payment.
class PlanItem {
  const PlanItem(this.key, this.name, this.netCents, this.legs);
  final String key;
  final String name;
  final int netCents; // positive = they pay me
  final List<(String, Transfer)> legs;
}

/// The fewest payments that clear my balances: each group simplified, then netted per person. [identity] says which members are the same human.
List<PlanItem> settlePlan(Iterable<TallyGroup> groups, Iterable<TallyExpense> expenses, Iterable<TallySettlement> settlements, {required String Function(String member) identity, required String Function(String member) name}) {
  final net = <String, int>{}, names = <String, String>{};
  final legs = <String, List<(String, Transfer)>>{};
  for (final g in groups) {
    for (final t in simplify(balances(expenses.where((e) => e.groupId == g.id), settlements.where((s) => s.groupId == g.id)))) {
      if (t.from != me && t.to != me) continue;
      final other = t.from == me ? t.to : t.from;
      final k = identity(other);
      net[k] = (net[k] ?? 0) + (t.to == me ? t.cents : -t.cents);
      names[k] = name(other);
      (legs[k] ??= []).add((g.id, t));
    }
  }
  final out = [for (final e in net.entries) PlanItem(e.key, names[e.key]!, e.value, legs[e.key]!)]
    ..sort((a, b) { final d = b.netCents.abs().compareTo(a.netCents.abs()); return d != 0 ? d : a.key.compareTo(b.key); });
  return out;
}

/// What a group's history says: who usually pays, and spend per month (oldest first, up to [months], including this one).
class GroupInsights {
  const GroupInsights(this.paidBy, this.monthly, this.totalCents, this.frontedCents, this.myShareCents);
  /// What I paid at the till, and what was really mine. The gap is what I carried for everyone else.
  final int frontedCents;
  final int myShareCents;
  final List<(String, int)> paidBy; // biggest first
  final List<(DateTime, int)> monthly;
  final int totalCents;
}

GroupInsights groupInsights(Iterable<TallyExpense> expenses, DateTime now, {int months = 6}) {
  final by = <String, int>{};
  final month = {for (var i = months - 1; i >= 0; i--) DateTime(now.year, now.month - i): 0};
  var total = 0, fronted = 0, mine = 0;
  for (final e in expenses) {
    if (e.paidBy == me) fronted += e.amountCents;
    mine += e.shares[me] ?? 0;
    by[e.paidBy] = (by[e.paidBy] ?? 0) + e.amountCents;
    total += e.amountCents;
    final m = DateTime(e.spentOn.year, e.spentOn.month);
    if (month.containsKey(m)) month[m] = month[m]! + e.amountCents;
  }
  final paid = [for (final e in by.entries) (e.key, e.value)]..sort((a, b) { final d = b.$2.compareTo(a.$2); return d != 0 ? d : a.$1.compareTo(b.$1); });
  return GroupInsights(paid, [for (final e in month.entries) (e.key, e.value)], total, fronted, mine);
}

class TallyBill {
  const TallyBill({required this.id, required this.groupId, required this.description, required this.amountCents, required this.cadence, required this.nextOn, this.createdBy});
  final String id;
  final String groupId;
  final String description;
  final int amountCents;
  final String cadence; // weekly | monthly | yearly
  final DateTime nextOn;
  final String? createdBy;
}

DateTime nextBillDate(DateTime from, String cadence) => switch (cadence) {
      'weekly' => DateTime(from.year, from.month, from.day + 7),
      'yearly' => DateTime(from.year + 1, from.month, from.day),
      _ => DateTime(from.year, from.month + 1, from.day),
    };
