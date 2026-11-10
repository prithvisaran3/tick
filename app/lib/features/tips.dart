import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/remote.dart';
import '../data/settings.dart';
import '../design/motion.g.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../design/widgets/motion.dart';
import '../services/haptics.dart';

/// The four tips, in the order they're offered. Each shows only where its target is on screen.
const tipOrder = ['home-cash', 'activity-suggestion', 'tally-new', 'ask-tick'];
const tipText = {
  'home-cash': 'Tap to see every account',
  'activity-suggestion': 'Tap a question to see why Tick asks and what each answer does',
  'tally-new': 'Start a tally for a trip, a flat or one dinner',
  'ask-tick': 'Ask Tick anything about your money',
};

/// Where each tip's target is. Plain registry: targets come and go without rebuilding anything.
class TipRegistry {
  final Map<String, GlobalKey> keys = {};
}

final tipRegistryProvider = Provider<TipRegistry>((ref) => TipRegistry());

/// Marks tips done here and on the server profile (profiles.tips), so they don't come back on another install.
void markTipsDone(WidgetRef ref, Iterable<String> ids) {
  final done = {...ref.read(settingsProvider).tipsDone, ...ids}.toList();
  ref.read(settingsProvider.notifier).update((s) => s.copyWith(tipsDone: done));
}

/// Wrap the thing a tip points at. Tapping it counts as seeing the tip; the tap still goes through.
class TipTarget extends ConsumerStatefulWidget {
  const TipTarget({super.key, required this.id, required this.child});
  final String id;
  final Widget child;
  @override
  ConsumerState<TipTarget> createState() => _TipTargetState();
}

class _TipTargetState extends ConsumerState<TipTarget> {
  final _key = GlobalKey();
  late final TipRegistry _reg = ref.read(tipRegistryProvider);
  @override
  void initState() { super.initState(); _reg.keys[widget.id] = _key; }
  @override
  void dispose() { if (_reg.keys[widget.id] == _key) _reg.keys.remove(widget.id); super.dispose(); }
  @override
  Widget build(BuildContext context) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerUp: (_) { if (!ref.read(settingsProvider).tipsDone.contains(widget.id)) markTipsDone(ref, [widget.id]); },
        child: KeyedSubtree(key: _key, child: widget.child),
      );
}

/// Is this target on screen enough to point at? At least 80% inside [screen], on the current route (not under a sheet), on the visible tab.
Rect? visibleTargetRect(BuildContext ctx, Rect screen) {
  final box = ctx.findRenderObject();
  if (box is! RenderBox || !box.attached || !box.hasSize || box.size.isEmpty) return null;
  if (!TickerMode.valuesOf(ctx).enabled) return null;                 // a tab that isn't showing
  final route = ModalRoute.of(ctx);
  if (route != null && !route.isCurrent) return null;                // something is on top of it
  final r = box.localToGlobal(Offset.zero) & box.size;
  final inside = r.intersect(screen);
  if (inside.width <= 0 || inside.height <= 0) return null;
  return (inside.width * inside.height) / (r.width * r.height) >= 0.8 ? r : null;
}

/// Hosts the tips over the app shell: dims everything but the target, points at it, and lets taps through.
class TipHost extends ConsumerStatefulWidget {
  const TipHost({super.key, required this.child, this.bottomInset = 0});
  final Widget child;
  final double bottomInset;    // the tab bar: a target behind it isn't visible
  @override
  ConsumerState<TipHost> createState() => _TipHostState();
}

class _TipHostState extends ConsumerState<TipHost> {
  Timer? _timer;
  String? _id;
  Rect? _rect;
  final _self = GlobalKey();

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 400), (_) => _check());
    _pull();
  }

  Future<void> _pull() async {
    final r = ref.read(remoteProvider);
    if (r == null) return;
    try {
      final server = await r.loadTips();
      if (mounted && server.any((id) => !ref.read(settingsProvider).tipsDone.contains(id))) markTipsDone(ref, server);
    } catch (_) {/* local copy is enough */}
  }

  @override
  void dispose() { _timer?.cancel(); super.dispose(); }

  void _check() {
    if (!mounted) return;
    final done = ref.read(settingsProvider).tipsDone;
    final host = _self.currentContext?.findRenderObject();
    String? id;
    Rect? rect;
    if (host is RenderBox && host.hasSize && done.length < tipOrder.length) {
      final pad = MediaQuery.paddingOf(context);
      final origin = host.localToGlobal(Offset.zero);
      final screen = Rect.fromLTRB(origin.dx, origin.dy + pad.top, origin.dx + host.size.width, origin.dy + host.size.height - math.max(pad.bottom, widget.bottomInset));
      for (final t in tipOrder) {
        if (done.contains(t)) continue;
        final ctx = ref.read(tipRegistryProvider).keys[t]?.currentContext;
        final r = ctx == null ? null : visibleTargetRect(ctx, screen);
        if (r != null) { id = t; rect = r.shift(-origin); break; }
      }
    }
    if (id != _id || rect != _rect) setState(() { _id = id; _rect = rect; });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(settingsProvider.select((s) => s.tipsDone), (prev, next) {
      _check();
      final r = ref.read(remoteProvider);
      if (r != null && prev != null && prev.length != next.length) r.saveTips(next).catchError((_) {});
    });
    return NotificationListener<ScrollNotification>(
      onNotification: (_) { WidgetsBinding.instance.addPostFrameCallback((_) => _check()); return false; },
      child: Stack(key: _self, clipBehavior: Clip.none, children: [
        Positioned.fill(child: widget.child),
        if (_id != null && _rect != null) Positioned.fill(child: _Coach(key: ValueKey(_id), id: _id!, hole: _rect!)),
      ]),
    );
  }
}

