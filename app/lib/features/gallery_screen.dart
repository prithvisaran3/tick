import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../design/widgets/more.dart';
import '../services/haptics.dart';

/// Debug-only /dev/gallery: every token, component, sticker and motion, plus a button per haptic.
class GalleryScreen extends StatefulWidget {
  const GalleryScreen({super.key});
  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  int _seg = 0;
  bool _tog = true;
  int _replay = 0;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    Widget h(String t) => SectionLabel(t);
    final colors = {'bg': c.bg, 'surface1': c.surface1, 'surface2': c.surface2, 'hairline': c.hairline, 'text': c.text, 'textSecondary': c.textSecondary, 'accent': c.accent, 'alert': c.alert, 'incoming': c.incoming};
    final haptics = <(String, Future<void> Function())>[
      ('1 The Pop', () => TickHaptics.instance.pop()), ('2 Price weight < \$20', () => TickHaptics.instance.priceWeight(1500)), ('2 Price weight < \$100', () => TickHaptics.instance.priceWeight(5000)),
      ('2 Price weight \$100+', () => TickHaptics.instance.priceWeight(20000)), ('3 Count-up', () => TickHaptics.instance.countUp()), ('4 Hold ramp', () => TickHaptics.instance.holdRamp()),
      ('4 Hold click', () => TickHaptics.instance.holdClick()), ('5 Sort right', () => TickHaptics.instance.sortRight()), ('5 Sort left', () => TickHaptics.instance.sortLeft()),
      ('5 Sort up', () => TickHaptics.instance.sortUp()), ('6 Landed', () => TickHaptics.instance.landed()), ('7 Receipt tick', () => TickHaptics.instance.receiptTick()),
      ('7 Receipt rip', () => TickHaptics.instance.receiptRip()), ('8 Heartbeat', () => TickHaptics.instance.heartbeat()), ('Sound: capture pop', () => TickHaptics.instance.sound('capture_pop')),
    ];
    return TickScreen(
      child: ListView(padding: const EdgeInsets.only(bottom: 60), children: [
        ScreenTitle('Gallery', onBack: () => context.pop()),
        h('Colors'),
        Wrap(spacing: 8, runSpacing: 8, children: [for (final e in colors.entries) Column(children: [Container(width: 64, height: 48, decoration: BoxDecoration(color: e.value, borderRadius: BorderRadius.circular(12), border: Border.all(color: c.hairline))), Text(e.key, style: context.ts(TickType.monoS, size: 10))])]),
        h('Type scale'),
        for (final e in {'heroXL': TickType.heroXL, 'displayL': TickType.displayL, 'title': TickType.title, 'body': TickType.body, 'mono': TickType.mono}.entries) Text('${e.key} · \$214.40', style: context.ts(e.value, size: e.value.size > 40 ? 32 : null)),
        h('Sticker (tap to replay the slap)'),
        Pressable(onTap: () => setState(() => _replay++), child: PopIn(key: ValueKey(_replay), fromTilt: -0.15, onLanded: () => TickHaptics.instance.capturePop(1840), child: Sticker(hole: true, child: Text('\$18.40', style: context.ts(TickType.hero, color: c.onAccent, size: 44))))),
        h('Count-up'),
        CountUpText(key: ValueKey('c$_replay'), cents: 21400, style: context.ts(TickType.hero)),
        h('Buttons and chips'),
        PillButton('Link bank', icon: 'bank', onTap: () {}),
        const SizedBox(height: 8),
        PillButton('Fix', style: PillStyle.ghost, onTap: () {}),
        const SizedBox(height: 8),
        const Wrap(spacing: 8, children: [TickChip('All', on: true), TickChip('Business'), TickChip('Needs review', icon: 'caught')]),
        h('Controls'),
        Segmented(options: const ['Full', 'Subtle', 'Off'], index: _seg, onChanged: (i) => setState(() => _seg = i)),
        const SizedBox(height: 8),
        Row(children: [Expanded(child: Text('Toggle', style: context.ts(TickType.title))), TickToggle(label: 'Toggle', on: _tog, onChanged: (v) => setState(() => _tog = v))]),
        const SizedBox(height: 8),
        HoldToConfirm(label: 'Delete', danger: true, onConfirmed: () {}),
        h('Avatars'),
        const Row(children: [Avatar('Uber', 'ride'), SizedBox(width: 8), Avatar('Blue Bottle', 'food'), SizedBox(width: 8), Avatar('Claude', 'sub'), SizedBox(width: 8), Avatar('Rent', 'home'), SizedBox(width: 8), Avatar('Cursor', 'biz')]),
        h('Skeleton'),
        const Skeleton(height: 40, radius: 12),
        h('Icons'),
        Wrap(spacing: 16, runSpacing: 16, children: [for (final n in ['today', 'activity', 'caught', 'flows', 'ask', 'plus', 'search', 'filter', 'arrow-in', 'arrow-out', 'calendar', 'bank', 'card', 'receipt', 'camera', 'briefcase', 'repeat', 'goal', 'bell', 'lock', 'share', 'trash', 'check', 'settings']) TickIcon(n)]),
        h('Haptics (one pattern, one meaning)'),
        Wrap(spacing: 8, runSpacing: 8, children: [for (final hp in haptics) TickChip(hp.$1, onTap: hp.$2)]),
      ]),
    );
  }
}
