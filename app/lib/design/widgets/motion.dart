import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';
import '../motion.g.dart';
import '../theme.dart';
import 'core.dart';

/// A spring from design/motion.json as a Curve, for the places Flutter wants one (route transitions, hero flights).
class SpringCurve extends Curve {
  const SpringCurve(this.spec, {this.seconds = TickMotion.sheetSpringSeconds});
  final TickSpringSpec spec;
  final double seconds;
  @override
  double transformInternal(double t) => SpringSimulation(springOf(spec), 0, 1, 0).x(t * seconds);
}

class _SpringRectTween extends RectTween {
  _SpringRectTween({super.begin, super.end});
  static const _curve = SpringCurve(TickSprings.standard);
  @override
  Rect? lerp(double t) => Rect.lerp(begin, end, _curve.transform(t));
}

/// A shared element that flies on the standard spring. With Reduce Motion there is no flight: the page cross-fades instead.
class TickHero extends StatelessWidget {
  const TickHero({super.key, required this.tag, required this.child});
  final String tag;
  final Widget child;
  @override
  Widget build(BuildContext context) => context.reduceMotion ? child : Hero(tag: tag, createRectTween: (a, b) => _SpringRectTween(begin: a, end: b), child: child);
}

/// A number that rolls to its new value on the standard spring. It lands exactly, never overshoots past it (money shouldn't wobble), and is read
/// out as the final value. Reduce Motion cross-fades instead.
class RollingNumber extends StatefulWidget {
  const RollingNumber({super.key, required this.value, required this.builder, this.semanticLabel});
  final int value;
  final Widget Function(BuildContext, int) builder;
  final String? semanticLabel;
  @override
  State<RollingNumber> createState() => _RollingNumberState();
}

class _RollingNumberState extends State<RollingNumber> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController.unbounded(vsync: this, value: widget.value.toDouble());
  late int _from = widget.value;

  @override
  void didUpdateWidget(RollingNumber old) {
    super.didUpdateWidget(old);
    if (old.value == widget.value || context.reduceMotion) return;
    _from = _c.value.round();
    _c.animateWith(SpringSimulation(springOf(TickSprings.standard), _c.value, widget.value.toDouble(), 0, tolerance: const Tolerance(distance: 0.5, velocity: 1)));
  }

  @override
  void dispose() { _c.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final body = context.reduceMotion
        ? AnimatedSwitcher(duration: const Duration(milliseconds: TickMotion.reduceMotionFadeMs), child: KeyedSubtree(key: ValueKey(widget.value), child: widget.builder(context, widget.value)))
        : AnimatedBuilder(animation: _c, builder: (context, _) {
            final lo = _from < widget.value ? _from : widget.value, hi = _from < widget.value ? widget.value : _from;
            return widget.builder(context, _c.isAnimating ? _c.value.round().clamp(lo, hi) : widget.value);
          });
    return widget.semanticLabel == null ? body : Semantics(label: widget.semanticLabel, excludeSemantics: true, child: body);
  }
}

class _Delayed extends Simulation {
  _Delayed(this.delay, this.inner);
  final double delay;
  final Simulation inner;
  @override
  double x(double t) => t < delay ? inner.x(0) : inner.x(t - delay);
  @override
  double dx(double t) => t < delay ? 0 : inner.dx(t - delay);
  @override
  bool isDone(double t) => t >= delay && inner.isDone(t - delay);
}

/// Rows settle in one after another, the first time a list ([scope]) shows in this run of the app, and never again.
/// Reduce Motion: a plain fade, all at once.
class StaggerIn extends StatefulWidget {
  const StaggerIn({super.key, required this.scope, required this.index, required this.child});
  final String scope;
  final int index;
  final Widget child;
  static final _played = <String>{};
  @override
  State<StaggerIn> createState() => _StaggerInState();
}

class _StaggerInState extends State<StaggerIn> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController.unbounded(vsync: this, value: 1);
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (StaggerIn._played.contains(widget.scope) || widget.index >= TickMotion.staggerMaxItems) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => StaggerIn._played.add(widget.scope));
    _c.value = 0;
    if (context.reduceMotion) {
      _c.animateTo(1, duration: const Duration(milliseconds: TickMotion.reduceMotionFadeMs));
    } else {
      _c.animateWith(_Delayed(widget.index * TickMotion.staggerStepMs / 1000, SpringSimulation(springOf(TickSprings.standard), 0, 1, 0)));
    }
  }

  @override
  void dispose() { _c.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final still = context.reduceMotion;
    return AnimatedBuilder(animation: _c, child: widget.child, builder: (context, child) {
      // The tree keeps one shape from start to finish, so rows never lose their state when the entrance ends.
      final v = _c.isAnimating ? _c.value : 1.0;
      return Opacity(opacity: v.clamp(0.0, 1.0), child: Transform.translate(offset: Offset(0, still ? 0 : (1 - v) * TickMotion.staggerFromOffsetY), child: child));
    });
  }
}
