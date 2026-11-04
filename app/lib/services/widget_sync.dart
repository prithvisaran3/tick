import 'dart:convert';
import 'package:home_widget/home_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import '../domain/models.dart';
import '../domain/payday.dart';
import '../domain/safe_to_spend.dart';

const appGroupId = 'group.com.prithvi.tick';

/// Snapshot JSON read by the WidgetKit extension. Pure builder + thin writer.
Map<String, dynamic> buildWidgetSnapshot({required SafeToSpend? sts, required List<Txn> txns, required List<Recurring> recurring, required DateTime now}) {
  final today = dayOnly(now);
  final spent = txns.where((t) => t.amountCents < 0 && dayOnly(t.occurredAt) == today).fold<int>(0, (s, t) => s - t.amountCents);
  final upcoming = recurring.where((r) => !r.nextDate.isBefore(today)).toList()..sort((a, b) => a.nextDate.compareTo(b.nextDate));
  final bill = upcoming.isEmpty ? null : upcoming.first;
  final diff = bill == null ? 0 : dayOnly(bill.nextDate).difference(today).inDays;
  return {
    'safeCents': sts?.cents ?? 0,
    'until': sts == null ? 'payday' : DateFormat('EEEE').format(sts.nextPayday),
    'spentTodayCents': spent,
    'nextBillName': bill?.merchant,
    'nextBillCents': bill?.expectedCents,
    'nextBillDay': bill == null ? null : (diff == 0 ? 'today' : diff == 1 ? 'tomorrow' : DateFormat('EEE MMM d').format(bill.nextDate)),
    'hasData': sts != null,
  };
}

Future<void> writeWidgetSnapshot(Map<String, dynamic> snap) async {
  try {
    await HomeWidget.setAppGroupId(appGroupId);
    await HomeWidget.saveWidgetData<String>('snapshot', jsonEncode(snap));
    await HomeWidget.updateWidget(iOSName: 'TickWidget');
  } catch (_) {/* widgets are optional */}
}

/// "Log expense" App Intent drops {amount, merchant, category} into the app's own UserDefaults (key "flutter.pendingAdd", the same
/// store shared_preferences uses), so it needs no App Group and works with a free Apple account. The app opens quick add with it.
Future<Map<String, dynamic>?> takePendingAdd() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();                                            // pick up what native code wrote
    final raw = prefs.getString('pendingAdd');
    if (raw == null || raw.isEmpty) return null;
    await prefs.remove('pendingAdd');
    return jsonDecode(raw) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}
