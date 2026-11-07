import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';
import '../../services/haptics.dart';
import '../motion.g.dart';
import '../theme.dart';
import '../tokens.g.dart';
import 'core.dart';

/// The mark the splash draws: one stroke.
Path tickPath(Size s) => Path()
  ..moveTo(s.width * 0.14, s.height * 0.54)
  ..lineTo(s.width * 0.40, s.height * 0.80)
  ..lineTo(s.width * 0.88, s.height * 0.20);

class _Mark extends CustomPainter {
  _Mark(this.draw, this.pulse);
  final double draw;
  final double pulse;
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    if (pulse > 0 && pulse < 1) {
      canvas.drawCircle(c, size.width * (0.5 + pulse * 0.9), Paint()..color = TickPalette.volt.withValues(alpha: (1 - pulse) * 0.5));
    }
    final path = tickPath(size);
    final metric = path.computeMetrics().first;
    final p = Paint()..color = TickPalette.volt..style = PaintingStyle.stroke..strokeWidth = size.width * 0.13..strokeCap = StrokeCap.round..strokeJoin = StrokeJoin.round;
    if (draw > 0) canvas.drawPath(metric.extractPath(0, metric.length * draw.clamp(0.0, 1.0)), p);
  }
  @override
  bool shouldRepaint(_Mark o) => o.draw != draw || o.pulse != pulse;
}

/// Every launch, over the app: the wordmark exactly where the native launch screen left it, the tick drawing itself on a spring, a Volt pulse and one crisp haptic.
/// At most [TickMotion.splashTotalMs]; a tap skips it. Reduce Motion: the finished mark, then a fade.
class TickSplash extends StatefulWidget {
  const TickSplash({super.key, required this.child});
  final Widget child;
  @override
  State<TickSplash> createState() => _TickSplashState();
}

class _TickSplashState extends State<TickSplash> with TickerProviderStateMixin {
  late final AnimationController _t = AnimationController(vsync: this, duration: const Duration(milliseconds: TickMotion.splashTotalMs));
  bool _gone = false, _hit = false;

  @override
  void initState() {
    super.initState();
    _t.addListener(_tick);
    _t.addStatusListener((s) { if (s == AnimationStatus.completed) setState(() => _gone = true); });
    _t.forward();
  }

  void _tick() {
    if (!_hit && _t.value * TickMotion.splashTotalMs >= TickMotion.splashDrawMs) {
      _hit = true;
      TickHaptics.instance.play('splash');
    }
  }

  @override
  void dispose() { _t.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    if (_gone) return widget.child;
    final reduce = context.reduceMotion;
    return Stack(fit: StackFit.expand, children: [
      widget.child,
      GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _gone = true),
        child: AnimatedBuilder(animation: _t, builder: (context, _) {
          final ms = _t.value * TickMotion.splashTotalMs;
          final sim = SpringSimulation(springOf(TickSprings.pop), 0, 1, 0);
          final draw = reduce ? 1.0 : sim.x(ms / TickMotion.splashDrawMs * 0.42).clamp(0.0, 1.0);
          final pulse = reduce ? 0.0 : ((ms - TickMotion.splashDrawMs) / (TickMotion.splashTotalMs - TickMotion.splashDrawMs - TickMotion.splashFadeMs)).clamp(0.0, 1.0);
          final fade = ((TickMotion.splashTotalMs - ms) / TickMotion.splashFadeMs).clamp(0.0, 1.0);
          return Opacity(opacity: fade, child: ColoredBox(color: TickPalette.ink, child: Center(child: SizedBox(width: LaunchMark.width, height: LaunchMark.height, child: Stack(clipBehavior: Clip.none, alignment: Alignment.center, children: [
            Positioned(top: -LaunchMark.height * 1.5, child: SizedBox(width: 64, height: 64, child: CustomPaint(painter: _Mark(draw, pulse)))),
            const LaunchMark(),
          ])))));
        }),
      ),
    ]);
  }
}

/// What the native launch screen shows, drawn the same way: tools export it to LaunchImage so the hand-off has no flash.
class LaunchMark extends StatelessWidget {
  const LaunchMark({super.key});
  static const width = 120.0, height = 60.0;
  @override
  Widget build(BuildContext context) => MediaQuery.withNoTextScaling(child: Center(child: DefaultTextStyle(style: tickTextStyle(TickType.displayM, TickPalette.paper, size: 40), child: const _Word())));
}

class _Word extends StatelessWidget {
  const _Word();
  @override
  Widget build(BuildContext context) {
    const size = 40.0;
    return Semantics(label: 'tick', excludeSemantics: true, child: Stack(clipBehavior: Clip.none, children: [
      Text('tıck', style: tickTextStyle(TickType.displayM, TickPalette.paper, size: size)),
      Positioned(left: size * 0.455, top: size * 0.14, child: Container(width: size * 0.2, height: size * 0.2, decoration: const BoxDecoration(color: TickPalette.volt, shape: BoxShape.circle))),
    ]));
  }
}

