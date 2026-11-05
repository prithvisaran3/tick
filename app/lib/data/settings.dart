import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../domain/models.dart';
import '../services/haptics.dart';
import 'remote.dart';

final sharedPrefsProvider = Provider<SharedPreferences?>((ref) => null);

class AppSettings {
  const AppSettings({
    this.haptics = HapticMode.full, this.sound = true, this.theme = 'system', this.faceIdLock = false, this.privacyBlur = true,
    this.demoMode = false, this.onboardingDone = false, this.rule, this.morningTime = '08:00', this.weeklyTime = '19:00',
    this.lastMorningReceipt, this.name,
  });
  final HapticMode haptics;
  final bool sound;
  final String theme; // system | dark | light
  final bool faceIdLock;
  final bool privacyBlur;
  final bool demoMode;
  final bool onboardingDone;
  final PaydayRule? rule;
  final String morningTime;
  final String weeklyTime;
  final String? lastMorningReceipt; // yyyy-mm-dd of the last Morning Receipt shown
  final String? name;

  AppSettings copyWith({HapticMode? haptics, bool? sound, String? theme, bool? faceIdLock, bool? privacyBlur, bool? demoMode, bool? onboardingDone, PaydayRule? rule, String? morningTime, String? weeklyTime, String? lastMorningReceipt, String? name}) => AppSettings(
        haptics: haptics ?? this.haptics, sound: sound ?? this.sound, theme: theme ?? this.theme, faceIdLock: faceIdLock ?? this.faceIdLock,
        privacyBlur: privacyBlur ?? this.privacyBlur, demoMode: demoMode ?? this.demoMode, onboardingDone: onboardingDone ?? this.onboardingDone,
        rule: rule ?? this.rule, morningTime: morningTime ?? this.morningTime, weeklyTime: weeklyTime ?? this.weeklyTime,
        lastMorningReceipt: lastMorningReceipt ?? this.lastMorningReceipt, name: name ?? this.name);

  Map<String, dynamic> toJson() => {
        'haptics': haptics.name, 'sound': sound, 'theme': theme, 'faceIdLock': faceIdLock, 'privacyBlur': privacyBlur, 'demoMode': demoMode,
        'onboardingDone': onboardingDone, 'morningTime': morningTime, 'weeklyTime': weeklyTime, 'lastMorningReceipt': lastMorningReceipt, 'name': name,
        if (rule != null) 'rule': {'f': rule!.frequency.name, 'a': rule!.anchor.toIso8601String(), 'c': rule!.amountCents},
      };
  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        haptics: HapticMode.values.firstWhere((m) => m.name == j['haptics'], orElse: () => HapticMode.full),
        sound: (j['sound'] ?? true) as bool, theme: (j['theme'] ?? 'system') as String, faceIdLock: (j['faceIdLock'] ?? false) as bool,
        privacyBlur: (j['privacyBlur'] ?? true) as bool, demoMode: (j['demoMode'] ?? false) as bool, onboardingDone: (j['onboardingDone'] ?? false) as bool,
        morningTime: (j['morningTime'] ?? '08:00') as String, weeklyTime: (j['weeklyTime'] ?? '19:00') as String,
        lastMorningReceipt: j['lastMorningReceipt'] as String?, name: j['name'] as String?,
        rule: j['rule'] == null ? null : PaydayRule(
            frequency: PayFrequency.values.firstWhere((f) => f.name == (j['rule'] as Map)['f'], orElse: () => PayFrequency.biweekly), anchor: DateTime.parse((j['rule'] as Map)['a'] as String), amountCents: ((j['rule'] as Map)['c'] as num).toInt()),
      );
}

class SettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() {
    final p = ref.read(sharedPrefsProvider);
    final raw = p?.getString('tick.settings');
    var s = const AppSettings();
    if (raw != null) {
      try {
        s = AppSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      } catch (_) {
        p?.remove('tick.settings');                                  // corrupt settings must never stop the app from launching
      }
    }
    TickHaptics.instance.setMode(s.haptics);
    TickHaptics.instance.setSound(s.sound);
    return s;
  }

  void update(AppSettings Function(AppSettings) f) {
    final old = state;
    final n = f(state);
    if (n.haptics != state.haptics) TickHaptics.instance.setMode(n.haptics);
    if (n.sound != state.sound) TickHaptics.instance.setSound(n.sound);
    state = n;
    ref.read(sharedPrefsProvider)?.setString('tick.settings', jsonEncode(n.toJson()));
    if (n.rule != null && n.rule != old.rule && !n.demoMode) {
      final remote = ref.read(remoteProvider);
      final r = n.rule!;
      remote?.savePaydayRule({'frequency': r.frequency.name, 'next_date': r.anchor.toIso8601String().substring(0, 10), 'amount_cents': r.amountCents}).catchError((_) {});   // best effort
    }
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);
