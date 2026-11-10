import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:sensors_plus/sensors_plus.dart';
import '../../services/haptics.dart';
import '../avatar.g.dart';
import '../motion.g.dart';
import '../theme.dart';
import '../tokens.g.dart';
import 'core.dart';

/// A person's face as small JSON: one choice per layer. Unknown or missing values fall back to the default from their id.
/// Palettes only grow at the end, so a saved index always means the same colour or shape.
class AvatarSpec {
  const AvatarSpec(this.v);
  final Map<String, int> v;
  int of(String k) => (v[k] ?? 0) % TickAvatarPalette.options[k]!;
  AvatarSpec withValue(String k, int x) => AvatarSpec({...v, k: x});
  Map<String, dynamic> toJson() => {...v, 'v': 2};
  String get cacheKey => [for (final k in TickAvatarPalette.options.keys) of(k)].join('.');

  /// The same id always draws the same face.
  factory AvatarSpec.fromSeed(String seed) {
    var h = 2166136261;
    for (final c in seed.codeUnits) { h = ((h ^ c) * 16777619) & 0xFFFFFFFF; }
    final out = <String, int>{};
    for (final e in TickAvatarPalette.options.entries) {
      out[e.key] = h % e.value;
      h = ((h >> 3) ^ (h * 2654435761)) & 0xFFFFFFFF;
    }
    // Defaults stay plain: a face nobody chose doesn't get a headscarf or a mark.
    return AvatarSpec({...out, 'hat': out['hat']! % 4, 'earrings': 0, 'mark': 0});
  }

  factory AvatarSpec.random(math.Random r) => AvatarSpec({for (final e in TickAvatarPalette.options.entries) e.key: r.nextInt(e.value)});

  /// A saved face. One saved before v2 keeps every choice and gets the plain option for each new layer, never a random one.
  factory AvatarSpec.parse(Map<String, dynamic>? j, String seed) {
    final base = AvatarSpec.fromSeed(seed).v;
    if (j == null || j.isEmpty) return AvatarSpec(base);
    final migrated = j['v'] != 2;
    return AvatarSpec({
      ...base,
      if (migrated) for (final k in TickAvatarPalette.addedInV2) k: 0,
      for (final e in j.entries) if (e.value is num && base.containsKey(e.key)) e.key: (e.value as num).toInt(),
    });
  }
}

enum AvatarMood { neutral, happy, surprised, thinking, sad }

Color _shade(Color c, double d) {
  final h = HSLColor.fromColor(c);
  return h.withLightness((h.lightness + d).clamp(0.0, 1.0)).toColor();
}

/// Soft clay: a matte highlight up and to the left, a darker rim down and to the right.
Paint _clay(Rect r, Color c, {double light = 0.12, double dark = 0.14}) => Paint()
  ..shader = RadialGradient(center: const Alignment(-0.35, -0.45), radius: 0.95, colors: [_shade(c, light), c, _shade(c, -dark)], stops: const [0, 0.55, 1]).createShader(r);

Paint _gloss(Rect r, {double a = 0.35}) => Paint()
  ..shader = RadialGradient(colors: [Color.fromRGBO(255, 255, 255, a), const Color(0x00FFFFFF)]).createShader(r);

/// Static layers are recorded once per face and replayed: lists of small avatars repaint for free.
class AvatarLayerCache {
  AvatarLayerCache._();
  static const max = 160;
  static final _m = <String, ui.Picture>{};   // insertion-ordered, so the first key is the oldest
  static int recorded = 0;
  static ui.Picture get(String key, void Function(Canvas) draw) {
    final hit = _m.remove(key);
    if (hit != null) { _m[key] = hit; return hit; }
    final rec = ui.PictureRecorder();
    draw(Canvas(rec));
    final pic = rec.endRecording();
    recorded++;
    _m[key] = pic;
    if (_m.length > max) _m.remove(_m.keys.first)!.dispose();
    return pic;
  }
  static void clear() { for (final p in _m.values) { p.dispose(); } _m.clear(); recorded = 0; }
}

