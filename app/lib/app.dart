import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'data/settings.dart';
import 'design/theme.dart';
import 'data/env.dart';
import 'router.dart';
import 'services/haptics.dart';
import 'services/session.dart';
import 'services/lock.dart';
import 'services/privacy.dart';
import 'domain/money.dart';

class TickApp extends ConsumerStatefulWidget {
  const TickApp({super.key});
  @override
  ConsumerState<TickApp> createState() => _TickAppState();
}

class _TickAppState extends ConsumerState<TickApp> {
  late final GoRouter _router = buildRouter(ref);

  @override
  void initState() {
    super.initState();
    // Defer everything non-essential until the first frame is on screen.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(bootstrapProvider);                                // starts Supabase
      Future<void>.delayed(const Duration(milliseconds: 400), TickHaptics.instance.prepare);
    });
  }
  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    ref.listen<bool>(amountsHiddenProvider, (_, hidden) => applyMoneyMask(context, hidden));
    MoneyMask.hidden = ref.watch(amountsHiddenProvider);
    final platformDark = MediaQuery.maybePlatformBrightnessOf(context) != Brightness.light;
    final dark = switch (s.theme) { 'dark' => true, 'light' => false, _ => platformDark };
    return TickTheme(
      dark: dark,
      child: WidgetsApp.router(
        title: 'Tick',
        color: dark ? const Color(0xFF0E0E12) : const Color(0xFFF5F3EC),
        routerConfig: _router,
        debugShowCheckedModeBanner: false,
        showPerformanceOverlay: Env.perfOverlay,
        builder: (context, child) => DefaultTextStyle(
          style: TextStyle(fontFamily: 'Satoshi', color: dark ? tickDarkColorsText : tickLightColorsText, fontSize: 15, decoration: TextDecoration.none),
          child: AppLock(child: child ?? const SizedBox()),
        ),
      ),
    );
  }
}

const tickDarkColorsText = Color(0xFFF5F3EC);
const tickLightColorsText = Color(0xFF0E0E12);
