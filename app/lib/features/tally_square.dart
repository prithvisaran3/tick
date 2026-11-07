import 'dart:math' as math;
import 'package:flutter/widgets.dart';
import '../design/motion.g.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/more.dart';
import '../services/haptics.dart';

/// The Tally signature moment: four strokes and a slash, drawn like tally marks, then "All square ✓" with a heartbeat.
/// With Reduce Motion the marks simply appear.
Future<void> showSquareUp(BuildContext context) {
  TickHaptics.instance.heartbeat();
  return showTickSheet<void>(context, builder: (_) => const SquareUpMoment());
}

class SquareUpMoment extends StatefulWidget {
  const SquareUpMoment({super.key});
  @override
  State<SquareUpMoment> createState() => _SquareUpMomentState();
}

class _SquareUpMomentState extends State<SquareUpMoment> with SingleTickerProviderStateMixin {
  late final AnimationController _a = AnimationController(vsync: this, duration: const Duration(milliseconds: TickMotion.squareUpMs));
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (context.reduceMotion) { _a.value = 1; } else if (!_a.isAnimating && _a.value == 0) { _a.forward(); }
  }
  @override
  void dispose() { _a.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Semantics(
      label: 'All square. Nobody owes anybody.', container: true,
      child: Padding(padding: const EdgeInsets.symmetric(vertical: 16), child: Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(width: 120, height: 80, child: AnimatedBuilder(animation: _a, builder: (_, _) => CustomPaint(painter: _Marks(_a.value, c.accent, c.text)))),
        const SizedBox(height: 12),
        Text('All square ✓', style: context.ts(TickType.displayM)),
        const SizedBox(height: 4),
        Text('Nobody owes anybody.', style: context.ts(TickType.body, color: c.textSecondary)),
      ])),
    );
  }
}

class _Marks extends CustomPainter {
  _Marks(this.t, this.fill, this.ink);
  final double t;
  final Color fill;
  final Color ink;
  @override
  void paint(Canvas canvas, Size s) {
    final p = Paint()..color = ink..strokeWidth = 7..strokeCap = StrokeCap.round;
    final slash = Paint()..color = fill..strokeWidth = 7..strokeCap = StrokeCap.round;
    // Strokes 0..3 take the first 70% of the animation, the slash the rest.
    for (var i = 0; i < 4; i++) {
      final k = ((t / 0.7) * 4 - i).clamp(0.0, 1.0);
      if (k == 0) continue;
      final x = 18.0 + i * 24;
      canvas.drawLine(Offset(x, 8), Offset(x, 8 + 64 * k), p);
    }
    final k = ((t - 0.7) / 0.3).clamp(0.0, 1.0);
    if (k > 0) canvas.drawLine(Offset(4, 62), Offset(4 + (s.width - 8) * k, 62 - 44 * k * math.min(1, 1)), slash);
  }
  @override
  bool shouldRepaint(_Marks o) => o.t != t;
}
