import 'models.dart';
import 'dates.dart';

/// Totals for a set of transactions under Tick's money rules. LIVE numbers come from the server (`tick_flows` in
/// supabase/migrations/20261106000002_activity_cards.sql); this Dart mirror is used only for demo mode and the signed-out guest
/// ledger, and test/flows_parity_test.dart checks it against the same fixture and numbers as supabase/tests/flows.sql.
///
///   excluded = flow 'transfer' (own accounts, card and loan payments) or 'settlement' (Tally): never spending, never income.
///   out      = money leaving, positive (purchases, card purchases, fees, loan payments).
///   refund   = money coming back onto a card or loan that isn't a payment: it lowers out, it isn't income.
///   in       = money arriving in cash accounts, or anything categorised Income.
class Totals {
  const Totals({this.inCents = 0, this.outCents = 0, this.businessCents = 0, this.billsCents = 0, this.count = 0,
      this.byCategory = const {}, this.byAccount = const {}, this.dailyOut = const {}});
  final int inCents;
  final int outCents;
  final int businessCents;
  final int billsCents;
  final int count;
  final Map<String, int> byCategory; // categoryId ('none' if uncategorised) -> out
  final Map<String, int> byAccount; // accountId ('none') -> out
  final Map<DateTime, int> dailyOut; // local calendar day -> out
  int get netCents => inCents - outCents;

  factory Totals.fromJson(Map<String, dynamic> j) {
    Map<String, int> m(Object? o) => {for (final e in ((o as Map?) ?? const {}).entries) e.key as String: (e.value as num).toInt()};
    return Totals(
      inCents: (j['in'] as num?)?.toInt() ?? 0, outCents: (j['out'] as num?)?.toInt() ?? 0, businessCents: (j['business'] as num?)?.toInt() ?? 0,
      billsCents: (j['bills'] as num?)?.toInt() ?? 0, count: (j['count'] as num?)?.toInt() ?? 0,
      byCategory: m(j['by_category']), byAccount: m(j['by_account']),
      dailyOut: {for (final e in m(j['daily_out']).entries) DateTime.parse(e.key): e.value},
    );
  }
}

String? _kind(String? categoryId, Map<String, Category>? cats) =>
    cats?[categoryId]?.kind ?? (categoryId == 'cat-transfer' ? 'transfer' : categoryId == 'cat-income' ? 'income' : null);

/// Only the FLOW excludes money. A Transfer-kind category is a label: Zelle to a friend is real money out (docs/MONEY_RULES.md).
bool isExcluded(Txn t, {Map<String, Category>? cats}) => t.flow == 'transfer' || t.flow == 'settlement';

/// Positive money out for one row (negative for a card refund), 0 if excluded or money in.
int outOf(Txn t, {Map<String, Category>? cats, Map<String, Account>? accounts}) {
  if (isExcluded(t, cats: cats)) return 0;
  if (t.amountCents < 0) return -t.amountCents;
  final type = accounts?[t.accountId]?.type ?? 'checking';
  if (t.amountCents > 0 && _kind(t.categoryId, cats) != 'income' && (type == 'credit' || type == 'loan')) return -t.amountCents;
  return 0;
}

int inOf(Txn t, {Map<String, Category>? cats, Map<String, Account>? accounts}) {
  if (isExcluded(t, cats: cats) || t.amountCents <= 0) return 0;
  final type = accounts?[t.accountId]?.type ?? 'checking';
  return (_kind(t.categoryId, cats) == 'income' || (type != 'credit' && type != 'loan')) ? t.amountCents : 0;
}

