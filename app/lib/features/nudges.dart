import 'package:intl/intl.dart';
import '../data/ledger.dart';
import '../domain/money.dart';
import '../domain/payday.dart';
import '../domain/safe_to_spend.dart';
import '../domain/dates.dart';

class Nudge {
  const Nudge(this.kind, this.title, this.body, {this.paceRatio, this.urgent = false, this.route});
  /// Where tapping it goes (defaults: relink -> /banks, else /incoming).
  final String? route;
  final String kind; // pace | duplicate | forgotten | bill | payday
  final String title;
  final String body;
  final double? paceRatio;
  final bool urgent;
}

/// Exactly ONE nudge: highest priority wins. Pure; unit-tested.
Nudge? pickNudge(LedgerState l, SafeToSpend? sts, DateTime now, {String? skipBillFor}) {
  final today = dayOnly(now);
  // 0. A bank link that needs a quick sign-in (calm, urgent).
  final broken = l.connections.where((c) => c.needsRelink).toList();
  if (broken.isNotEmpty) {
    return Nudge('relink', 'Your ${broken.first.institution} link needs a quick sign-in to keep syncing.', 'Takes under a minute. Nothing was lost.', urgent: true);
  }
  // 1. Overspend (urgent): safe to spend is negative.
  final hasCash = l.accounts.any((a) => a.includeInSafe && a.type != 'credit' && a.type != 'savings');
  if (sts != null && sts.overspent && hasCash) {
    return Nudge('pace', 'You are ${formatDollars(-sts.cents)} past safe to spend', 'Bills and goals before payday are bigger than your cash. Check what can wait.', urgent: true);
  }
  // 2. Bill due tomorrow.
  final tomorrow = addDays(today, 1);
  final due = l.recurring.where((r) => dayOnly(r.nextDate) == tomorrow).toList();
  if (due.isNotEmpty && due.first.merchant != skipBillFor) {
    final r = due.first;
    return Nudge('bill', 'Bill due tomorrow: ${r.merchant}, ${formatDollars(r.expectedCents)}.', 'It comes out tomorrow.');
  }
  // 2b. A card statement due within 3 days that still has money due (gentle; Tick never pays it for you).
  final cards = l.accounts.where((a) => a.isCard && a.dueDate != null && a.statementDueCents > 0).toList()..sort((a, b) => a.dueDate!.compareTo(b.dueDate!));
  for (final a in cards) {
    final days = daysBetween(today, dayOnly(a.dueDate!));
    if (days >= 0 && days <= 3) {
      final when = days == 0 ? 'today' : days == 1 ? 'tomorrow' : DateFormat('EEEE').format(a.dueDate!);
      return Nudge('card', '${a.shortLabel}: ${formatDollars(a.statementDueCents)} due $when.', 'Pay the statement balance from checking by then and there is no interest.', route: '/card/${a.id}');
    }
  }
  // 3. Duplicate charge: same merchant + amount within 3 days, both outgoing and not marked reviewed.
  final recent = l.txns.where((t) => t.amountCents < 0 && daysBetween(dayOnly(t.occurredAt), today) <= 3).toList();
  for (var i = 0; i < recent.length; i++) {
    for (var j = i + 1; j < recent.length; j++) {
      if (recent[i].merchant == recent[j].merchant && recent[i].amountCents == recent[j].amountCents && _catName(l, recent[i].categoryId) == 'subscriptions') {
        return Nudge('duplicate', 'Two ${formatCents(-recent[i].amountCents)} charges at ${recent[i].merchant}', 'Same amount twice in 3 days. Worth a look.');
      }
    }
  }
  // 4. Category pace: food on pace to pass the typical monthly spend by 15%+ (needs 7+ days of data).
  final pace = _foodPace(l, now);
  if (pace != null) return pace;
  return null;
}

/// Category by NAME, lower-cased. Live categories have uuid ids, so comparing to the demo's 'cat-*' ids made two nudges silent for real users.
String _catName(LedgerState l, String? id) => (l.category(id)?.name ?? '').toLowerCase();

Nudge? _foodPace(LedgerState l, DateTime now) {
  if (now.day < 7) return null;
  const foodCats = {'groceries', 'restaurants', 'coffee'};
  int sum(DateTime a, DateTime b) => l.txns.where((t) => t.amountCents < 0 && foodCats.contains(_catName(l, t.categoryId)) && !t.occurredAt.isBefore(a) && t.occurredAt.isBefore(b)).fold(0, (s, t) => s - t.amountCents);
  final start = DateTime(now.year, now.month, 1);
  final soFar = sum(start, addDays(dayOnly(now), 1));
  final daysInMonth = DateTime(now.year, now.month + 1, 0).day;
  final projected = (soFar / now.day * daysInMonth).round();
  final prevStart = DateTime(now.year, now.month - 1, 1);
  final prev = sum(prevStart, start);
  if (prev <= 0 || projected < prev * 1.15) return null;
  return Nudge('pace', 'Food is running hot', 'On pace for ${formatDollars(projected)} vs ${formatDollars(prev)} last month.', paceRatio: projected / prev);
}
