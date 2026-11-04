import 'package:flutter/widgets.dart';
import 'tokens.g.dart';

enum TickThemeMode { system, dark, light }

/// Provides the active [TickColors]. No Material anywhere.
class TickTheme extends InheritedWidget {
  const TickTheme({super.key, required this.dark, required super.child});
  final bool dark;
  TickColors get colors => dark ? tickDarkColors : tickLightColors;
  static TickTheme of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<TickTheme>()!;
  @override
  bool updateShouldNotify(TickTheme old) => old.dark != dark;
}

extension TickContext on BuildContext {
  TickColors get c => TickTheme.of(this).colors;
  bool get isDark => TickTheme.of(this).dark;
  bool get reduceMotion => MediaQuery.maybeOf(this)?.disableAnimations ?? false;

  /// Text style from the generated type scale. Numbers always get tabular figures.
  TextStyle ts(TickTypeSpec s, {Color? color, double? size}) => tickTextStyle(s, color ?? c.text, size: size);
}

TextStyle tickTextStyle(TickTypeSpec s, Color color, {double? size}) {
  final mono = s.family == TickFamilies.mono;
  return TextStyle(
    fontFamily: s.family,
    fontSize: size ?? s.size,
    fontWeight: FontWeight.values[((s.weight ~/ 100) - 1).clamp(0, 8)],
    fontVariations: mono ? [FontVariation('wght', s.weight.toDouble())] : null,
    height: s.height,
    letterSpacing: s.tracking,
    color: color,
    fontFeatures: const [FontFeature.tabularFigures()],
    decoration: TextDecoration.none,
  );
}

/// Category tints for monogram avatars (bg, fg), per brightness.
(Color, Color) categoryTint(String key, bool dark) {
  const d = {
    'food': (Color(0x2EFFB84D), Color(0xFFFFB84D)),
    'ride': (Color(0x2E7AA7FF), Color(0xFF7AA7FF)),
    'sub': (Color(0x2EC8A0FF), Color(0xFFC8A0FF)),
    'home': (Color(0x29FF6B4A), Color(0xFFFF8A6E)),
    'biz': (Color(0x29A3A3AF), Color(0xFFA3A3AF)),
    'inc': (Color(0x2E7AA7FF), Color(0xFF7AA7FF)),
    'shop': (Color(0x29FF8CC8), Color(0xFFFF8CC8)),
  };
  const l = {
    'food': (Color(0xFFF7E3C4), Color(0xFF8A5200)),
    'ride': (Color(0xFFD9E3FA), Color(0xFF2A57C0)),
    'sub': (Color(0xFFE8DDF8), Color(0xFF6A3DB8)),
    'home': (Color(0xFFF6DCD3), Color(0xFFB8381A)),
    'biz': (Color(0xFFE6E4DC), Color(0xFF3A3A44)),
    'inc': (Color(0xFFD9E3FA), Color(0xFF2A57C0)),
    'shop': (Color(0xFFF6D8E8), Color(0xFF9A2F68)),
  };
  return (dark ? d : l)[key] ?? (dark ? d : l)['shop']!;
}