const _hijab = 4, _turban = 5, _wrap = 6;
const _face = Rect.fromLTWH(27, 20, 46, 56);

/// Back: background, shoulders, neck, anything that sits behind the head.
void _paintBack(Canvas canvas, AvatarSpec s) {
  final bg = TickAvatarPalette.background[s.of('background')];
  canvas.drawRect(const Rect.fromLTWH(0, 0, 100, 100), Paint()..shader = RadialGradient(center: const Alignment(-0.3, -0.5), radius: 1.1, colors: [_shade(bg, 0.06), _shade(bg, -0.08)]).createShader(const Rect.fromLTWH(0, 0, 100, 100)));
  final skin = TickAvatarPalette.skin[s.of('skin')];
  final cloth = TickAvatarPalette.cloth[s.of('cloth')];
  final hair = TickAvatarPalette.hair[s.of('hairColor')];
  final hat = s.of('hat');
  // soft contact shadow under the head
  canvas.drawOval(const Rect.fromLTWH(24, 70, 52, 14), Paint()..color = const Color(0x33000000)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
  const body = Rect.fromLTWH(12, 80, 76, 52);
  canvas.drawRRect(RRect.fromRectAndRadius(body, const Radius.circular(26)), _clay(body, cloth));
  canvas.drawRect(const Rect.fromLTWH(42, 68, 16, 16), _clay(const Rect.fromLTWH(40, 66, 20, 20), _shade(skin, -0.05)));
  if (hat == _hijab) {
    const drape = Rect.fromLTWH(19, 13, 62, 84);
    canvas.drawRRect(RRect.fromRectAndRadius(drape, const Radius.circular(30)), _clay(drape, cloth, light: 0.1));
    return;
  }
  final h = s.of('hair');
  final hp = _clay(const Rect.fromLTWH(18, 14, 64, 76), hair, light: 0.1);
  switch (h) {
    case 4: canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(21, 22, 58, 64), const Radius.circular(24)), hp);
    case 5: canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(22, 22, 56, 48), const Radius.circular(22)), hp);
    case 8:
      for (final x in [24.0, 70.0]) {
        for (var i = 0; i < 5; i++) { canvas.drawOval(Rect.fromLTWH(x, 40.0 + i * 8, 7, 9), hp); }
      }
    case 9:
      for (var i = 0; i < 7; i++) { canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(22.0 + i * 8.5, 30, 5.5, 46 - (i - 3).abs() * 3.0), const Radius.circular(3)), hp); }
    case 10: canvas.drawCircle(const Offset(50, 40), 31, hp);
  }
}

