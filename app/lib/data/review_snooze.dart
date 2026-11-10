import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'ledger.dart';
import 'settings.dart';

/// "Not sure" on a Yes/No question. Kept on this phone only and never sent anywhere, so it can't train a rule.
/// First Not sure: hidden for 7 days, then back once as "Still unsure?". Second Not sure: gone for good.
class Snooze {
  const Snooze(this.untilMs, this.times);
  final int untilMs;
  final int times;
  Map<String, dynamic> toJson() => {'u': untilMs, 't': times};
}

const snoozeDays = 7;
const _key = 'review_snoozes_v1';

class ReviewSnoozes extends Notifier<Map<String, Snooze>> {
  @override
  Map<String, Snooze> build() {
    final raw = ref.read(sharedPrefsProvider)?.getString(_key);
    if (raw == null) return const {};
    try {
      final j = (jsonDecode(raw) as Map).cast<String, dynamic>();
      return {for (final e in j.entries) e.key: Snooze(((e.value as Map)['u'] as num).toInt(), ((e.value as Map)['t'] as num).toInt())};
    } catch (_) {
      return const {};
    }
  }

  void notSure(String key) {
    final now = ref.read(clockProvider)();
    final times = (state[key]?.times ?? 0) + 1;
    state = {...state, key: Snooze(now.add(const Duration(days: snoozeDays)).millisecondsSinceEpoch, times)};
    ref.read(sharedPrefsProvider)?.setString(_key, jsonEncode({for (final e in state.entries) e.key: e.value.toJson()}));
  }

  /// Undo for the toast.
  void restore(String key, Snooze? before) {
    final next = {...state}..remove(key);
    if (before != null) next[key] = before;
    state = next;
    ref.read(sharedPrefsProvider)?.setString(_key, jsonEncode({for (final e in state.entries) e.key: e.value.toJson()}));
  }
}

final reviewSnoozesProvider = NotifierProvider<ReviewSnoozes, Map<String, Snooze>>(ReviewSnoozes.new);

/// Hidden, back as "Still unsure?", or never snoozed.
enum SnoozeState { fresh, hidden, stillUnsure }

SnoozeState snoozeState(Snooze? s, DateTime now) {
  if (s == null) return SnoozeState.fresh;
  if (s.times >= 2 || now.millisecondsSinceEpoch < s.untilMs) return SnoozeState.hidden;
  return SnoozeState.stillUnsure;
}
