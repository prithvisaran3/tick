import 'dart:async';
import 'dart:developer' as dev;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';

/// Global error handling: nothing may ever show a red or grey error screen, and nothing sensitive is logged.
/// Errors are kept in memory (last 20, type + short message only) for the debug gallery; release builds log nothing.
class AppErrors {
  static final List<String> recent = [];

  static void record(Object error, StackTrace? stack, {String where = ''}) {
    final line = '${DateTime.now().toIso8601String()} $where ${error.runtimeType}';
    recent.add(line);
    if (recent.length > 20) recent.removeAt(0);
    if (kDebugMode) dev.log(line, name: 'tick', error: error.runtimeType, stackTrace: stack);   // type only: messages can carry user data
  }

  static void install() {
    FlutterError.onError = (details) {
      record(details.exception, details.stack, where: 'flutter');
      if (kDebugMode) FlutterError.dumpErrorToConsole(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      record(error, stack, where: 'platform');
      return true;                                                  // handled: don't crash the app
    };
    ErrorWidget.builder = (details) => const CalmErrorBox();
  }

  static Future<void> guarded(Future<void> Function() body) async {
    await runZonedGuarded(body, (e, s) => record(e, s, where: 'zone'));
  }
}

/// Replaces Flutter's red/grey error box in any subtree that fails to build. Static colors: it may render without a theme.
class CalmErrorBox extends StatelessWidget {
  const CalmErrorBox({super.key});
  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: TextDirection.ltr,
        child: Container(
          padding: const EdgeInsets.all(16), alignment: Alignment.center,
          decoration: BoxDecoration(color: TickPalette.ink2, borderRadius: BorderRadius.circular(TickRadius.card)),
          child: Text('That didn\'t load. Pull to refresh, nothing was lost.', textAlign: TextAlign.center, style: tickTextStyle(TickType.bodyS, TickPalette.mist)),
        ),
      );
}