/// Head: face, ears, cheeks, hair, beard, headwear, earrings, glasses. Everything that moves with the head but doesn't animate.
void _paintHead(Canvas canvas, AvatarSpec s) {
  final skin = TickAvatarPalette.skin[s.of('skin')];
  final hair = TickAvatarPalette.hair[s.of('hairColor')];
  final cloth = TickAvatarPalette.cloth[s.of('cloth')];
  final hat = s.of('hat');
  final covered = hat == _hijab;
  final faceP = _clay(_face.inflate(4), skin);
  if (!covered) {
    for (final x in [24.0, 70.0]) { canvas.drawOval(Rect.fromLTWH(x, 42, 8, 12), _clay(Rect.fromLTWH(x, 42, 8, 12), _shade(skin, -0.03))); }
  }
  switch (s.of('face')) {
    case 0: canvas.drawOval(_face, faceP);
    case 1: canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(27, 20, 46, 54), const Radius.circular(19)), faceP);
    default: canvas.drawCircle(const Offset(50, 48), 26, faceP);
  }
  // cheeks
  final blush = Paint()..shader = const RadialGradient(colors: [Color(0x40FF6B4A), Color(0x00FF6B4A)]).createShader(const Rect.fromLTWH(30, 50, 12, 10));
  canvas.drawOval(const Rect.fromLTWH(30, 50, 12, 10), blush);
  canvas.drawOval(const Rect.fromLTWH(58, 50, 12, 10), Paint()..shader = const RadialGradient(colors: [Color(0x40FF6B4A), Color(0x00FF6B4A)]).createShader(const Rect.fromLTWH(58, 50, 12, 10)));
  // nose: a soft bump, not a line
  canvas.drawOval(const Rect.fromLTWH(47, 49, 6, 5), Paint()..color = _shade(skin, -0.07));
  canvas.drawCircle(const Offset(49, 50), 1.1, Paint()..color = _shade(skin, 0.12));
  // mark
  switch (s.of('mark')) {
    case 1:
      final f = Paint()..color = _shade(skin, -0.2);
      for (final o in const [Offset(34, 53), Offset(37, 55), Offset(35, 57), Offset(63, 53), Offset(66, 55), Offset(64, 57)]) { canvas.drawCircle(o, 0.9, f); }
    case 2: canvas.drawCircle(const Offset(50, 34), 1.8, Paint()..color = TickPalette.clay);
  }
  // beard
  final hp = _clay(const Rect.fromLTWH(26, 16, 48, 64), hair, light: 0.1);
  switch (s.of('beard')) {
    case 1: canvas.drawPath(Path()..moveTo(28, 50)..quadraticBezierTo(30, 80, 50, 80)..quadraticBezierTo(70, 80, 72, 50)..quadraticBezierTo(62, 66, 50, 64)..quadraticBezierTo(38, 66, 28, 50), hp);
    case 2: canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(41, 56, 18, 4.5), const Radius.circular(2.5)), hp);
    case 3: canvas.drawPath(Path()..moveTo(30, 54)..quadraticBezierTo(32, 76, 50, 76)..quadraticBezierTo(68, 76, 70, 54)..quadraticBezierTo(60, 66, 50, 65)..quadraticBezierTo(40, 66, 30, 54), Paint()..color = hair.withValues(alpha: 0.28));
  }
  // hair on top (headwear hides most of it)
  if (hat != _hijab && hat != _turban) {
    final top = Path();
    switch (s.of('hair')) {
      case 1: top.addRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(27, 17, 46, 15), const Radius.circular(8)));
      case 2: top..moveTo(26, 36)..quadraticBezierTo(29, 11, 52, 14)..quadraticBezierTo(77, 15, 74, 36)..quadraticBezierTo(58, 24, 26, 36);
      case 3: for (var i = 0; i < 6; i++) { top.addOval(Rect.fromCircle(center: Offset(30.0 + i * 8, 23 - (i % 2) * 4), radius: 8)); }
      case 4 || 5 || 9: top.addArc(const Rect.fromLTWH(26, 15, 48, 32), math.pi, math.pi);
      case 6: top.addOval(const Rect.fromLTWH(41, 4, 18, 17)); top.addArc(const Rect.fromLTWH(27, 17, 46, 26), math.pi, math.pi);
      case 7: for (var i = 0; i < 5; i++) { top..moveTo(29.0 + i * 10, 29)..lineTo(34.0 + i * 10, 11)..lineTo(39.0 + i * 10, 29)..close(); } top.addRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(27, 20, 46, 12), const Radius.circular(6)));
      case 8: top.addArc(const Rect.fromLTWH(26, 15, 48, 32), math.pi, math.pi); 
      case 10: for (var i = 0; i < 7; i++) { top.addOval(Rect.fromCircle(center: Offset(28.0 + i * 7.3, 22 - math.sin(i / 6 * math.pi) * 6), radius: 8)); }
      case 11: top.addArc(const Rect.fromLTWH(27, 18, 46, 24), math.pi, math.pi);
    }
    if (s.of('hair') == 11) {
      canvas.drawPath(top, Paint()..color = hair.withValues(alpha: 0.55));
    } else {
      canvas.drawPath(top, hp);
      canvas.drawOval(const Rect.fromLTWH(33, 15, 16, 7), _gloss(const Rect.fromLTWH(33, 15, 16, 7), a: 0.3));
    }
  }
  // headwear
  final fab = _clay(const Rect.fromLTWH(20, 2, 60, 46), cloth, light: 0.12);
  final fold = Paint()..color = _shade(cloth, -0.12)..style = PaintingStyle.stroke..strokeWidth = 1.6..strokeCap = StrokeCap.round;
  switch (hat) {
    case 1:
      canvas.drawArc(const Rect.fromLTWH(26, 9, 48, 44), math.pi, math.pi, true, _clay(const Rect.fromLTWH(26, 9, 48, 30), TickPalette.ink2));
      canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(46, 27, 38, 6), const Radius.circular(3)), Paint()..color = TickPalette.ink2);
    case 2:
      canvas.drawArc(const Rect.fromLTWH(26, 11, 48, 40), math.pi, math.pi, true, _clay(const Rect.fromLTWH(26, 11, 48, 24), cloth));
      canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(25, 26, 50, 7), const Radius.circular(3.5)), Paint()..color = _shade(cloth, -0.08));
      canvas.drawCircle(const Offset(50, 10), 5, _clay(const Rect.fromLTWH(45, 5, 10, 10), TickPalette.paper));
    case 3:
      canvas.drawRect(const Rect.fromLTWH(34, 3, 32, 24), _clay(const Rect.fromLTWH(34, 3, 32, 24), TickPalette.ink2));
      canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(24, 26, 52, 5), const Radius.circular(2)), Paint()..color = TickPalette.ink2);
    case _hijab:
      // the scarf frames the face: a band over the forehead and down both sides
      final frame = Path()..fillType = PathFillType.evenOdd
        ..addRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(21, 12, 58, 70), const Radius.circular(28)))
        ..addOval(const Rect.fromLTWH(30, 27, 40, 50));
      canvas.drawPath(frame, _clay(const Rect.fromLTWH(21, 12, 58, 70), cloth, light: 0.1));
      canvas.drawArc(const Rect.fromLTWH(30, 27, 40, 50), math.pi * 1.1, math.pi * 0.8, false, fold);
    case _turban:
      canvas.drawOval(const Rect.fromLTWH(23, 5, 54, 34), fab);
      canvas.drawPath(Path()..moveTo(27, 30)..quadraticBezierTo(50, 8, 73, 22), fold);
      canvas.drawPath(Path()..moveTo(26, 22)..quadraticBezierTo(50, 32, 74, 30), fold);
      canvas.drawPath(Path()..moveTo(50, 7)..lineTo(44, 31), fold);
    case _wrap:
      canvas.drawArc(const Rect.fromLTWH(24, 9, 52, 44), math.pi, math.pi, true, fab);
      canvas.drawOval(const Rect.fromLTWH(41, 2, 12, 12), fab);
      canvas.drawOval(const Rect.fromLTWH(50, 3, 12, 10), fab);
      canvas.drawLine(const Offset(28, 28), const Offset(72, 28), fold);
  }
  // earrings (under a hijab there are none to see)
  if (!covered) {
    final gold = Paint()..color = const Color(0xFFE8B73A);
    switch (s.of('earrings')) {
      case 1: for (final x in [27.0, 73.0]) { canvas.drawCircle(Offset(x, 55), 1.9, gold); }
      case 2: for (final x in [27.0, 73.0]) { canvas.drawCircle(Offset(x, 58), 3.4, gold..style = PaintingStyle.stroke..strokeWidth = 1.4); }
    }
  }
  // glasses
  final g = s.of('glasses');
  if (g > 0) {
    final gp = Paint()..color = TickPalette.ink..style = PaintingStyle.stroke..strokeWidth = 2;
    const a = Offset(41, 45), c = Offset(59, 45);
    final ra = Rect.fromCenter(center: a, width: 16, height: 12), rc = Rect.fromCenter(center: c, width: 16, height: 12);
    switch (g) {
      case 1: canvas.drawCircle(a, 7.5, gp); canvas.drawCircle(c, 7.5, gp);
      case 2:
        canvas.drawRRect(RRect.fromRectAndRadius(ra, const Radius.circular(3)), gp);
        canvas.drawRRect(RRect.fromRectAndRadius(rc, const Radius.circular(3)), gp);
      default:
        for (final r in [ra, rc]) {
          canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(5)), _clay(r, TickPalette.ink2, light: 0.2));
          canvas.drawOval(Rect.fromLTWH(r.left + 2, r.top + 2, 6, 3), _gloss(Rect.fromLTWH(r.left + 2, r.top + 2, 6, 3), a: 0.5));
        }
    }
    canvas.drawLine(const Offset(49, 45), const Offset(51, 45), gp);
  }
}

