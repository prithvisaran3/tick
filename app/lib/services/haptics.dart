import 'dart:async';
import 'package:flutter/services.dart';

enum HapticMode { full, subtle, off }

/// The one Dart API for Tick's haptic language (design/haptics.json).
/// Patterns: pop, priceWeight(tier), countUp, holdRamp/holdClick/holdCancel, sortRight/Left/Up, landed, tearTick/tearRip, heartbeat.
class TickHaptics {
  TickHaptics._();
  static final TickHaptics instance = TickHaptics._();
  static const _ch = MethodChannel('tick/haptics');

  /// Recorded calls (pattern names) so tests can audit that haptics fire with their animation.
  final List<String> log = [];
  bool recordOnly = false; // true in tests/gallery without a device
  HapticMode _mode = HapticMode.full;
  bool _sound = true;
  HapticMode get mode => _mode;

  Future<void> _invoke(String m, [Map<String, Object?>? args]) async {
    if (recordOnly) return;
    try {
      await _ch.invokeMethod<void>(m, args);
    } on MissingPluginException {
      // Not on iOS (tests, simulator without the plugin): Tick works fine without haptics.
    } on PlatformException {
      // Never let a haptic failure surface to the user.
    }
  }

  Future<void> prepare() => _invoke('prepare');
  Future<void> setMode(HapticMode m) async {
    _mode = m;
    await _invoke('setMode', {'mode': m.name});
  }

  Future<void> setSound(bool on) async {
    _sound = on;
    await _invoke('setSound', {'on': on});
  }

  /// [pattern] is a manifest key such as 'pop', 'price_weight', 'sort'. [tier] picks the variant (low|mid|high, right|left|up, ramp|click|cancel, tick|rip).
  Future<void> play(String pattern, {String? tier}) {
    final key = tier == null ? pattern : '${pattern}_$tier';
    log.add(key);
    if (_mode == HapticMode.off) return Future.value();
    return _invoke('play', {'asset': 'assets/haptics/$key.ahap'});
  }

  Future<void> sound(String name) {
    log.add('sound:$name');
    if (!_sound) return Future.value();
    return _invoke('playSound', {'asset': 'assets/sounds/$name.caf'});
  }

  // Meaningful moments (one pattern, one meaning).
  Future<void> pop() => play('pop');
  Future<void> priceWeight(int cents) => play('price_weight', tier: cents.abs() < 2000 ? 'low' : cents.abs() < 10000 ? 'mid' : 'high');
  Future<void> countUp() => play('count_up');
  Future<void> holdRamp() => play('hold', tier: 'ramp');
  Future<void> holdClick() => play('hold', tier: 'click');
  Future<void> holdCancel() => play('hold', tier: 'cancel');
  Future<void> sortRight() => play('sort', tier: 'right');
  Future<void> sortLeft() => play('sort', tier: 'left');
  Future<void> sortUp() => play('sort', tier: 'up');
  Future<void> landed() async {
    unawaited(sound('landed_chime'));
    return play('landed');
  }
  Future<void> receiptTick() => play('tear', tier: 'tick');
  Future<void> receiptRip() => play('tear', tier: 'rip');
  Future<void> heartbeat() => play('heartbeat');
  Future<void> capturePop(int cents) async {
    unawaited(sound('capture_pop'));
    return priceWeight(cents);
  }

  // Everyday interactions mapped onto the language (docs/DECISIONS.md "Haptic map"). Silent when Haptics is Off, and light by design.
  /// Selection tick: a chip, a toggle, a segment, crossing into another month while scrolling.
  Future<void> selection() {
    log.add('selection');
    if (_mode == HapticMode.off || recordOnly) return Future.value();
    return HapticFeedback.selectionClick();
  }
  /// Confirm: a sheet applied, a swipe action committed (the two-tick "looks right").
  Future<void> confirm() => sortRight();
  /// Success: an import finished, a send went through (price-weight, mid).
  Future<void> success() => play('price_weight', tier: 'mid');

  /// Errors use the standard system warning, never a custom pattern.
  Future<void> warning() => HapticFeedback.heavyImpact();
}
