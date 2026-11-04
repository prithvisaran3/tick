import 'models.dart';

class MonthFlows {
  const MonthFlows({required this.inCents, required this.outCents, required this.byCategory, required this.dailyOut, required this.businessCents, required this.prevOutSamePeriod});
  final int inCents;
  final int outCents; // positive magnitude
  final Map<String, int> byCategory; // categoryId -> positive cents, spend only
  final Map<int, int> dailyOut; // day-of-month -> positive cents
  final int businessCents;
  final int prevOutSamePeriod; // last month, same days elapsed
  int get netCents => inCents - outCents;
  /// Change vs the same days last month, as a fraction (-0.06 = 6% lower); null if no baseline.
  double? get vsLast => prevOutSamePeriod == 0 ? null : (outCents - prevOutSamePeriod) / prevOutSamePeriod;
}

/// Transfers are ignored on both sides so moving money never looks like spending.
MonthFlows computeFlows(List<Txn> txns, DateTime now, {Set<String> transferCats = const {'cat-transfer'}}) {
  final start = DateTime(now.year, now.month, 1);
  final end = DateTime(now.year, now.month + 1, 1);
  final prevStart = DateTime(now.year, now.month - 1, 1);
  final prevCut = prevStart.add(Duration(days: now.day));
  var inC = 0, outC = 0, biz = 0, prevOut = 0;
  final cats = <String, int>{};
  final daily = <int, int>{};
  for (final t in txns) {
    if (transferCats.contains(t.categoryId)) continue;
    final d = t.occurredAt;
    if (!d.isBefore(start) && d.isBefore(end)) {
      if (t.amountCents > 0) { inC += t.amountCents; }
      else {
        final v = -t.amountCents;
        outC += v;
        cats[t.categoryId ?? 'cat-other'] = (cats[t.categoryId ?? 'cat-other'] ?? 0) + v;
        daily[d.day] = (daily[d.day] ?? 0) + v;
        if (t.isBusiness) biz += v;
      }
    } else if (!d.isBefore(prevStart) && d.isBefore(prevCut) && t.amountCents < 0) {
      prevOut += -t.amountCents;
    }
  }
  return MonthFlows(inCents: inC, outCents: outC, byCategory: cats, dailyOut: daily, businessCents: biz, prevOutSamePeriod: prevOut);
}

int daysInMonth(DateTime d) => DateTime(d.year, d.month + 1, 0).day;
int firstWeekdaySunday0(DateTime d) => DateTime(d.year, d.month, 1).weekday % 7;
