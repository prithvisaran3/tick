import 'dart:math' as math;
import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../motion.g.dart';
import '../theme.dart';
import '../tokens.g.dart';
import '../../services/haptics.dart';

SpringDescription springOf(TickSpringSpec s) => SpringDescription(mass: s.mass, stiffness: s.stiffness, damping: s.damping);

class TickIcon extends StatelessWidget {
  const TickIcon(this.name, {super.key, this.size = 24, this.color});
  final String name;
  final double size;
  final Color? color;
  @override
  Widget build(BuildContext context) => SvgPicture.asset('assets/icons/$name.svg',
      width: size, height: size, colorFilter: ColorFilter.mode(color ?? context.c.text, BlendMode.srcIn), excludeFromSemantics: true);
}

/// Scales down with a spring while pressed.
class Pressable extends StatefulWidget {
  const Pressable({super.key, required this.child, this.onTap, this.semanticLabel, this.scale = 0.96});
  final Widget child;
  final VoidCallback? onTap;
  final String? semanticLabel;
  final double scale;
  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController.unbounded(vsync: this, value: 1);
  void _to(double v) {
    if (context.reduceMotion) { _c.value = v; return; }
    _c.animateWith(SpringSimulation(springOf(TickSprings.pop), _c.value, v, 0));
  }
  @override
  void dispose() { _c.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => Semantics(
        button: true, label: widget.semanticLabel, enabled: widget.onTap != null,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => _to(widget.scale),
          onTapUp: (_) => _to(1),
          onTapCancel: () => _to(1),
          onTap: widget.onTap,
          child: AnimatedBuilder(animation: _c, builder: (_, ch) => Transform.scale(scale: _c.value, child: ch), child: widget.child),
        ),
      );
}

/// Springs a child in from scale/offset with overshoot. Reduce Motion -> 150 ms fade.
class PopIn extends StatefulWidget {
  const PopIn({super.key, required this.child, this.delay = Duration.zero, this.fromScale = 0.6, this.fromOffsetY = 0, this.fromTilt = 0, this.spring, this.onLanded});
  final Widget child;
  final Duration delay;
  final double fromScale;
  final double fromOffsetY;
  final double fromTilt; // radians
  final TickSpringSpec? spring;
  final VoidCallback? onLanded; // fires on the frame the animation starts (haptic/sound sync)
  @override
  State<PopIn> createState() => _PopInState();
}

class _PopInState extends State<PopIn> with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  bool _started = false;
  @override
  void initState() {
    super.initState();
    _c = AnimationController.unbounded(vsync: this, value: 0);      // created here, never lazily in dispose()
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (widget.delay > Duration.zero) await Future<void>.delayed(widget.delay);
      if (!mounted) return;
      _started = true;
      widget.onLanded?.call();
      if (context.reduceMotion) {
        _c.animateTo(1, duration: const Duration(milliseconds: TickMotion.reduceMotionFadeMs), curve: Curves.linear);
      } else {
        _c.animateWith(SpringSimulation(springOf(widget.spring ?? TickSprings.pop), 0, 1, 0));
      }
    });
  }
  @override
  void dispose() { _c.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    final rm = context.reduceMotion;
    return AnimatedBuilder(
      animation: _c,
      builder: (_, ch) {
        final t = _c.value;
        if (rm) return Opacity(opacity: t.clamp(0, 1), child: ch);
        return Opacity(
          opacity: _started ? t.clamp(0.0, 1.0) : 0,
          child: Transform.translate(
            offset: Offset(0, widget.fromOffsetY * (1 - t)),
            child: Transform.rotate(angle: widget.fromTilt * (1 - t), child: Transform.scale(scale: widget.fromScale + (1 - widget.fromScale) * t, child: ch)),
          ),
        );
      },
      child: widget.child,
    );
  }
}

