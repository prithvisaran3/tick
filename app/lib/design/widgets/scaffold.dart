import 'package:flutter/widgets.dart';
import '../theme.dart';
import '../tokens.g.dart';
import 'core.dart';
import 'refresh.dart';

/// A horizontally scrolling row of chips. NO fixed height: the row is as tall as its chips (a fixed 36pt box used to clip descenders,
/// "Checkina", "Savinas"), at any Dynamic Type size.
class ChipRow extends StatelessWidget {
  const ChipRow({super.key, required this.children, this.gap = 8, this.padding = EdgeInsets.zero});
  final List<Widget> children;
  final double gap;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        scrollDirection: Axis.horizontal, clipBehavior: Clip.none, padding: padding, physics: const BouncingScrollPhysics(),
        child: Row(children: [for (final (i, c) in children.indexed) ...[if (i > 0) SizedBox(width: gap), c]]),
      );
}

/// A secondary screen with an iOS-style collapsing large title: the big title scrolls away, a compact one takes its place in a
/// pinned bar with a hairline. Handles the status-bar inset itself (no clipped title on scroll), wraps long titles to two lines,
/// and works with pull-to-refresh. [children] are laid out in a sliver list with 20pt gutters; pass [slivers] for long lists.
class TickPage extends StatelessWidget {
  const TickPage({super.key, required this.title, this.onBack, this.trailing, this.children = const [], this.slivers = const [], this.onRefresh,
      this.controller, this.bottomPad = 48, this.subtitle});
  final String title;
  final String? subtitle;
  final VoidCallback? onBack;
  final Widget? trailing;
  final List<Widget> children;
  final List<Widget> slivers;
  final Future<void> Function()? onRefresh;
  final ScrollController? controller;
  final double bottomPad;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final c = context.c;
    // Measure the large title so a two-line title gets the room it needs instead of overlapping what is below it.
    final style = context.ts(TickType.displayL);
    final maxW = mq.size.width - 40 - (onBack != null ? 0 : 0);
    final tp = TextPainter(text: TextSpan(text: title, style: style), textDirection: TextDirection.ltr, maxLines: 2, textScaler: mq.textScaler)..layout(maxWidth: maxW);
    final largeH = tp.height + 12;
    return ColoredBox(
      color: c.bg,
      child: CustomScrollView(
        controller: controller,
        physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
        slivers: [
          SliverPersistentHeader(pinned: true, delegate: _TitleBar(title: title, onBack: onBack, trailing: trailing, top: mq.padding.top, largeHeight: largeH, colors: c, textScaler: mq.textScaler, titleStyle: style, compactStyle: context.ts(TickType.title, size: 17))),
          if (onRefresh != null) TickRefreshSliver(onRefresh: onRefresh!),
          if (subtitle != null) SliverPadding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 8), sliver: SliverToBoxAdapter(child: Text(subtitle!, style: context.ts(TickType.body, color: c.textSecondary)))),
          if (children.isNotEmpty) SliverPadding(padding: const EdgeInsets.symmetric(horizontal: 20), sliver: SliverList(delegate: SliverChildListDelegate(children))),
          ...slivers,
          SliverToBoxAdapter(child: SizedBox(height: bottomPad + mq.padding.bottom)),
        ],
      ),
    );
  }
}

class _TitleBar extends SliverPersistentHeaderDelegate {
  _TitleBar({required this.title, required this.onBack, required this.trailing, required this.top, required this.largeHeight, required this.colors,
      required this.textScaler, required this.titleStyle, required this.compactStyle});
  final String title;
  final VoidCallback? onBack;
  final Widget? trailing;
  final double top;
  final double largeHeight;
  final TickColors colors;
  final TextScaler textScaler;
  final TextStyle titleStyle;
  final TextStyle compactStyle;
  static const bar = 52.0;

  @override
  double get minExtent => top + bar;
  @override
  double get maxExtent => top + bar + largeHeight;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final t = largeHeight == 0 ? 1.0 : (shrinkOffset / largeHeight).clamp(0.0, 1.0);
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final compactOpacity = ((t - 0.55) / 0.45).clamp(0.0, 1.0);
    final largeOpacity = (1 - t * 1.5).clamp(0.0, 1.0);
    return ColoredBox(
      color: colors.bg,
      child: Stack(children: [
        Positioned(
          left: 20, right: 20, bottom: 0, top: top + bar - 4,
          child: Opacity(
            opacity: reduce ? (t < 0.5 ? 1 : 0) : largeOpacity,
            child: Transform.translate(
              offset: Offset(0, reduce ? 0 : -shrinkOffset * 0.25),
              child: Semantics(header: true, child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: titleStyle)),
            ),
          ),
        ),
        Positioned(
          left: 0, right: 0, top: top, height: bar,
          child: Row(children: [
            if (onBack != null) Pressable(onTap: onBack, semanticLabel: 'Back', minSize: 44, child: SizedBox(width: 52, height: 44, child: Center(child: TickIcon('chevron-left', size: 28, color: colors.text))))
            else const SizedBox(width: 20),
            Expanded(child: Opacity(opacity: reduce ? (t > 0.5 ? 1 : 0) : compactOpacity, child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: compactStyle))),
            if (trailing != null) Padding(padding: const EdgeInsets.only(right: 20, left: 8), child: trailing),
          ]),
        ),
        Positioned(left: 0, right: 0, bottom: 0, height: 1, child: Opacity(opacity: compactOpacity, child: ColoredBox(color: colors.hairline))),
      ]),
    );
  }

  @override
  bool shouldRebuild(_TitleBar old) => old.title != title || old.largeHeight != largeHeight || old.top != top || old.colors != colors || old.trailing != trailing || old.textScaler != textScaler;
}
