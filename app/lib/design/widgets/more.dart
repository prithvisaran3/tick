import 'dart:async';
import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';
import '../motion.g.dart';
import '../theme.dart';
import '../tokens.g.dart';
import '../../services/haptics.dart';
import 'core.dart';

/// Press and hold ~600 ms to confirm. Fires HOLD ramp while held, a click on completion, a soft cancel if released early.
class HoldToConfirm extends StatefulWidget {
  const HoldToConfirm({super.key, required this.label, required this.onConfirmed, this.danger = false, this.holdMs = 600});
  final String label;
  final VoidCallback onConfirmed;
  final bool danger;
  final int holdMs;
  @override
  State<HoldToConfirm> createState() => _HoldToConfirmState();
}

class _HoldToConfirmState extends State<HoldToConfirm> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: Duration(milliseconds: widget.holdMs));
  @override
  void initState() {
    super.initState();
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed) {
        TickHaptics.instance.holdClick();
        widget.onConfirmed();
        _c.value = 0;
      }
    });
  }
  @override
  void dispose() { _c.dispose(); super.dispose(); }
  void _down() { TickHaptics.instance.holdRamp(); _c.forward(); }
  void _up() {
    if (_c.status != AnimationStatus.completed && _c.value > 0) {
      TickHaptics.instance.holdCancel();
      _c.animateBack(0, duration: const Duration(milliseconds: 180));
    }
  }
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final fill = widget.danger ? c.alert : c.accent;
    final onFill = widget.danger ? (context.isDark ? TickPalette.ink : TickPalette.white) : c.onAccent;
    return Semantics(
      button: true, label: '${widget.label}. Press and hold to confirm.',
      child: GestureDetector(
        onTapDown: (_) => _down(), onTapUp: (_) => _up(), onTapCancel: _up,
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, _) => Container(
            height: 56, clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(color: c.surface2, borderRadius: BorderRadius.circular(999), border: Border.all(color: c.hairline)),
            child: Stack(alignment: Alignment.center, children: [
              Align(alignment: Alignment.centerLeft, child: FractionallySizedBox(widthFactor: _c.value, child: Container(color: fill))),
              Text(_c.value > 0.5 ? widget.label : 'Hold to ${widget.label.toLowerCase()}',
                  style: TextStyle(fontFamily: TickFamilies.text, fontWeight: FontWeight.w900, fontSize: 17, color: _c.value > 0.5 ? onFill : c.text, decoration: TextDecoration.none)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Custom number pad. Keys: digits, '.', backspace.
class NumberPad extends StatelessWidget {
  const NumberPad({super.key, required this.onKey});
  final ValueChanged<String> onKey; // '0'-'9', '.', '<'
  @override
  Widget build(BuildContext context) {
    const keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '.', '0', '<'];
    return GridView.count(
      crossAxisCount: 3, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), childAspectRatio: 393 / 3 / 52, padding: EdgeInsets.zero,
      children: [
        for (final k in keys)
          Pressable(
            onTap: () => onKey(k), scale: 0.9, semanticLabel: k == '<' ? 'Delete' : (k == '.' ? 'Decimal point' : k),
            child: Center(child: k == '<' ? TickIcon('arrow-in', size: 24, color: context.c.text) : Text(k, style: context.ts(TickType.monoL, size: 26))),
          ),
      ],
    );
  }
}

class TabSpec {
  const TabSpec(this.icon, this.label);
  final String icon;
  final String label;
}

/// Floating pill tab bar with a centre Add button. [index] -1 hides selection.
class TickTabBar extends StatelessWidget {
  const TickTabBar({super.key, required this.index, required this.onTap, required this.onAdd, this.badge = 0});
  final int index;
  final ValueChanged<int> onTap;
  final VoidCallback onAdd;
  final int badge;
  static const tabs = [TabSpec('today', 'Today'), TabSpec('activity', 'Activity'), TabSpec('flows', 'Flows'), TabSpec('ask', 'Ask Tick')];
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    Widget tab(int i) {
      final on = i == index;
      return Expanded(
        child: Pressable(
          onTap: () => onTap(i), semanticLabel: tabs[i].label, scale: 0.92,
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            TickIcon(tabs[i].icon, size: 24, color: on ? c.text : c.textSecondary),
            const SizedBox(height: 3),
            Text(tabs[i].label, style: TextStyle(fontFamily: TickFamilies.text, fontWeight: FontWeight.w700, fontSize: 11, color: on ? c.text : c.textSecondary, decoration: TextDecoration.none)),
            const SizedBox(height: 2),
            Container(width: 5, height: 5, decoration: BoxDecoration(color: on ? (context.isDark ? c.accent : c.text) : const Color(0x00000000), shape: BoxShape.circle)),
          ]),
        ),
      );
    }
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 24), height: 72,
      decoration: BoxDecoration(color: c.surface2, borderRadius: BorderRadius.circular(999), boxShadow: const [BoxShadow(color: Color(0x4D000000), blurRadius: 30, offset: Offset(0, 12), spreadRadius: -12)]),
      child: Row(children: [
        tab(0), tab(1),
        Pressable(
          onTap: onAdd, semanticLabel: 'Add',
          child: Container(width: 56, height: 56, transform: Matrix4.translationValues(0, -8, 0), decoration: BoxDecoration(color: c.accent, shape: BoxShape.circle), alignment: Alignment.center, child: TickIcon('plus', size: 28, color: c.onAccent)),
        ),
        tab(2), tab(3),
      ]),
    );
  }
}