/// Features: brows, eyes and mouth, drawn every frame because they blink, wink and change with mood.
void _paintFeatures(Canvas canvas, AvatarSpec s, {required double blink, required double wink, required AvatarMood mood}) {
  if (s.of('glasses') == 3) { _paintMouth(canvas, s, wink, mood); return; }   // sunglasses cover the eyes
  final hair = TickAvatarPalette.hair[s.of('hairColor')];
  final ink = Paint()..color = TickPalette.ink;
  final line = Paint()..color = TickPalette.ink..style = PaintingStyle.stroke..strokeWidth = 2.6..strokeCap = StrokeCap.round;
  final brow = Paint()..color = _shade(hair, -0.05)..style = PaintingStyle.stroke..strokeWidth = 2.8..strokeCap = StrokeCap.round;
  final lift = switch (mood) { AvatarMood.surprised => -3.0, AvatarMood.sad => 1.5, _ => 0.0 };
  final bt = [0.0, -2.0, 2.0][s.of('brows')];
  canvas.drawLine(Offset(36, 37 + bt + lift + (mood == AvatarMood.sad ? -2 : 0)), Offset(46, 37 + lift), brow);
  canvas.drawLine(Offset(54, 37 + lift + (mood == AvatarMood.thinking ? -3 : 0)), Offset(64, 37 + bt + lift + (mood == AvatarMood.sad ? -2 : 0)), brow);
  final look = mood == AvatarMood.thinking ? const Offset(1.2, -1.2) : Offset.zero;
  void eye(double x, double closed) {
    if (closed > 0.6 || (mood == AvatarMood.happy && s.of('eyes') != 2)) {
      canvas.drawArc(Rect.fromCenter(center: Offset(x, 46), width: 9, height: 7), math.pi, math.pi, false, line);
      return;
    }
    final big = mood == AvatarMood.surprised ? 1.25 : 1.0;
    switch (s.of('eyes')) {
      case 0: canvas.drawCircle(Offset(x, 45) + look, 3.2 * big, ink);
      case 1: canvas.drawOval(Rect.fromCenter(center: Offset(x, 45) + look, width: 6 * big, height: 8.5 * big), ink);
      case 2:
        canvas.drawOval(Rect.fromCenter(center: Offset(x, 45), width: 10 * big, height: 10.5 * big), Paint()..color = TickPalette.white);
        canvas.drawCircle(Offset(x + 1, 45.5) + look, 2.8 * big, ink);
      default: canvas.drawArc(Rect.fromCenter(center: Offset(x, 46), width: 9, height: 7), math.pi, math.pi, false, line);
    }
    canvas.drawCircle(Offset(x - 1.1, 43.6) + look, 0.9, Paint()..color = const Color(0xCCFFFFFF));   // a wet highlight
  }
  eye(41, blink);
  eye(59, math.max(blink, wink));
  _paintMouth(canvas, s, wink, mood);
}

