import 'dart:math' as math;
import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../data/ledger.dart';
import '../design/motion.g.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import '../services/haptics.dart';
import 'payday_editor.dart';

const introScenes = <(String, String, String)>[
  ('Every purchase. One number.', 'Tick reads your accounts and resolves them into what matters.', 'stream'),
  ('Your balance, across every account.', 'And what\'s safe to spend until payday, after bills and cards.', 'count'),
  ('Payday, always in view.', 'Every number knows when the next one lands.', 'flip'),
  ('Split it in seconds.', 'Shared costs go to the right people, and Tick spots when they pay you back.', 'split'),
  ('Ask, and get the number.', 'Plain questions, exact answers from your own data.', 'type'),
];

double _spring(double t) => SpringSimulation(springOf(TickSprings.standard), 0, 1, 0).x(t.clamp(0.0, 1.0) * 0.6);

/// The first-run story: five scenes rendered live, then Make it yours. Tap or swipe to move on, Skip is always there. Reduce Motion shows each finished frame with the same words.
class IntroCinematic extends ConsumerStatefulWidget {
  const IntroCinematic({super.key, required this.onDone, this.replay = false});
  final void Function(PaydayRule? rule, String after) onDone;
  final bool replay;
  @override
  ConsumerState<IntroCinematic> createState() => _IntroCinematicState();
}

class _IntroCinematicState extends ConsumerState<IntroCinematic> with SingleTickerProviderStateMixin {
  late final AnimationController _t = AnimationController(vsync: this, duration: const Duration(milliseconds: TickMotion.sceneMs));
  int _scene = 0;
  PaydayRule? _rule;

  int get _last => widget.replay ? introScenes.length - 1 : introScenes.length;

  @override
  void initState() {
    super.initState();
    _t.addStatusListener((s) { if (s == AnimationStatus.completed && _scene < introScenes.length) _go(_scene + 1); });
    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _start(); });
  }

  void _start() {
    if (_scene < introScenes.length) {
      TickHaptics.instance.play('intro', tier: introScenes[_scene].$3);
      _t.forward(from: 0);
    } else {
      _t.stop();
    }
  }

  void _go(int n) {
    if (n > _last) { _finish('skip'); return; }
    if (n < 0) return;
    setState(() => _scene = n);
    _start();
  }

  void _finish(String after) {
    TickHaptics.instance.play('intro', tier: 'done');
    widget.onDone(_rule, after);
  }

  @override
  void dispose() { _t.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final reduce = context.reduceMotion;
    final total = _last + 1;
    return ColoredBox(color: TickPalette.ink, child: SafeArea(child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _scene < introScenes.length ? () => _go(_scene + 1) : null,
      onHorizontalDragEnd: (d) { final v = d.primaryVelocity ?? 0; if (v < -200) _go(_scene + 1); if (v > 200) _go(_scene - 1); },
      child: Padding(padding: const EdgeInsets.symmetric(horizontal: TickLayout.gutter), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(height: 52, child: Row(children: [
          Semantics(label: 'Scene ${_scene + 1} of $total', excludeSemantics: true, child: Row(mainAxisSize: MainAxisSize.min, children: [
            for (var i = 0; i < total; i++) Container(margin: const EdgeInsets.only(right: 6), width: i == _scene ? 22 : 7, height: 7, decoration: BoxDecoration(color: i == _scene ? TickPalette.volt : TickPalette.graphite, borderRadius: BorderRadius.circular(TickRadius.pill))),
          ])),
          const Spacer(),
          Pressable(onTap: () => _scene < introScenes.length && !widget.replay ? _go(introScenes.length) : _finish('skip'), semanticLabel: 'Skip', minSize: 44, child: Padding(padding: const EdgeInsets.all(8), child: Text('Skip', style: tickTextStyle(TickType.body, TickPalette.mist)))),
        ])),
        Expanded(child: AnimatedSwitcher(
          duration: const Duration(milliseconds: TickMotion.reduceMotionFadeMs * 2),
          child: _scene < introScenes.length
              ? KeyedSubtree(key: ValueKey(_scene), child: _Scene(i: _scene, t: reduce ? const AlwaysStoppedAnimation(1) : _t))
              : KeyedSubtree(key: const ValueKey('yours'), child: _MakeItYours(onRule: (r) => _rule = r, onChoice: _finish)),
        )),
      ])),
    )));
  }
}

