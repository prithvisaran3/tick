import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/flows.dart';
import 'activity.dart';
import 'ledger.dart';
import 'settings.dart';
import '../domain/dates.dart';

class InsightsData {
  const InsightsData({required this.now, required this.cur, required this.prevSame, required this.prevFull, required this.merchants});
  final DateTime now;
  final Totals cur; // this month so far
  final Totals prevSame; // last month, same number of days
  final Totals prevFull; // all of last month
  final List<MerchantTotal> merchants;

  int get day => now.day;
  int get daysInThisMonth => DateTime(now.year, now.month + 1, 0).day;
  /// Spending change vs the same days last month, as a fraction (null without a baseline).
  double? get vsLast => prevSame.outCents == 0 ? null : (cur.outCents - prevSame.outCents) / prevSame.outCents;
  /// Straight-line projection for the month (null in the first days, when it would be noise).
  int? get projectedCents => day < 5 || cur.outCents == 0 ? null : (cur.outCents / day * daysInThisMonth).round();
  /// Categories sorted by this month's spending, each with last month's same-period amount.
  List<(String, int, int)> get categories {
    final ids = {...cur.byCategory.keys, ...prevSame.byCategory.keys};
    final rows = [for (final id in ids) (id, cur.byCategory[id] ?? 0, prevSame.byCategory[id] ?? 0)].where((r) => r.$2 > 0 || r.$3 > 0).toList()..sort((a, b) => b.$2.compareTo(a.$2));
    return rows;
  }
}

/// Everything Insights shows, from the SAME money rules as the rest of Tick (SQL in live mode): transfers excluded, cards included.
final insightsProvider = FutureProvider<InsightsData>((ref) async {
  ref.watch(ledgerRevisionProvider);
  final src = ref.watch(activitySourceProvider);
  final now = ref.read(clockProvider)();
  final m = monthOf(now);
  final prev = DateTime(m.year, m.month - 1, 1);
  const none = ActivityQuery();
  final bounds = (etToUtc(m), etToUtc(DateTime(m.year, m.month + 1, 1)));
  final r = await Future.wait([
    src.totals(none, from: bounds.$1, to: bounds.$2),
    src.totals(none, from: etToUtc(prev), to: etToUtc(addDays(prev, now.day))),
    src.totals(none, from: etToUtc(prev), to: etToUtc(m)),
    src.topMerchants(bounds.$1, bounds.$2, limit: 6),
  ]);
  final cur = r[0] as Totals;
  if (cur.friendsIncluded != ref.read(settingsProvider).includeFriends) {       // another device changed it: the database wins
    ref.read(settingsProvider.notifier).update((s) => s.copyWith(includeFriends: cur.friendsIncluded));
  }
  return InsightsData(now: now, cur: r[0] as Totals, prevSame: r[1] as Totals, prevFull: r[2] as Totals, merchants: r[3] as List<MerchantTotal>);
});
