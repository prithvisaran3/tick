import 'dart:math' as math;
import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../../services/haptics.dart';
import '../avatar.g.dart';
import '../motion.g.dart';
import '../theme.dart';
import '../tokens.g.dart';
import 'core.dart';

/// A person's face as small JSON: one choice per layer. Unknown or missing values fall back to the default from their id.
class AvatarSpec {
  const AvatarSpec(this.v);
  final Map<String, int> v;
  int of(String k) => (v[k] ?? 0) % TickAvatarPalette.options[k]!;
  AvatarSpec withValue(String k, int x) => AvatarSpec({...v, k: x});
  Map<String, dynamic> toJson() => v;

  /// The same id always draws the same face.
  factory AvatarSpec.fromSeed(String seed) {
    var h = 2166136261;
    for (final c in seed.codeUnits) { h = ((h ^ c) * 16777619) & 0xFFFFFFFF; }
    final out = <String, int>{};
    for (final e in TickAvatarPalette.options.entries) {
      out[e.key] = h % e.value;
      h = ((h >> 3) ^ (h * 2654435761)) & 0xFFFFFFFF;
    }
    return AvatarSpec(out);
  }

  factory AvatarSpec.random(math.Random r) => AvatarSpec({for (final e in TickAvatarPalette.options.entries) e.key: r.nextInt(e.value)});

  factory AvatarSpec.parse(Map<String, dynamic>? j, String seed) {
    final base = AvatarSpec.fromSeed(seed).v;
    return AvatarSpec({...base, for (final e in (j ?? const {}).entries) if (e.value is num && base.containsKey(e.key)) e.key: (e.value as num).toInt()});
  }
}