class _Scene extends StatelessWidget {
  const _Scene({required this.i, required this.t});
  final int i;
  final Animation<double> t;
  @override
  Widget build(BuildContext context) {
    final (title, body, _) = introScenes[i];
    return LayoutBuilder(builder: (context, box) {
      final compact = box.maxHeight < 560;
      return SingleChildScrollView(physics: const NeverScrollableScrollPhysics(), child: ConstrainedBox(constraints: BoxConstraints(minHeight: box.maxHeight), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(height: compact ? 200 : box.maxHeight * 0.58, child: RepaintBoundary(child: MediaQuery.withNoTextScaling(child: AnimatedBuilder(animation: t, builder: (context, _) => switch (i) {     // the picture stays a picture; the words below scale
          0 => _Stream(t.value), 1 => _Count(t.value), 2 => _Flip(t.value), 3 => _Split(t.value), _ => _Typing(t.value),
        })))),
        const SizedBox(height: 16),
        Text(title, style: tickTextStyle(TickType.displayL, TickPalette.paper)),
        const SizedBox(height: 8),
        Text(body, style: tickTextStyle(TickType.bodyL, TickPalette.mist)),
        const SizedBox(height: 24),
      ])));
    });
  }
}

/// Scene 1: rows stream in and resolve into one number.
class _Stream extends StatelessWidget {
  const _Stream(this.t);
  final double t;
  static const rows = [('Blue Bottle', 575), ('Whole Foods', 4218), ('Uber', 1840), ('Spotify', 1099), ('Chipotle', 1385), ('Trader Joe\'s', 1940)];
  @override
  Widget build(BuildContext context) {
    final merge = ((t - 0.55) / 0.3).clamp(0.0, 1.0);
    return LayoutBuilder(builder: (context, box) => Stack(alignment: Alignment.center, children: [
      for (final (i, r) in rows.indexed) () {
        final start = i * 0.07;
        final inT = _spring((t - start) / 0.25);
        final y = (i - 2.5) * 40.0 * (1 - merge);
        return Transform.translate(offset: Offset((1 - inT) * box.maxWidth, y), child: Opacity(opacity: (1 - merge) * inT.clamp(0.0, 1.0), child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7), decoration: BoxDecoration(color: TickPalette.ink3, borderRadius: BorderRadius.circular(TickRadius.small)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [Text(r.$1, style: tickTextStyle(TickType.body, TickPalette.paper)), const SizedBox(width: 24), Text(formatCents(r.$2), style: tickTextStyle(TickType.monoS, TickPalette.mist))]),
        )));
      }(),
      Opacity(opacity: merge, child: Transform.scale(scale: 0.7 + 0.3 * _spring(merge), child: Text('\$214', style: tickTextStyle(TickType.heroXL, TickPalette.volt)))),
    ]));
  }
}

/// Scene 2: Safe to spend counts up and settles on a Volt underline.
class _Count extends StatelessWidget {
  const _Count(this.t);
  final double t;
  @override
  Widget build(BuildContext context) {
    // First the balance across every account counts up, then it settles into what's safe until payday.
    final first = t < 0.5;
    final k = first ? (t / 0.4).clamp(0.0, 1.0) : ((t - 0.5) / 0.25).clamp(0.0, 1.0);
    final ease = 1 - math.pow(1 - k, 3);
    final v = first ? (1840 * ease).round() : (1840 - (1840 - 214) * ease).round();
    final line = _spring((t - 0.75) / 0.2);
    return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      Text(first ? 'Across every account' : 'Safe until payday', style: tickTextStyle(TickType.body, TickPalette.mist)),
      FittedBox(child: Text('\$$v', style: tickTextStyle(TickType.heroXL, TickPalette.paper, size: 96))),
      const SizedBox(height: 8),
      Container(width: 200 * line.clamp(0.0, 1.1), height: 8, decoration: BoxDecoration(color: TickPalette.volt, borderRadius: BorderRadius.circular(TickRadius.pill))),
    ]));
  }
}

/// Scene 3: the calendar flips to the next payday.
class _Flip extends StatelessWidget {
  const _Flip(this.t);
  final double t;
  static const days = ['6', '9', '11', '13'];
  @override
  Widget build(BuildContext context) {
    final p = (t / 0.7).clamp(0.0, 0.999) * (days.length - 1);
    final i = p.floor();
    final f = p - i;
    final done = t >= 0.7;
    final shown = done ? days.last : (f < 0.5 ? days[i] : days[i + 1]);
    final angle = done ? 0.0 : (f < 0.5 ? f : f - 1) * math.pi;
    return Center(child: Transform(alignment: Alignment.center, transform: Matrix4.identity()..setEntry(3, 2, 0.002)..rotateX(angle), child: Container(
      width: 170, height: 190, alignment: Alignment.center, decoration: BoxDecoration(color: done ? TickPalette.volt : TickPalette.ink3, borderRadius: BorderRadius.circular(TickRadius.card)),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text('NOV', style: tickTextStyle(TickType.label, done ? TickPalette.ink : TickPalette.mist)),
        Text(shown, style: tickTextStyle(TickType.heroXL, done ? TickPalette.ink : TickPalette.paper)),
        Text(done ? 'Payday' : ' ', style: tickTextStyle(TickType.body, TickPalette.ink)),
      ]),
    )));
  }
}