/// The Volt price-tag sticker: hero amounts and new captures only.
class Sticker extends StatelessWidget {
  const Sticker({super.key, required this.child, this.hole = false, this.padding = const EdgeInsets.symmetric(horizontal: 28, vertical: 14), this.tilt = TickMotion.stickerTiltDeg, this.glow = true});
  final Widget child;
  final bool hole;
  final EdgeInsets padding;
  final double tilt; // degrees, negative = counter-clockwise
  final bool glow;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Transform.rotate(
      angle: -tilt * math.pi / 180,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: c.accent,
          borderRadius: BorderRadius.circular(TickRadius.pill),
          border: context.isDark ? null : Border.all(color: TickPalette.ink, width: 2),
          boxShadow: glow ? [BoxShadow(color: context.isDark ? const Color(0x73C8FF2E) : const Color(0x590E0E12), blurRadius: 28, offset: const Offset(0, 10), spreadRadius: -10)] : null,
        ),
        child: Stack(alignment: Alignment.center, children: [
          Padding(padding: padding, child: DefaultTextStyle.merge(style: TextStyle(color: c.onAccent), child: child)),
          if (hole) Positioned(left: 22, child: Container(width: 10, height: 10, decoration: BoxDecoration(color: c.bg, shape: BoxShape.circle))),
        ]),
      ),
    );
  }
}

class TickCard extends StatelessWidget {
  const TickCard({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.raised = false, this.color, this.onTap});
  final Widget child;
  final EdgeInsets padding;
  final bool raised;
  final Color? color;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final w = Container(
      padding: padding,
      decoration: BoxDecoration(color: color ?? (raised ? context.c.surface2 : context.c.surface1), borderRadius: BorderRadius.circular(TickRadius.card)),
      child: child,
    );
    return onTap == null ? w : Pressable(onTap: onTap, scale: 0.985, child: w);
  }
}

class Hairline extends StatelessWidget {
  const Hairline({super.key});
  @override
  Widget build(BuildContext context) => Container(height: 1, color: context.c.hairline);
}

enum PillStyle { primary, ghost, inverse, quiet }

class PillButton extends StatelessWidget {
  const PillButton(this.label, {super.key, this.onTap, this.style = PillStyle.primary, this.icon, this.height = 56, this.expand = true, this.busy = false});
  final bool busy; // in-progress: shows the Tick loader and ignores taps
  final String label;
  final VoidCallback? onTap;
  final PillStyle style;
  final String? icon;
  final double height;
  final bool expand;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final (bg0, fg0, border) = switch (style) {
      PillStyle.primary => (c.accent, c.onAccent, null as Color?),
      PillStyle.inverse => (c.text, c.bg, null),
      PillStyle.ghost => (const Color(0x00000000), c.text, c.hairline),
      PillStyle.quiet => (c.surface2, c.text, null),
    };
    final disabled = onTap == null && !busy;
    final bg = disabled ? c.surface2 : bg0;
    final fg = disabled ? c.textSecondary : fg0;
    return Pressable(
      onTap: busy ? null : onTap, semanticLabel: busy ? '$label, working' : label,
      child: Container(
        height: height, width: expand ? double.infinity : null, padding: expand ? null : const EdgeInsets.symmetric(horizontal: 24),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(TickRadius.pill), border: border == null ? null : Border.all(color: border, width: 1.5)),
        child: busy
            ? Center(child: TickLoader(color: fg))
            : Row(mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
                if (icon != null) ...[TickIcon(icon!, size: 22, color: fg), const SizedBox(width: 8)],
                Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontFamily: TickFamilies.text, fontWeight: FontWeight.w900, fontSize: 17, color: fg, decoration: TextDecoration.none))),
              ]),
      ),
    );
  }
}