class _Face extends CustomPainter {
  _Face(this.s, {this.blink = 0, this.wink = 0, this.bob = 0});
  final AvatarSpec s;
  final double blink, wink, bob;
  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 100;
    canvas.scale(k);
    canvas.clipPath(Path()..addOval(const Rect.fromLTWH(0, 0, 100, 100)));
    canvas.drawRect(const Rect.fromLTWH(0, 0, 100, 100), Paint()..color = TickAvatarPalette.background[s.of('background')]);
    canvas.translate(0, bob);
    final skin = TickAvatarPalette.skin[s.of('skin')];
    final hair = TickAvatarPalette.hair[s.of('hairColor')];
    final fill = Paint()..color = skin;
    final ink = Paint()..color = TickPalette.ink;
    final line = Paint()..color = TickPalette.ink..style = PaintingStyle.stroke..strokeWidth = 2.6..strokeCap = StrokeCap.round;
    final hairP = Paint()..color = hair;
    // shoulders and neck
    canvas.drawOval(const Rect.fromLTWH(14, 82, 72, 50), Paint()..color = TickPalette.graphite);
    canvas.drawRect(const Rect.fromLTWH(42, 70, 16, 18), fill);
    // long hair sits behind the face
    final h = s.of('hair');
    if (h == 4 || h == 5) canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(22, 24, 56, h == 4 ? 60 : 46), const Radius.circular(22)), hairP);
    // face
    switch (s.of('face')) {
      case 0: canvas.drawOval(const Rect.fromLTWH(27, 22, 46, 56), fill);
      case 1: canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(27, 22, 46, 54), const Radius.circular(18)), fill);
      default: canvas.drawCircle(const Offset(50, 49), 26, fill);
    }
    // beard
    final b = s.of('beard');
    if (b == 1) canvas.drawArc(const Rect.fromLTWH(30, 40, 40, 38), 0.1, math.pi - 0.2, true, hairP);
    if (b == 2) canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(40, 58, 20, 4), const Radius.circular(2)), hairP);
    // hair on top
    final top = Path();
    switch (h) {
      case 1: top.addRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(27, 19, 46, 14), const Radius.circular(7)));
      case 2: top..moveTo(26, 36)..quadraticBezierTo(30, 12, 52, 15)..quadraticBezierTo(76, 16, 74, 36)..quadraticBezierTo(60, 26, 26, 36);
      case 3: for (var i = 0; i < 6; i++) { top.addOval(Rect.fromCircle(center: Offset(30.0 + i * 8, 24 - (i % 2) * 4), radius: 8)); }
      case 4 || 5: top.addArc(const Rect.fromLTWH(26, 16, 48, 30), math.pi, math.pi);
      case 6: top.addOval(const Rect.fromLTWH(42, 6, 16, 16)); top.addArc(const Rect.fromLTWH(27, 18, 46, 24), math.pi, math.pi);
      case 7: for (var i = 0; i < 5; i++) { top..moveTo(30.0 + i * 10, 28)..lineTo(35.0 + i * 10, 12)..lineTo(40.0 + i * 10, 28)..close(); }
    }
    canvas.drawPath(top, hairP);
    // brows
    final brow = Paint()..color = hair..style = PaintingStyle.stroke..strokeWidth = 2.8..strokeCap = StrokeCap.round;
    final bt = [0.0, -2.0, 2.0][s.of('brows')];
    canvas.drawLine(Offset(36, 38 + bt), const Offset(46, 38), brow);
    canvas.drawLine(const Offset(54, 38), Offset(64, 38 + bt), brow);
    // eyes
    void eye(double x, double closed) {
      if (closed > 0.6) { canvas.drawLine(Offset(x - 4, 46), Offset(x + 4, 46), line); return; }
      switch (s.of('eyes')) {
        case 0: canvas.drawCircle(Offset(x, 46), 3, ink);
        case 1: canvas.drawOval(Rect.fromCenter(center: Offset(x, 46), width: 6, height: 8), ink);
        case 2:
          canvas.drawCircle(Offset(x, 46), 4.5, Paint()..color = TickPalette.white);
          canvas.drawCircle(Offset(x + 1, 46), 2.4, ink);
        default: canvas.drawArc(Rect.fromCenter(center: Offset(x, 47), width: 9, height: 7), math.pi, math.pi, false, line);
      }
    }
    eye(41, blink);
    eye(59, math.max(blink, wink));
    // mouth
    final m = Rect.fromCenter(center: const Offset(50, 60), width: 18, height: 12);
    switch (wink > 0.2 ? 0 : s.of('mouth')) {
      case 0: canvas.drawArc(m, 0.2, math.pi - 0.4, false, line);
      case 1: canvas.drawLine(const Offset(44, 62), const Offset(56, 62), line);
      case 2: canvas.drawArc(m, 0, math.pi, true, ink);
      case 3: canvas.drawCircle(const Offset(50, 62), 3, ink);
      default: canvas.drawArc(m.shift(const Offset(3, 0)), 0.3, 1.6, false, line);
    }
    // glasses
    final g = s.of('glasses');
    if (g > 0) {
      final gp = Paint()..color = TickPalette.ink..style = PaintingStyle.stroke..strokeWidth = 2;
      final a = const Offset(41, 46), c = const Offset(59, 46);
      if (g == 1) { canvas.drawCircle(a, 8, gp); canvas.drawCircle(c, 8, gp); } else { canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: a, width: 16, height: 12), const Radius.circular(3)), gp); canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: c, width: 16, height: 12), const Radius.circular(3)), gp); }
      canvas.drawLine(const Offset(49, 46), const Offset(51, 46), gp);
    }
    // hat
    final hat = Paint()..color = TickPalette.ink2;
    switch (s.of('hat')) {
      case 1: canvas.drawArc(const Rect.fromLTWH(26, 10, 48, 44), math.pi, math.pi, true, hat); canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(46, 28, 38, 6), const Radius.circular(3)), hat);
      case 2: canvas.drawArc(const Rect.fromLTWH(26, 12, 48, 40), math.pi, math.pi, true, Paint()..color = TickPalette.clay); canvas.drawCircle(const Offset(50, 11), 5, Paint()..color = TickPalette.paper);
      case 3: canvas.drawRect(const Rect.fromLTWH(34, 4, 32, 24), hat); canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(24, 27, 52, 5), const Radius.circular(2)), hat);
    }
  }
  @override
  bool shouldRepaint(_Face o) => o.s.v != s.v || o.blink != blink || o.wink != wink || o.bob != bob;
}

/// A drawn face. [live] blinks and bobs (big avatars only, so a list stays quiet); a tap winks and smiles with a light haptic. Reduce Motion keeps it still.
class TickAvatar extends StatefulWidget {
  const TickAvatar(this.spec, {super.key, this.size = 40, this.live = false, this.tappable = true});
  final AvatarSpec spec;
  final double size;
  final bool live;
  final bool tappable;
  @override
  State<TickAvatar> createState() => _TickAvatarState();
}