void _paintMouth(Canvas canvas, AvatarSpec s, double wink, AvatarMood mood) {
  final ink = Paint()..color = TickPalette.ink;
  final line = Paint()..color = TickPalette.ink..style = PaintingStyle.stroke..strokeWidth = 2.6..strokeCap = StrokeCap.round;
  final m = Rect.fromCenter(center: const Offset(50, 60), width: 18, height: 12);
  final pick = wink > 0.2 ? 2 : switch (mood) { AvatarMood.happy => 2, AvatarMood.surprised => 3, AvatarMood.thinking => 4, AvatarMood.sad => 5, _ => s.of('mouth') };
  switch (pick) {
    case 0: canvas.drawArc(m, 0.2, math.pi - 0.4, false, line);
    case 1: canvas.drawLine(const Offset(44, 62), const Offset(56, 62), line);
    case 2:
      canvas.drawArc(m, 0, math.pi, true, ink);
      canvas.drawArc(Rect.fromCenter(center: const Offset(50, 64.5), width: 9, height: 5), 0, math.pi, true, Paint()..color = const Color(0xFFFF8C73));
    case 3: canvas.drawOval(Rect.fromCenter(center: const Offset(50, 62), width: mood == AvatarMood.surprised ? 7 : 6, height: mood == AvatarMood.surprised ? 8 : 6), ink);
    case 4: canvas.drawArc(m.shift(const Offset(3, 0)), 0.3, 1.6, false, line);
    default: canvas.drawArc(m.shift(const Offset(0, 6)), math.pi + 0.4, math.pi - 0.8, false, line);
  }
}

