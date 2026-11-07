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
import '../design/widgets/scaffold.dart';
import '../services/api.dart';
import '../services/haptics.dart';

const avatarLayers = <(String, String)>[('face', 'Face'), ('skin', 'Skin tone'), ('hair', 'Hair'), ('hairColor', 'Hair colour'), ('eyes', 'Eyes'), ('brows', 'Brows'), ('mouth', 'Mouth'), ('glasses', 'Glasses'), ('hat', 'Hat'), ('beard', 'Facial hair'), ('background', 'Background')];

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
  bool _busy = false;
  String? _error;

  void _step(String k, int d) {
    final n = TickAvatarPalette.options[k]!;
    TickHaptics.instance.selection();
    setState(() => _s = _s.withValue(k, (_s.of(k) + d + n) % n));
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
    return TickPage(title: 'Avatar', onBack: () => context.pop(), bottomPad: 40, children: [
      Center(child: TickAvatar(_s, size: 140, live: true)),
      const SizedBox(height: 12),
      Center(child: TickChip('Randomise', icon: 'repeat', onTap: () { TickHaptics.instance.selection(); setState(() => _s = AvatarSpec.random(math.Random())); })),
      const SizedBox(height: 12),
      TickCard(padding: const EdgeInsets.symmetric(horizontal: 8), child: Column(children: [
        for (final (i, (k, label)) in avatarLayers.indexed) ...[
          if (i > 0) const Hairline(),
          Row(children: [
            Pressable(onTap: () => _step(k, -1), semanticLabel: 'Previous $label', minSize: 44, child: SizedBox(width: 44, height: 44, child: Center(child: TickIcon('chevron-left', size: 20, color: c.textSecondary)))),
            Expanded(child: Text(label, textAlign: TextAlign.center, style: context.ts(TickType.body))),
            Pressable(onTap: () => _step(k, 1), semanticLabel: 'Next $label', minSize: 44, child: SizedBox(width: 44, height: 44, child: Center(child: TickIcon('chevron-right', size: 20, color: c.textSecondary)))),
          ]),
        ],
      ])),
      if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: context.ts(TickType.bodyS, color: c.alert))),
      const SizedBox(height: 16),
      PillButton('Save', busy: _busy, onTap: _save),
    ]);
  }
}