class _TickAvatarState extends State<TickAvatar> with TickerProviderStateMixin {
  late final AnimationController _idle = AnimationController(vsync: this, duration: const Duration(milliseconds: TickMotion.avatarIdleMs));
  late final AnimationController _wink = AnimationController(vsync: this, duration: const Duration(milliseconds: TickMotion.avatarWinkMs));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.live && !context.reduceMotion && !_idle.isAnimating) _idle.repeat();
    if (context.reduceMotion) _idle.stop();
  }

  @override
  void dispose() { _idle.dispose(); _wink.dispose(); super.dispose(); }

  void _tap() {
    TickHaptics.instance.selection();
    if (!context.reduceMotion) _wink.animateWith(SpringSimulation(springOf(TickSprings.pop), 0, 1, 0)).whenComplete(() { if (mounted) _wink.reverse(); });
  }

  @override
  Widget build(BuildContext context) {
    final body = RepaintBoundary(child: AnimatedBuilder(animation: Listenable.merge([_idle, _wink]), builder: (context, _) {
      final t = _idle.value;
      final blink = (t > 0.94 && t < 0.98) ? 1.0 : 0.0;
      return CustomPaint(size: Size.square(widget.size), painter: _Face(widget.spec, blink: blink, wink: _wink.value, bob: math.sin(t * 2 * math.pi) * 1.2));
    }));
    if (!widget.tappable) return ExcludeSemantics(child: body);
    return Semantics(label: 'Avatar', button: true, child: GestureDetector(onTap: _tap, child: body));
  }
}

/// A person, from what they chose or the default from their id.
class PersonAvatar extends StatelessWidget {
  const PersonAvatar({super.key, required this.seed, this.spec, this.size = 40, this.live = false});
  final String seed;
  final Map<String, dynamic>? spec;
  final double size;
  final bool live;
  @override
  Widget build(BuildContext context) => TickAvatar(AvatarSpec.parse(spec, seed), size: size, live: live, tappable: size >= 44);
}

/// Ask Tick's mascot.
class AskMascot extends StatelessWidget {
  const AskMascot({super.key, this.size = 96});
  final double size;
  @override
  Widget build(BuildContext context) => TickAvatar(const AvatarSpec({'face': 2, 'skin': 0, 'hair': 0, 'hairColor': 0, 'eyes': 2, 'brows': 0, 'mouth': 0, 'glasses': 0, 'hat': 0, 'beard': 0, 'background': 0}), size: size, live: true);
}

/// One custom group icon.
class TallyIcon extends StatelessWidget {
  const TallyIcon(this.name, {super.key, this.size = 24, this.color});
  final String name;
  final double size;
  final Color? color;
  @override
  Widget build(BuildContext context) => SvgPicture.asset('assets/icons/tally/$name.svg', width: size, height: size, colorFilter: ColorFilter.mode(color ?? context.c.text, BlendMode.srcIn), excludeFromSemantics: true);
}

/// An icon in the picker: picking it pops on the pop spring, with a light haptic. Reduce Motion: it just fills.
class IconChoice extends StatefulWidget {
  const IconChoice(this.name, {super.key, required this.on, required this.onTap});
  final String name;
  final bool on;
  final VoidCallback onTap;
  @override
  State<IconChoice> createState() => _IconChoiceState();
}

class _IconChoiceState extends State<IconChoice> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController.unbounded(vsync: this, value: 1);
  @override
  void dispose() { _c.dispose(); super.dispose(); }
  void _tap() {
    TickHaptics.instance.selection();
    if (!context.reduceMotion) {
      _c.value = 0.7;
      _c.animateWith(SpringSimulation(springOf(TickSprings.pop), 0.7, 1, 0));
    }
    widget.onTap();
  }
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Semantics(label: widget.name, button: true, selected: widget.on, excludeSemantics: true, child: GestureDetector(onTap: _tap, child: AnimatedBuilder(animation: _c, builder: (context, _) => Transform.scale(scale: _c.value, child: Container(
      width: 44, height: 44, alignment: Alignment.center, decoration: BoxDecoration(color: widget.on ? c.accent : c.surface2, shape: BoxShape.circle),
      child: TallyIcon(widget.name, size: 22, color: widget.on ? c.onAccent : c.text),
    )))));
  }
}