/// Ask Tick's mascot: a little clay blob with a check on its head. Not a person, on purpose.
void _paintMascotBody(Canvas canvas) {
  canvas.drawRect(const Rect.fromLTWH(0, 0, 100, 100), Paint()..shader = const RadialGradient(center: Alignment(-0.3, -0.5), radius: 1.1, colors: [Color(0xFF2C2C35), Color(0xFF16161B)]).createShader(const Rect.fromLTWH(0, 0, 100, 100)));
  canvas.drawOval(const Rect.fromLTWH(26, 82, 48, 10), Paint()..color = const Color(0x55000000)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
  final body = Path()..moveTo(50, 22)..cubicTo(80, 22, 84, 50, 82, 64)..cubicTo(80, 82, 66, 88, 50, 88)..cubicTo(34, 88, 20, 82, 18, 64)..cubicTo(16, 50, 20, 22, 50, 22);
  canvas.drawPath(body, _clay(const Rect.fromLTWH(16, 20, 68, 70), TickPalette.volt, light: 0.1, dark: 0.22));
  canvas.drawOval(const Rect.fromLTWH(30, 28, 18, 9), _gloss(const Rect.fromLTWH(30, 28, 18, 9), a: 0.45));
  // the check: Tick's mark, as a little crest
  canvas.drawPath(Path()..moveTo(41, 16)..lineTo(48, 22)..lineTo(62, 6), Paint()..color = TickPalette.ink..style = PaintingStyle.stroke..strokeWidth = 4.2..strokeCap = StrokeCap.round..strokeJoin = StrokeJoin.round);
  for (final x in [34.0, 58.0]) { canvas.drawOval(Rect.fromLTWH(x, 84, 9, 6), Paint()..color = _shade(TickPalette.volt, -0.25)); }
}

void _paintMascotFace(Canvas canvas, {required double blink, required double wink, required AvatarMood mood}) {
  final ink = Paint()..color = TickPalette.ink;
  final line = Paint()..color = TickPalette.ink..style = PaintingStyle.stroke..strokeWidth = 3..strokeCap = StrokeCap.round;
  final look = mood == AvatarMood.thinking ? const Offset(2, -2) : Offset.zero;
  void eye(double x, double closed) {
    if (closed > 0.6 || mood == AvatarMood.happy) { canvas.drawArc(Rect.fromCenter(center: Offset(x, 52), width: 11, height: 8), math.pi, math.pi, false, line); return; }
    final r = mood == AvatarMood.surprised ? 6.0 : 5.0;
    canvas.drawOval(Rect.fromCenter(center: Offset(x, 51) + look, width: r * 1.7, height: r * 2.1), ink);
    canvas.drawCircle(Offset(x - 1.5, 48.5) + look, 1.6, Paint()..color = const Color(0xE6FFFFFF));
  }
  eye(40, blink);
  eye(60, math.max(blink, wink));
  final m = Rect.fromCenter(center: const Offset(50, 64), width: 14, height: 9);
  switch (wink > 0.2 ? AvatarMood.happy : mood) {
    case AvatarMood.happy: canvas.drawArc(m, 0, math.pi, true, ink);
    case AvatarMood.surprised: canvas.drawOval(Rect.fromCenter(center: const Offset(50, 66), width: 6, height: 7), ink);
    case AvatarMood.thinking: canvas.drawLine(const Offset(46, 66), const Offset(55, 64), line);
    case AvatarMood.sad: canvas.drawArc(m.shift(const Offset(0, 5)), math.pi + 0.4, math.pi - 0.8, false, line);
    case AvatarMood.neutral: canvas.drawArc(m, 0.3, math.pi - 0.6, false, line);
  }
}

class _Face extends CustomPainter {
  _Face(this.s, {this.mascot = false, this.blink = 0, this.wink = 0, this.bob = 0, this.tilt = 0, this.parallax = Offset.zero, this.mood = AvatarMood.neutral});
  final AvatarSpec s;
  final bool mascot;
  final double blink, wink, bob, tilt;
  final Offset parallax;
  final AvatarMood mood;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 100);
    canvas.clipPath(Path()..addOval(const Rect.fromLTWH(0, 0, 100, 100)));
    final key = mascot ? 'mascot' : s.cacheKey;
    // back moves least, the head more, the features most: that's the depth
    canvas.save();
    canvas.translate(-parallax.dx * 0.5, -parallax.dy * 0.5);
    canvas.drawPicture(AvatarLayerCache.get('$key/back', (c) => mascot ? _paintMascotBody(c) : _paintBack(c, s)));
    canvas.restore();
    canvas.save();
    canvas.translate(parallax.dx, bob + parallax.dy);
    canvas.translate(50, 76); canvas.rotate(tilt); canvas.translate(-50, -76);
    if (!mascot) canvas.drawPicture(AvatarLayerCache.get('$key/head', (c) => _paintHead(c, s)));
    canvas.translate(parallax.dx * 0.4, parallax.dy * 0.4);
    if (mascot) {
      _paintMascotFace(canvas, blink: blink, wink: wink, mood: mood);
    } else {
      _paintFeatures(canvas, s, blink: blink, wink: wink, mood: mood);
    }
    canvas.restore();
  }
  @override
  bool shouldRepaint(_Face o) => o.s.v != s.v || o.mascot != mascot || o.blink != blink || o.wink != wink || o.bob != bob || o.tilt != tilt || o.parallax != parallax || o.mood != mood;
}