Totals computeTotals(Iterable<Txn> txns, {Map<String, Category>? cats, Map<String, Account>? accounts}) {
  var inC = 0, outC = 0, biz = 0, bills = 0, n = 0;
  final byCat = <String, int>{}, byAcct = <String, int>{}, daily = <DateTime, int>{};
  for (final t in txns) {
    n++;
    final o = outOf(t, cats: cats, accounts: accounts);
    inC += inOf(t, cats: cats, accounts: accounts);
    if (o == 0) continue;
    outC += o;
    if (t.isBusiness) biz += o;
    if (t.flow == 'bill') bills += o;
    byCat[t.categoryId ?? 'none'] = (byCat[t.categoryId ?? 'none'] ?? 0) + o;
    byAcct[t.accountId ?? 'none'] = (byAcct[t.accountId ?? 'none'] ?? 0) + o;
    final d = etDay(t.occurredAt);
    daily[d] = (daily[d] ?? 0) + o;
  }
  byCat.removeWhere((_, v) => v == 0);
  byAcct.removeWhere((_, v) => v == 0);
  daily.removeWhere((_, v) => v == 0);
  return Totals(inCents: inC, outCents: outC, businessCents: biz, billsCents: bills, count: n, byCategory: byCat, byAccount: byAcct, dailyOut: daily);
}

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

  factory MonthFlows.from(Totals month, int prevOut) => MonthFlows(
      inCents: month.inCents, outCents: month.outCents, byCategory: month.byCategory, businessCents: month.businessCents, prevOutSamePeriod: prevOut,
      dailyOut: {for (final e in month.dailyOut.entries) e.key.day: e.value});
}

bool _inRange(DateTime d, DateTime from, DateTime to) => !d.isBefore(from) && d.isBefore(to);

/// Demo / guest mode only (live numbers come from the server).
MonthFlows computeFlows(List<Txn> txns, DateTime now, {Map<String, Category>? cats, Map<String, Account>? accounts}) {
  final start = DateTime(now.year, now.month, 1);
  final end = DateTime(now.year, now.month + 1, 1);
  final prevStart = DateTime(now.year, now.month - 1, 1);
  final prevCut = addDays(prevStart, now.day);
  final cur = computeTotals(txns.where((t) => _inRange(t.occurredAt, start, end)), cats: cats, accounts: accounts);
  final prev = computeTotals(txns.where((t) => _inRange(t.occurredAt, prevStart, prevCut)), cats: cats, accounts: accounts);
  return MonthFlows.from(cur, prev.outCents);
}

int daysInMonth(DateTime d) => DateTime(d.year, d.month + 1, 0).day;
int firstWeekdaySunday0(DateTime d) => DateTime(d.year, d.month, 1).weekday % 7;

/// America/New_York wall-clock time -> UTC instant, without depending on the phone's time zone (DB "days" are New York days).
/// US rules since 2007: EDT (UTC-4) from the second Sunday of March 02:00 to the first Sunday of November 02:00, else EST (UTC-5).
DateTime etToUtc(DateTime wall) {
  DateTime nthSunday(int year, int month, int n) {
    final first = DateTime.utc(year, month, 1);
    final firstSun = 1 + (7 - first.weekday % 7) % 7;
    return DateTime.utc(year, month, firstSun + 7 * (n - 1), 2);
  }
  final w = DateTime.utc(wall.year, wall.month, wall.day, wall.hour, wall.minute, wall.second);
  final dst = !w.isBefore(nthSunday(wall.year, 3, 2)) && w.isBefore(nthSunday(wall.year, 11, 1));
  return w.add(Duration(hours: dst ? 4 : 5));
}

/// UTC instant -> America/New_York wall-clock time (inverse of [etToUtc]).
DateTime utcToEt(DateTime instant) {
  final u = instant.toUtc();
  final edt = DateTime(u.year, u.month, u.day, u.hour, u.minute, u.second).subtract(const Duration(hours: 4));
  return etToUtc(edt) == DateTime.utc(u.year, u.month, u.day, u.hour, u.minute, u.second) ? edt : edt.subtract(const Duration(hours: 1));
}

/// The New York calendar day of a transaction (the DB's notion of "day").
DateTime etDay(DateTime instant) { final w = utcToEt(instant); return DateTime(w.year, w.month, w.day); }
