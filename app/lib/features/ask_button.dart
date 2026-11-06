import 'package:flutter/widgets.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../design/widgets/more.dart';
import 'ask_screen.dart';

/// Ask Tick lives behind this avatar button, top-right of Today, Activity, Insights and Tally. It opens as a sheet (spring up from the bottom).
class AskButton extends StatelessWidget {
  const AskButton({super.key});
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Pressable(
      onTap: () => showAskSheet(context), semanticLabel: 'Ask Tick', minSize: 44,
      child: SizedBox(width: 44, height: 44, child: Center(child: Container(
        width: 34, height: 34, decoration: BoxDecoration(color: context.isDark ? c.accent : c.text, shape: BoxShape.circle), alignment: Alignment.center,
        child: TickIcon('insights', size: 18, color: context.isDark ? c.onAccent : c.bg),
      ))),
    );
  }
}

Future<void> showAskSheet(BuildContext context) => showTickSheet<void>(context, full: true, fill: true, builder: (ctx) => const AskSheet());

/// Ask Tick as a sheet: the same chat, with a title row and a close button instead of a tab.
class AskSheet extends StatelessWidget {
  const AskSheet({super.key});
  @override
  Widget build(BuildContext context) => Column(children: [
        Row(children: [
          Expanded(child: Semantics(header: true, child: Text('Ask Tick', style: context.ts(TickType.displayM)))),
          Pressable(onTap: () => Navigator.of(context).maybePop(), semanticLabel: 'Close', minSize: 44, child: SizedBox(width: 44, height: 44, child: Center(child: TickIcon('x', size: 22, color: context.c.textSecondary)))),
        ]),
        const SizedBox(height: 8),
        const Expanded(child: AskScreen(inSheet: true)),
      ]);
}
