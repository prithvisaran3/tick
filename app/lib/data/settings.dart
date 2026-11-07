import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../domain/models.dart';
import '../services/haptics.dart';
import '../services/session.dart';
import 'remote.dart';

/// Demo data exists for tests and local development only. A compile-time constant: release builds can't turn it on, whatever is saved on the phone.
const demoAllowed = !kReleaseMode;

/// Labs: shipped ideas from docs/IDEAS_ARCHIVE.md, each switchable in Settings. (id, title, one-line description)
const featureFlags = <(String, String, String)>[
  ('card_guard', 'Card-due guard', 'Warns when checking can\'t cover the card bills due before payday.'),
  ('truly_free', 'Truly free', 'Shows what is left after every card balance, not only what is due.'),
  ('statement_cycle', 'Statement cycle', 'Per card: when the statement closes, pay-in-full countdown, and a utilisation heads-up.'),
  ('what_if', 'What if', 'Try an amount before you buy: see what is left until payday.'),
];

final sharedPrefsProvider = Provider<SharedPreferences?>((ref) => null);

class AppSettings {
  const AppSettings({
    this.haptics = HapticMode.full, this.sound = true, this.theme = 'system', this.faceIdLock = false, this.privacyBlur = true,
    this._demoMode = false, this.onboardingDone = false, this.rule, this.morningTime = '08:00', this.weeklyTime = '19:00',
    this.lastMorningReceipt, this.name, this.flagsOff = const {}, this.hideAmounts = false, this.lockAfterSeconds = 60, this.includeFriends = false,
  });
  /// Insights: count Friends and family in spending and income. Saved per user in the database, where the money rules read it; this is the local copy.
  final bool includeFriends;
  /// Feature flags that are switched OFF (everything in [featureFlags] is on by default). Settings > Labs.
  final Set<String> flagsOff;
  /// Quick privacy: amounts show as •••• until tapped off (Settings, or long-press the hero).
  final bool hideAmounts;
  /// Face ID lock: ask again after the app has been in the background this long (0 = every time).
  final int lockAfterSeconds;
  bool flag(String f) => !flagsOff.contains(f);
  final HapticMode haptics;
  final bool sound;
  final String theme; // system | dark | light
  final bool faceIdLock;
  final bool privacyBlur;
  final bool _demoMode;
  bool get demoMode => demoAllowed && _demoMode;
  final bool onboardingDone;
  final PaydayRule? rule;
  final String morningTime;
  final String weeklyTime;
  final String? lastMorningReceipt; // yyyy-mm-dd of the last Morning Receipt shown
  final String? name;

  AppSettings copyWith({HapticMode? haptics, bool? sound, String? theme, bool? faceIdLock, bool? privacyBlur, bool? demoMode, bool? onboardingDone, PaydayRule? rule, String? morningTime, String? weeklyTime, String? lastMorningReceipt, String? name, Set<String>? flagsOff, bool? hideAmounts, int? lockAfterSeconds, bool? includeFriends}) => AppSettings(
        haptics: haptics ?? this.haptics, sound: sound ?? this.sound, theme: theme ?? this.theme, faceIdLock: faceIdLock ?? this.faceIdLock,
        privacyBlur: privacyBlur ?? this.privacyBlur, demoMode: demoMode ?? this.demoMode, onboardingDone: onboardingDone ?? this.onboardingDone,
        rule: rule ?? this.rule, morningTime: morningTime ?? this.morningTime, weeklyTime: weeklyTime ?? this.weeklyTime,
        lastMorningReceipt: lastMorningReceipt ?? this.lastMorningReceipt, name: name ?? this.name, flagsOff: flagsOff ?? this.flagsOff,
        hideAmounts: hideAmounts ?? this.hideAmounts, lockAfterSeconds: lockAfterSeconds ?? this.lockAfterSeconds, includeFriends: includeFriends ?? this.includeFriends);

  Map<String, dynamic> toJson() => {
        'haptics': haptics.name, 'sound': sound, 'theme': theme, 'faceIdLock': faceIdLock, 'privacyBlur': privacyBlur, 'demoMode': demoMode,
        'onboardingDone': onboardingDone, 'morningTime': morningTime, 'weeklyTime': weeklyTime, 'lastMorningReceipt': lastMorningReceipt, 'name': name,
        'flagsOff': flagsOff.toList(), 'hideAmounts': hideAmounts, 'lockAfterSeconds': lockAfterSeconds, 'includeFriends': includeFriends,
        if (rule != null) 'rule': {'f': rule!.frequency.name, 'a': rule!.anchor.toIso8601String(), 'c': rule!.amountCents, 'd': rule!.days},
      };
  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        haptics: HapticMode.values.firstWhere((m) => m.name == j['haptics'], orElse: () => HapticMode.full),
        sound: (j['sound'] ?? true) as bool, theme: (j['theme'] ?? 'system') as String, faceIdLock: (j['faceIdLock'] ?? false) as bool,
        privacyBlur: (j['privacyBlur'] ?? true) as bool, demoMode: (j['demoMode'] ?? false) as bool, onboardingDone: (j['onboardingDone'] ?? false) as bool && !(j['demoMode'] == true && !demoAllowed),   // someone who only ever saw demo data starts over
        morningTime: (j['morningTime'] ?? '08:00') as String, weeklyTime: (j['weeklyTime'] ?? '19:00') as String,
        lastMorningReceipt: j['lastMorningReceipt'] as String?, name: j['name'] as String?,
        flagsOff: {...((j['flagsOff'] as List?) ?? const []).whereType<String>()}, hideAmounts: (j['hideAmounts'] ?? false) as bool,
        lockAfterSeconds: (j['lockAfterSeconds'] as num?)?.toInt() ?? 60, includeFriends: (j['includeFriends'] ?? false) as bool,
        rule: j['rule'] == null ? null : PaydayRule(
            frequency: PayFrequency.values.firstWhere((f) => f.name == (j['rule'] as Map)['f'], orElse: () => PayFrequency.biweekly), anchor: DateTime.parse((j['rule'] as Map)['a'] as String), amountCents: ((j['rule'] as Map)['c'] as num).toInt(), days: ((j['rule'] as Map)['d'] as List?)?.cast<int>()),
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
    // Demo data never shows for a signed-in person.
    if (s.demoMode && ref.read(userIdProvider) != null) s = s.copyWith(demoMode: false);
    ref.listen(userIdProvider, (_, uid) { if (uid != null && state.demoMode) update((x) => x.copyWith(demoMode: false)); });
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
      remote?.savePaydayRule({'frequency': r.frequency.name, 'next_date': r.anchor.toIso8601String().substring(0, 10), 'amount_cents': r.amountCents, 'days': ?r.days}).catchError((_) {});   // best effort
    }
  }

  /// The money rules run in SQL, so the database is written first; a failure leaves the toggle where it was.
  Future<void> setIncludeFriends(bool v) async {
    if (!state.demoMode) await ref.read(remoteProvider)?.saveIncludeFriends(v);
    update((s) => s.copyWith(includeFriends: v));
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);
