import 'package:flutter/gestures.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';
import '../motion.g.dart';
import '../theme.dart';
import '../tokens.g.dart';
import 'core.dart';

class SwipeAction {
  const SwipeAction(this.label, this.icon, this.onTap, {this.emphasis = false});
  final String label;
  final String icon;
  final VoidCallback onTap;
  final bool emphasis;
}

/// iOS-style row actions: drag left to reveal buttons, they spring open and shut, tap the row to close. Exposed to VoiceOver as custom
/// actions (so no gesture is required), honours Reduce Motion (snaps instead of springing), and never removes the row.
class SwipeActions extends StatefulWidget {
  const SwipeActions({super.key, required this.child, required this.actions, this.onOpen});
  final Widget child;
  final List<SwipeAction> actions;
  final VoidCallback? onOpen;
  @override
  State<SwipeActions> createState() => _SwipeActionsState();
}

class _SwipeActionsState extends State<SwipeActions> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController.unbounded(vsync: this);
  static const _w = 72.0;
  double get _open => _w * widget.actions.length;
  bool _wasOpen = false;

  @override
  void dispose() { _c.dispose(); super.dispose(); }

  void _settle(double to, {double velocity = 0}) {
    if (context.reduceMotion) { _c.value = to; return; }
    _c.animateWith(SpringSimulation(springOf(TickSprings.sheet), _c.value, to, velocity));
  }

  void _end(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0;
    final open = v < -400 || (v.abs() <= 400 && _c.value > _open * 0.4);
    if (open && !_wasOpen) widget.onOpen?.call();
    _wasOpen = open;
    _settle(open ? _open : 0, velocity: -v);
  }

  void _close() { _wasOpen = false; _settle(0); }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Semantics(
      customSemanticsActions: {for (final a in widget.actions) CustomSemanticsAction(label: a.label): a.onTap},
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: (d) => _c.value = (_c.value - d.delta.dx).clamp(0.0, _open * 1.15),
        onHorizontalDragEnd: _end,
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            final x = _c.value.clamp(0.0, _open * 1.15);
            return Stack(children: [
              if (x > 0)
                Positioned(
                  right: 0, top: 0, bottom: 0, width: x,
                  child: ClipRect(child: OverflowBox(
                    alignment: Alignment.centerRight, minWidth: 0, maxWidth: _open, maxHeight: double.infinity,
                    child: Row(children: [
                      for (final a in widget.actions)
                        SizedBox(width: _w, child: Pressable(
                          onTap: () { _close(); a.onTap(); }, semanticLabel: a.label, scale: 0.92,
                          child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                            Container(width: 40, height: 40, decoration: BoxDecoration(color: a.emphasis ? c.accent : c.surface2, shape: BoxShape.circle), alignment: Alignment.center,
                                child: TickIcon(a.icon, size: 20, color: a.emphasis ? c.onAccent : c.text)),
                            const SizedBox(height: 4),
                            Text(a.label, maxLines: 1, overflow: TextOverflow.visible, style: TextStyle(fontFamily: TickFamilies.text, fontWeight: FontWeight.w700, fontSize: 10.5, color: c.textSecondary, decoration: TextDecoration.none)),
                          ])),
                        )),
                    ]),
                  )),
                ),
              Transform.translate(
                offset: Offset(-x, 0),
                child: x > 0 ? GestureDetector(behavior: HitTestBehavior.opaque, onTap: _c.value > 8 ? _close : null, child: AbsorbPointer(absorbing: _c.value > 8, child: widget.child)) : widget.child,
              ),
            ]);
          },
        ),
      ),
    );
  }
}