class _SplitPainter extends CustomPainter {
  _SplitPainter(this.t);
  final double t;
  @override
  void paint(Canvas canvas, Size s) {
    final c = s.center(Offset.zero);
    final r = math.min(s.width, s.height) * 0.38;
    final gather = _spring(t / 0.3);
    final fly = ((t - 0.45) / 0.35).clamp(0.0, 1.0);
    const faces = [TickPalette.sky, TickPalette.clay, TickPalette.volt];
    for (var i = 0; i < 3; i++) {
      final a = -math.pi / 2 + i * 2 * math.pi / 3;
      final dir = Offset(math.cos(a), math.sin(a));
      final at = c + dir * (r + (1 - gather) * 120);
      canvas.drawCircle(at, 26, Paint()..color = faces[i]);
      final eye = Paint()..color = TickPalette.ink;
      canvas.drawCircle(at + const Offset(-8, -4), 3, eye);
      canvas.drawCircle(at + const Offset(8, -4), 3, eye);
      canvas.drawArc(Rect.fromCenter(center: at + const Offset(0, 4), width: 16, height: 12), 0.2, math.pi - 0.4, false, Paint()..color = TickPalette.ink..style = PaintingStyle.stroke..strokeWidth = 2.5..strokeCap = StrokeCap.round);
      if (fly > 0) {
        final p = Offset.lerp(c, at, _spring(fly))!;
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: p, width: 34, height: 22), const Radius.circular(6)), Paint()..color = TickPalette.paper.withValues(alpha: 1 - (fly > 0.9 ? (fly - 0.9) * 10 : 0)));
      }
    }
    if (fly < 1) {
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: c, width: 76, height: 96 * (1 - fly * 0.7)), const Radius.circular(10)), Paint()..color = TickPalette.paper);
    }
  }
  @override
  bool shouldRepaint(_SplitPainter o) => o.t != t;
}

/// Scene 4: faces gather round a bill, it splits, and shares fly to them.
class _Split extends StatelessWidget {
  const _Split(this.t);
  final double t;
  @override
  Widget build(BuildContext context) => CustomPaint(painter: _SplitPainter(t), size: Size.infinite);
}

/// Scene 5: a question types itself and the answer lands.
class _Typing extends StatelessWidget {
  const _Typing(this.t);
  final double t;
  static const q = 'How much on food this month?';
  @override
  Widget build(BuildContext context) {
    final n = (q.length * (t / 0.5).clamp(0.0, 1.0)).round();
    final a = _spring((t - 0.58) / 0.25);
    return Center(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Align(alignment: Alignment.centerRight, child: Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), decoration: BoxDecoration(color: TickPalette.ink3, borderRadius: BorderRadius.circular(TickRadius.card)),
          child: Text('${q.substring(0, n)}${n < q.length ? '|' : ''}', style: tickTextStyle(TickType.body, TickPalette.paper)))),
      const SizedBox(height: 20),
      Opacity(opacity: a.clamp(0.0, 1.0), child: Transform.translate(offset: Offset(0, (1 - a) * 16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('\$412', style: tickTextStyle(TickType.hero, TickPalette.volt)),
        Text('on food so far this month.', style: tickTextStyle(TickType.bodyL, TickPalette.mist)),
      ]))),
    ]));
  }
}

/// Scene 6: payday with the live preview, and the optional bank step.
class _MakeItYours extends ConsumerWidget {
  const _MakeItYours({required this.onRule, required this.onChoice});
  final ValueChanged<PaydayRule> onRule;
  final ValueChanged<String> onChoice;
  @override
  Widget build(BuildContext context, WidgetRef ref) => SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const SizedBox(height: 12),
        Text('Make it yours.', style: tickTextStyle(TickType.displayL, TickPalette.paper)),
        const SizedBox(height: 16),
        PaydayEditor(today: ref.watch(clockProvider)(), onChanged: onRule),
        const SizedBox(height: 16),
        PillButton('Link a bank', onTap: () => onChoice('link')),
        const SizedBox(height: 8),
        PillButton('Import a statement', style: PillStyle.quiet, onTap: () => onChoice('import')),
        const SizedBox(height: 8),
        PillButton('Skip for now', style: PillStyle.quiet, onTap: () => onChoice('skip')),
        const SizedBox(height: 24),
      ]));
}

/// Settings > About > Replay the intro: the scenes without the setup.
class IntroReplayScreen extends ConsumerWidget {
  const IntroReplayScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => IntroCinematic(replay: true, onDone: (_, _) => context.pop());
}

