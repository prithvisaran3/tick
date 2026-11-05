import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/settings.dart';
import '../domain/money.dart';

/// Native privacy helpers (ios/Runner/TickPrivacy.swift). Every call soft-fails: no channel (tests, older builds) means no-op.
class Privacy {
  static const _ch = MethodChannel('tick/privacy');

  /// File protection "complete" + excluded from iCloud and device backups.
  static Future<void> protect(List<String> paths) async {
    try { await _ch.invokeMethod<int>('protect', {'paths': paths}); } catch (_) {}
  }

  static Future<bool> isCaptured() async {
    try { return await _ch.invokeMethod<bool>('isCaptured') ?? false; } catch (_) { return false; }
  }
}

/// True while the screen is being recorded, mirrored or AirPlayed.
class ScreenCaptured extends Notifier<bool> {
  @override
  bool build() {
    try {
      Privacy._ch.setMethodCallHandler((call) async {
        if (call.method == 'captured') state = call.arguments == true;
      });
    } catch (_) {}
    Privacy.isCaptured().then((v) { if (v != state) state = v; });
    return false;
  }
  void set(bool v) => state = v;
}
final screenCapturedProvider = NotifierProvider<ScreenCaptured, bool>(ScreenCaptured.new);

/// Amounts are hidden when the person asked for it, or while the screen is being captured.
final amountsHiddenProvider = Provider<bool>((ref) => ref.watch(settingsProvider.select((s) => s.hideAmounts)) || ref.watch(screenCapturedProvider));

/// Applies [hidden] to the formatter and rebuilds every widget once, so no stale amount stays on screen.
void applyMoneyMask(BuildContext context, bool hidden) {
  if (MoneyMask.hidden == hidden) return;
  MoneyMask.hidden = hidden;
  void mark(Element e) { e.markNeedsBuild(); e.visitChildren(mark); }
  (context as Element).visitChildren(mark);
}