/// Device tilt for parallax, shared by every live avatar and only listened to while one is on screen.
class AvatarTilt {
  AvatarTilt._();
  static final value = ValueNotifier<Offset>(Offset.zero);
  static StreamSubscription<AccelerometerEvent>? _sub;
  static int _users = 0;
  /// Off where there's no motion sensor channel (tests, desktop); tests can still set [value].
  static bool enabled = !kIsWeb && Platform.isIOS;
  static void attach() {
    if (_users++ > 0 || !enabled) return;
    try {
      _sub = accelerometerEventStream(samplingPeriod: SensorInterval.uiInterval).listen((e) {
        // low-pass: the phone in a hand jitters, the avatar shouldn't
        final next = Offset((e.x / 9.8).clamp(-1.0, 1.0), (-e.y / 9.8 + 0.6).clamp(-1.0, 1.0));
        value.value = Offset.lerp(value.value, next, 0.12)!;
      }, onError: (_) { _sub?.cancel(); _sub = null; }, cancelOnError: true);
    } catch (_) {/* no sensor (tests, simulator): no parallax */}
  }
  static void detach() {
    if (--_users > 0) return;
    _users = 0;
    _sub?.cancel();
    _sub = null;
  }
}

/// A drawn face. [live] blinks, bobs, tilts its head and follows the phone's tilt (big avatars only, so a list stays still and cheap).
/// A tap is a reaction: a wink, a smile and a little bounce, with a light haptic. Reduce Motion keeps it still and skips the bounce.
class TickAvatar extends StatefulWidget {
  const TickAvatar(this.spec, {super.key, this.size = 40, this.live = false, this.tappable = true, this.mood = AvatarMood.neutral, this.mascot = false});
  final AvatarSpec spec;
  final double size;
  final bool live;
  final bool tappable;
  final AvatarMood mood;
  final bool mascot;
  @override
  State<TickAvatar> createState() => _TickAvatarState();
}