/// Bottom sheet that springs up. Returns when dismissed.
Future<T?> showTickSheet<T>(BuildContext context, {required WidgetBuilder builder, bool full = false}) {
  return Navigator.of(context, rootNavigator: true).push<T>(PageRouteBuilder<T>(
    opaque: false, barrierDismissible: true, barrierColor: const Color(0x99000000), barrierLabel: 'Close',
    transitionDuration: const Duration(milliseconds: 420), reverseTransitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (ctx, a, b) => _SheetHost(full: full, child: builder(ctx)),
    transitionsBuilder: (ctx, a, b, child) {
      if (ctx.reduceMotion) return FadeTransition(opacity: a, child: child);
      final spring = CurvedAnimation(parent: a, curve: const _SpringCurve(), reverseCurve: Curves.easeIn);
      return SlideTransition(position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(spring), child: child);
    },
  ));
}

class _SpringCurve extends Curve {
  const _SpringCurve();
  @override
  double transformInternal(double t) {
    final sim = SpringSimulation(springOf(TickSprings.sheet), 0, 1, 0);
    return sim.x(t * 0.55);
  }
}

class _SheetHost extends StatelessWidget {
  const _SheetHost({required this.child, required this.full});
  final Widget child;
  final bool full;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final mq = MediaQuery.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque, onTap: () => Navigator.of(context).maybePop(),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: GestureDetector(
          onTap: () {},
          child: Container(
            width: double.infinity, constraints: BoxConstraints(maxHeight: mq.size.height * (full ? 0.94 : 0.88)),
            padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + mq.padding.bottom + mq.viewInsets.bottom),
            decoration: BoxDecoration(color: c.bg, borderRadius: const BorderRadius.vertical(top: Radius.circular(TickRadius.sheet))),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 40, height: 5, decoration: BoxDecoration(color: c.hairline, borderRadius: BorderRadius.circular(3))),
              const SizedBox(height: 16),
              Flexible(child: child),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Shared page scaffold: background, status bar inset, optional bottom bar spacing.
class TickScreen extends StatelessWidget {
  const TickScreen({super.key, required this.child, this.bottomPad = 0, this.horizontal = 20});
  final Widget child;
  final double bottomPad;
  final double horizontal;
  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return ColoredBox(
      color: context.c.bg,
      child: Padding(padding: EdgeInsets.fromLTRB(horizontal, mq.padding.top, horizontal, bottomPad), child: child),
    );
  }
}

class ScreenTitle extends StatelessWidget {
  const ScreenTitle(this.title, {super.key, this.trailing, this.onBack});
  final String title;
  final Widget? trailing;
  final VoidCallback? onBack;
  @override
  Widget build(BuildContext context) => SizedBox(
        height: 52,
        child: Row(children: [
          if (onBack != null) Pressable(onTap: onBack, semanticLabel: 'Back', child: Padding(padding: const EdgeInsets.only(right: 8), child: Text('‹', style: context.ts(TickType.displayL)))),
          Expanded(child: Semantics(header: true, child: Text(title, style: context.ts(TickType.displayL)))),
          ?trailing,
        ]),
      );
}

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.color, this.trailing});
  final String text;
  final Color? color;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 8),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Semantics(header: true, child: Text(text, style: TextStyle(fontFamily: TickFamilies.text, fontWeight: FontWeight.w700, fontSize: 13, letterSpacing: 0.2, color: color ?? context.c.textSecondary, decoration: TextDecoration.none))),
          ?trailing,
        ]),
      );
}