class TickChip extends StatelessWidget {
  const TickChip(this.label, {super.key, this.on = false, this.onTap, this.icon});
  final String label;
  final bool on;
  final VoidCallback? onTap;
  final String? icon;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Pressable(
      onTap: onTap, semanticLabel: label,
      child: Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Container(
        height: 36, padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(color: on ? c.text : c.surface1, borderRadius: BorderRadius.circular(999), border: on ? null : Border.all(color: c.hairline)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[TickIcon(icon!, size: 18, color: on ? c.bg : c.text), const SizedBox(width: 6)],
          Text(label, style: TextStyle(fontFamily: TickFamilies.text, fontWeight: FontWeight.w700, fontSize: 13.5, color: on ? c.bg : c.text, decoration: TextDecoration.none)),
        ]),
      )),
    );
  }
}

class Avatar extends StatelessWidget {
  const Avatar(this.letter, this.colorKey, {super.key, this.size = 40});
  final String letter;
  final String colorKey;
  final double size;
  @override
  Widget build(BuildContext context) {
    final (bg, fg) = categoryTint(colorKey, context.isDark);
    return Container(
      width: size, height: size, alignment: Alignment.center,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      child: ExcludeSemantics(child: Text(letter.isEmpty ? '?' : letter.substring(0, 1).toUpperCase(), style: TextStyle(fontFamily: TickFamilies.display, fontWeight: FontWeight.w800, fontSize: size * 0.42, color: fg, decoration: TextDecoration.none))),
    );
  }
}

class Segmented extends StatelessWidget {
  const Segmented({super.key, required this.options, required this.index, required this.onChanged});
  final List<String> options;
  final int index;
  final ValueChanged<int> onChanged;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.all(4), decoration: BoxDecoration(color: c.surface2, borderRadius: BorderRadius.circular(999)),
      child: Row(children: [
        for (var i = 0; i < options.length; i++)
          Expanded(
            child: Pressable(
              onTap: () => onChanged(i), semanticLabel: options[i], scale: 0.97,
              child: Container(
                height: 40, alignment: Alignment.center,
                decoration: BoxDecoration(color: i == index ? c.text : const Color(0x00000000), borderRadius: BorderRadius.circular(999)),
                child: FittedBox(fit: BoxFit.scaleDown, child: Text(options[i], maxLines: 1, style: TextStyle(fontFamily: TickFamilies.text, fontWeight: FontWeight.w700, fontSize: 13.5, color: i == index ? c.bg : c.textSecondary, decoration: TextDecoration.none))),
              ),
            ),
          ),
      ]),
    );
  }
}

class TickToggle extends StatelessWidget {
  const TickToggle({super.key, required this.on, required this.onChanged, this.label});
  final bool on;
  final String? label;
  final ValueChanged<bool> onChanged;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Semantics(
      toggled: on, container: true, label: label, button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onChanged(!on),
        child: SizedBox(width: 56, height: 44, child: Center(child: AnimatedContainer(
          duration: const Duration(milliseconds: 180), curve: Curves.easeOutBack, width: 50, height: 30,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(color: on ? c.accent : c.surface2, borderRadius: BorderRadius.circular(999), border: on ? null : Border.all(color: c.hairline)),
          alignment: on ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(width: 22, height: 22, decoration: BoxDecoration(color: on ? c.onAccent : c.textSecondary, shape: BoxShape.circle)),
        ))),
      ),
    );
  }
}

class Skeleton extends StatefulWidget {
  const Skeleton({super.key, this.width, this.height = 16, this.radius = 8});
  final double? width;
  final double height;
  final double radius;
  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: TickMotion.skeletonShimmerMs));
  bool _started = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (context.reduceMotion) { _c.stop(); _c.value = 0.5; }
    else if (!_started) { _started = true; _c.repeat(reverse: true); }
  }
  @override
  void dispose() { _c.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => Semantics(
        label: 'Loading',
        child: ExcludeSemantics(
          child: RepaintBoundary(
            child: AnimatedBuilder(
              animation: _c,
              builder: (_, _) => Container(
                width: widget.width, height: widget.height,
                decoration: BoxDecoration(color: Color.lerp(context.c.surface1, context.c.surface2, _c.value), borderRadius: BorderRadius.circular(widget.radius)),
              ),
            ),
          ),
        ),
      );
}