class _TickAvatarState extends State<TickAvatar> with TickerProviderStateMixin {
  late final AnimationController _idle = AnimationController(vsync: this, duration: const Duration(milliseconds: TickMotion.avatarIdleMs));
  late final AnimationController _wink = AnimationController(vsync: this, duration: const Duration(milliseconds: TickMotion.avatarWinkMs));
  late final AnimationController _bounce = AnimationController.unbounded(vsync: this, value: 1);
  AvatarMood? _react;
  Timer? _reactTimer;
  bool _tilting = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = context.reduceMotion;
    if (widget.live && !still && !_idle.isAnimating) _idle.repeat();
    if (still) _idle.stop();
    final wantTilt = widget.live && !still;
    if (wantTilt != _tilting) { _tilting = wantTilt; wantTilt ? AvatarTilt.attach() : AvatarTilt.detach(); }
  }

  @override
  void dispose() {
    if (_tilting) AvatarTilt.detach();
    _reactTimer?.cancel();
    _idle.dispose(); _wink.dispose(); _bounce.dispose();
    super.dispose();
  }

  void _tap() {
    TickHaptics.instance.selection();
    final next = _react == AvatarMood.happy ? AvatarMood.surprised : AvatarMood.happy;
    setState(() => _react = next);
    _reactTimer?.cancel();
    _reactTimer = Timer(const Duration(milliseconds: TickMotion.avatarReactMs), () { if (mounted) setState(() => _react = null); });
    if (context.reduceMotion) return;
    _wink.animateWith(SpringSimulation(springOf(TickSprings.pop), 0, 1, 0)).whenComplete(() { if (mounted) _wink.reverse(); });
    _bounce.value = 0.92;
    _bounce.animateWith(SpringSimulation(springOf(TickSprings.pop), 0.92, 1, 0));
  }

  @override
  Widget build(BuildContext context) {
    final listen = <Listenable>[_idle, _wink, _bounce, if (_tilting) AvatarTilt.value];
    final body = RepaintBoundary(child: AnimatedBuilder(animation: Listenable.merge(listen), builder: (context, _) {
      final t = _idle.value;
      final blink = (t > 0.94 && t < 0.98) ? 1.0 : 0.0;
      final tilt = widget.live && _idle.isAnimating ? math.sin(t * 2 * math.pi * 0.5) * TickMotion.avatarTiltMaxDeg * math.pi / 180 : 0.0;
      final p = _tilting ? AvatarTilt.value.value * TickMotion.avatarParallaxPx : Offset.zero;
      return Transform.scale(scale: _bounce.value, child: CustomPaint(size: Size.square(widget.size), painter: _Face(widget.spec, mascot: widget.mascot, blink: blink, wink: _wink.value,
          bob: math.sin(t * 2 * math.pi) * TickMotion.avatarBobPx, tilt: tilt, parallax: p, mood: _react ?? widget.mood)));
    }));
    if (!widget.tappable) return ExcludeSemantics(child: body);
    return Semantics(label: widget.mascot ? 'Ask Tick' : 'Avatar', button: true, child: GestureDetector(onTap: _tap, child: body));
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

/// Ask Tick's mascot. [mood] thinking while it works on an answer.
class AskMascot extends StatelessWidget {
  const AskMascot({super.key, this.size = 96, this.mood = AvatarMood.neutral, this.live = true, this.tappable = true});
  final double size;
  final AvatarMood mood;
  final bool live;
  final bool tappable;
  @override
  Widget build(BuildContext context) => TickAvatar(const AvatarSpec({}), size: size, live: live, mood: mood, mascot: true, tappable: tappable);
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
