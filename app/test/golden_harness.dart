import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tick/data/ledger.dart';
import 'package:tick/data/settings.dart';
import 'package:tick/design/theme.dart';
import 'package:tick/design/tokens.g.dart';
import 'package:tick/design/widgets/more.dart';
import 'package:tick/services/haptics.dart';

final fixedNow = DateTime(2026, 11, 4, 9, 41);

Future<void> loadFonts() async {
  Future<void> load(String family, List<String> files) async {
    final l = FontLoader(family);
    for (final f in files) {
      l.addFont(Future.value(ByteData.sublistView(File('assets/fonts/$f').readAsBytesSync())));
    }
    await l.load();
  }
  await load('CabinetGrotesk', ['CabinetGrotesk-Medium.ttf', 'CabinetGrotesk-Bold.ttf', 'CabinetGrotesk-Extrabold.ttf', 'CabinetGrotesk-Black.ttf']);
  await load('Satoshi', ['Satoshi-Regular.ttf', 'Satoshi-Medium.ttf', 'Satoshi-Bold.ttf', 'Satoshi-Black.ttf']);
  await load('GeistMono', ['GeistMono-Variable.ttf']);
}

Future<ProviderContainer> demoContainer({bool demo = true, List<Override> overrides = const [], DateTime? now}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  TickHaptics.instance.recordOnly = true;
  final c = ProviderContainer(overrides: [sharedPrefsProvider.overrideWithValue(prefs), clockProvider.overrideWithValue(() => now ?? fixedNow), ...overrides]);
  c.read(settingsProvider.notifier).update((s) => s.copyWith(demoMode: demo, onboardingDone: true, name: 'Prithvi'));
  return c;
}

/// Renders [child] at 393x852 (@2x) inside the Tick theme with a faked status-bar inset.
Widget frame(ProviderContainer c, Widget child, {required bool dark, int? tab}) {
  return UncontrolledProviderScope(
    container: c,
    child: TickTheme(
      dark: dark,
      child: WidgetsApp(
        color: const Color(0xFF000000), debugShowCheckedModeBanner: false,
        pageRouteBuilder: <T>(settings, builder) => PageRouteBuilder<T>(settings: settings, pageBuilder: (ctx, _, _) => builder(ctx)),
        builder: (context, _) => MediaQuery(
          data: MediaQuery.of(context).copyWith(padding: const EdgeInsets.only(top: 54, bottom: 34)),
          child: DefaultTextStyle(
            style: TextStyle(fontFamily: 'Satoshi', color: dark ? const Color(0xFFF5F3EC) : const Color(0xFF0E0E12), decoration: TextDecoration.none),
            child: tab == null
                ? child
                : ColoredBox(color: dark ? tickDarkColors.bg : tickLightColors.bg, child: Stack(clipBehavior: Clip.none, children: [
                    Positioned.fill(child: child),
                    Positioned(left: 0, right: 0, bottom: 0, child: TickTabBar(index: tab, onTap: (_) {}, onAdd: () {})),
                  ])),
          ),
        ),
        home: const SizedBox(),
      ),
    ),
  );
}

Future<void> pumpGolden(WidgetTester tester, Widget w, {double width = 393, double height = 852}) async {
  tester.view.physicalSize = Size(width * 2, height * 2);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(w);
  for (var i = 0; i < 60; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
