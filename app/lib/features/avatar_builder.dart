import 'dart:math' as math;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../data/tally_store.dart';
import '../design/avatar.g.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/avatar.dart';
import '../design/widgets/core.dart';
import '../design/motion.g.dart';
import '../design/widgets/scaffold.dart';
import '../services/api.dart';
import '../services/haptics.dart';

/// The studio's categories, each a list of (layer, label). Colour layers show swatches; the rest show the face with that option.
const avatarCategories = <(String, List<(String, String)>)>[
  ('Face', [('face', 'Shape'), ('eyes', 'Eyes'), ('brows', 'Brows'), ('mouth', 'Mouth')]),
  ('Skin', [('skin', 'Skin tone'), ('mark', 'Freckles and bindi')]),
  ('Hair', [('hair', 'Style'), ('hairColor', 'Colour'), ('beard', 'Facial hair')]),
  ('Headwear', [('hat', 'Style'), ('cloth', 'Fabric and top')]),
  ('Extras', [('glasses', 'Glasses'), ('earrings', 'Earrings')]),
  ('Background', [('background', 'Colour')]),
];

const _swatches = {'skin', 'hairColor', 'cloth', 'background'};

Color swatchOf(String layer, int i) => switch (layer) {
      'skin' => TickAvatarPalette.skin[i],
      'hairColor' => TickAvatarPalette.hair[i],
      'cloth' => TickAvatarPalette.cloth[i],
      _ => TickAvatarPalette.background[i],
    };

/// Build a face, for me or a guest ([member]).
class AvatarBuilderScreen extends ConsumerStatefulWidget {
  const AvatarBuilderScreen({super.key, this.member});
  final String? member;
  @override
  ConsumerState<AvatarBuilderScreen> createState() => _AvatarBuilderState();
}

class _AvatarBuilderState extends ConsumerState<AvatarBuilderScreen> {
  late AvatarSpec _s = () {
    final t = ref.read(tallyProvider);
    final id = widget.member ?? t.myUserId ?? 'me';
    final p = t.person(widget.member ?? t.myMember.values.firstOrNull ?? '');
    return AvatarSpec.parse(p?.avatar, p?.userId ?? id);
  }();
  int _cat = 0;
  bool _busy = false;
  String? _error;

  void _pick(String k, int v) {
    TickHaptics.instance.selection();
    setState(() => _s = _s.withValue(k, v));
  }

  Future<void> _save() async {
    setState(() { _busy = true; _error = null; });
    try {
      await ref.read(tallyProvider.notifier).saveAvatar(widget.member, _s.toJson());
      TickHaptics.instance.confirm();
      if (mounted) context.pop();
    } catch (e) {
      if (mounted) setState(() { _busy = false; _error = describeError(e, action: 'save that'); });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final (_, layers) = avatarCategories[_cat];
    return TickPage(title: 'Avatar', onBack: () => context.pop(), bottomPad: 40, children: [
      Center(child: TickAvatar(_s, size: 140, live: true)),
      const SizedBox(height: 12),
      Center(child: TickChip('Randomise', icon: 'repeat', onTap: () { TickHaptics.instance.selection(); setState(() => _s = AvatarSpec.random(math.Random())); })),
      const SizedBox(height: 16),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (final (i, (name, _)) in avatarCategories.indexed)
            Padding(padding: const EdgeInsets.only(right: 8), child: TickChip(name, on: i == _cat, onTap: () { TickHaptics.instance.selection(); setState(() => _cat = i); })),
        ]),
      ),
      const SizedBox(height: 8),
      for (final (k, label) in layers) ...[
        Padding(padding: const EdgeInsets.only(top: 12, bottom: 8), child: Text(label, style: context.ts(TickType.bodyS, color: c.textSecondary))),
        LayoutBuilder(builder: (context, box) {
          final swatch = _swatches.contains(k);
          final per = swatch ? (box.maxWidth / 52).floor().clamp(4, 10) : (box.maxWidth >= 400 ? 5 : 4);
          final tile = (box.maxWidth - (per - 1) * 8) / per;
          return Wrap(spacing: 8, runSpacing: 8, children: [
            for (var i = 0; i < TickAvatarPalette.options[k]!; i++)
              _Option(
                on: _s.of(k) == i, size: tile, label: '$label ${i + 1}', onTap: () => _pick(k, i),
                child: swatch
                    ? Container(width: tile * 0.7, height: tile * 0.7, decoration: BoxDecoration(color: swatchOf(k, i), shape: BoxShape.circle, border: Border.all(color: c.hairline)))
                    : TickAvatar(_s.withValue(k, i), size: tile - 10, tappable: false),
              ),
          ]);
        }),
      ],
      if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: context.ts(TickType.bodyS, color: c.alert))),
      const SizedBox(height: 20),
      PillButton('Save', busy: _busy, onTap: _save),
    ]);
  }
}

class _Option extends StatelessWidget {
  const _Option({required this.on, required this.size, required this.label, required this.onTap, required this.child});
  final bool on;
  final double size;
  final String label;
  final VoidCallback onTap;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Semantics(label: label, selected: on, button: true, excludeSemantics: true, child: Pressable(
      onTap: onTap,
      child: AnimatedContainer(
        duration: Duration(milliseconds: context.reduceMotion ? 0 : TickMotion.digitMs),
        width: size, height: size, alignment: Alignment.center,
        decoration: BoxDecoration(color: c.surface2, borderRadius: BorderRadius.circular(TickRadius.small), border: Border.all(color: on ? c.accent : const Color(0x00000000), width: 2.5)),
        child: child,
      ),
    ));
  }
}