class _Coach extends ConsumerWidget {
  const _Coach({super.key, required this.id, required this.hole});
  final String id;
  final Rect hole;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final reduce = context.reduceMotion;
    final spot = hole.inflate(8);
    return LayoutBuilder(builder: (context, box) {
      final below = spot.center.dy < box.maxHeight / 2;
      final width = math.min(box.maxWidth - 32, 300.0);
      final left = (spot.center.dx - width / 2).clamp(16.0, box.maxWidth - 16 - width);
      final arrowX = (spot.center.dx - left).clamp(24.0, width - 24);
      final bubble = Container(
        width: width,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
        decoration: BoxDecoration(color: c.surface2, borderRadius: BorderRadius.circular(TickRadius.card)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Text(tipText[id]!, style: context.ts(TickType.title, size: 16)),
          const SizedBox(height: 8),
          Row(children: [
            Pressable(
              onTap: () { TickHaptics.instance.selection(); markTipsDone(ref, tipOrder); },
              semanticLabel: 'Skip tips',
              child: Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Text('Skip tips', style: context.ts(TickType.bodyS, color: c.textSecondary))),
            ),
            const Spacer(),
            PillButton('Got it', expand: false, height: 40, onTap: () { TickHaptics.instance.selection(); markTipsDone(ref, [id]); }),
          ]),
        ]),
      );
      final arrow = CustomPaint(size: const Size(20, 10), painter: _Arrow(color: c.surface2, up: below));
      final tip = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (below) Padding(padding: EdgeInsets.only(left: arrowX - 10), child: arrow),
        bubble,
        if (!below) Padding(padding: EdgeInsets.only(left: arrowX - 10), child: arrow),
      ]);
      return Stack(children: [
        // The dim never takes a tap: the target and everything else still work.
        Positioned.fill(child: IgnorePointer(child: _fadeIn(reduce, CustomPaint(painter: _Spotlight(hole: spot, color: const Color(0x99000000)))))),
        Positioned(
          left: left, width: width,
          top: below ? spot.bottom + 4 : null,
          bottom: below ? null : box.maxHeight - spot.top + 4,
          child: _fadeIn(reduce, tip, pop: !reduce, fromTop: below),
        ),
      ]);
    });
  }

  Widget _fadeIn(bool reduce, Widget child, {bool pop = false, bool fromTop = true}) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: Duration(milliseconds: reduce ? TickMotion.reduceMotionFadeMs : TickMotion.pageInMs),
        curve: reduce ? Curves.linear : const SpringCurve(TickSprings.standard),
        builder: (context, v, child) => Opacity(
          opacity: v.clamp(0.0, 1.0),
          child: pop ? Transform.translate(offset: Offset(0, (1 - v) * (fromTop ? -8 : 8)), child: child) : child,
        ),
        child: child,
      );
}

/// Everything dimmed except a rounded hole around the target.
class _Spotlight extends CustomPainter {
  _Spotlight({required this.hole, required this.color});
  final Rect hole;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRRect(RRect.fromRectAndRadius(hole, const Radius.circular(TickRadius.card)));
    canvas.drawPath(path, Paint()..color = color);
  }
  @override
  bool shouldRepaint(_Spotlight old) => old.hole != hole || old.color != color;
}

class _Arrow extends CustomPainter {
  _Arrow({required this.color, required this.up});
  final Color color;
  final bool up;
  @override
  void paint(Canvas canvas, Size s) {
    final p = up
        ? (Path()..moveTo(0, s.height)..lineTo(s.width / 2, 0)..lineTo(s.width, s.height)..close())
        : (Path()..moveTo(0, 0)..lineTo(s.width / 2, s.height)..lineTo(s.width, 0)..close());
    canvas.drawPath(p, Paint()..color = color);
  }
  @override
  bool shouldRepaint(_Arrow old) => old.color != color || old.up != up;
}