/// A hero number that counts up. Haptic COUNT-UP fires on the same frame the animation starts.
class CountUpText extends StatefulWidget {
  const CountUpText({super.key, required this.cents, required this.style, this.duration = const Duration(milliseconds: TickMotion.countUpMs), this.haptic = true, this.format});
  final int cents;
  final TextStyle style;
  final Duration duration;
  final bool haptic;
  final String Function(int cents)? format;
  @override
  State<CountUpText> createState() => _CountUpTextState();
}

class _CountUpTextState extends State<CountUpText> with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: widget.duration);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (context.reduceMotion) { _c.value = 1; return; }
      if (widget.haptic) TickHaptics.instance.countUp();
      _c.animateTo(1, curve: Curves.easeOutCubic);
    });
  }
  @override
  void dispose() { _c.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    final f = widget.format ?? (v) => '\$${(v.abs() ~/ 100).toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',')}';
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) {
        final v = (widget.cents * _c.value).round();
        return Text((widget.cents < 0 ? '−' : '') + f(v), style: widget.style, semanticsLabel: f(widget.cents));
      },
    );
  }
}

/// The logo: lowercase "tick" in Cabinet Grotesk Extrabold with a Volt dot on the i.
class Wordmark extends StatelessWidget {
  const Wordmark({super.key, this.size = 26});
  final double size;
  @override
  Widget build(BuildContext context) {
    final style = tickTextStyle(TickType.displayM, context.c.text, size: size);
    return Semantics(
      label: 'tick', excludeSemantics: true,
      child: Stack(clipBehavior: Clip.none, children: [
        Text('t\u0131ck', style: style),
        Positioned(left: size * 0.455, top: size * 0.14, child: Container(width: size * 0.2, height: size * 0.2, decoration: BoxDecoration(color: TickPalette.volt, shape: BoxShape.circle, border: context.isDark ? null : Border.all(color: TickPalette.ink, width: 1)))),
      ]),
    );
  }
}

/// Three dots that spring up in turn: Tick's in-progress indicator (never a default spinner). Static under Reduce Motion.
class TickLoader extends StatefulWidget {
  const TickLoader({super.key, this.color, this.size = 8});
  final Color? color;
  final double size;
  @override
  State<TickLoader> createState() => _TickLoaderState();
}

class _TickLoaderState extends State<TickLoader> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
  bool _started = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started && !context.reduceMotion) { _started = true; _c.repeat(); }
    if (context.reduceMotion && _c.isAnimating) _c.stop();
  }
  @override
  void dispose() { _c.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? context.c.text;
    return Semantics(
      label: 'Loading', liveRegion: true,
      child: ExcludeSemantics(
        child: RepaintBoundary(
          child: AnimatedBuilder(
            animation: _c,
            builder: (_, _) => Row(mainAxisSize: MainAxisSize.min, children: [
              for (var i = 0; i < 3; i++)
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: widget.size * 0.4),
                  child: Transform.translate(
                    offset: Offset(0, context.reduceMotion ? 0 : -widget.size * 0.9 * math.max(0, math.sin((_c.value * 2 * math.pi) - i * 0.9))),
                    child: Container(width: widget.size, height: widget.size, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// A button that runs an async action: shows progress, blocks double taps, and never throws into the UI.
class ActionButton extends StatefulWidget {
  const ActionButton(this.label, {super.key, required this.onPressed, this.style = PillStyle.primary, this.icon, this.height = 56, this.enabled = true});
  final String label;
  final Future<void> Function() onPressed;
  final PillStyle style;
  final String? icon;
  final double height;
  final bool enabled;
  @override
  State<ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<ActionButton> {
  bool _busy = false;
  Future<void> _run() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onPressed();
    } catch (_) {/* the action reports its own failure; a thrown error must never reach the UI */}
    if (mounted) setState(() => _busy = false);
  }
  @override
  Widget build(BuildContext context) => PillButton(widget.label, style: widget.style, icon: widget.icon, height: widget.height, busy: _busy, onTap: widget.enabled ? _run : null);
}
