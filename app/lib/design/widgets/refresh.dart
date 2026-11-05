import 'package:flutter/cupertino.dart' show CupertinoSliverRefreshControl, RefreshIndicatorMode;
import 'package:flutter/widgets.dart';
import '../theme.dart';
import 'core.dart';

/// Pull-to-refresh in Tick's language: the three-dot loader pulses as you pull, then loops while loading. No platform spinner.
class TickRefreshSliver extends StatelessWidget {
  const TickRefreshSliver({super.key, required this.onRefresh});
  final Future<void> Function() onRefresh;
  @override
  Widget build(BuildContext context) => CupertinoSliverRefreshControl(
        onRefresh: onRefresh, refreshTriggerPullDistance: 80, refreshIndicatorExtent: 56,
        builder: (context, mode, pulled, trigger, indicator) {
          final t = (pulled / trigger).clamp(0.0, 1.0);
          return Center(
            child: Opacity(
              opacity: mode == RefreshIndicatorMode.inactive ? 0 : (mode == RefreshIndicatorMode.refresh ? 1 : t),
              child: Semantics(label: 'Refreshing', child: TickLoader(color: context.c.textSecondary)),
            ),
          );
        },
      );
}

/// A scroll view that always supports pull-to-refresh (even when content is short) and bounces like the rest of the app.
class TickScrollView extends StatelessWidget {
  const TickScrollView({super.key, required this.slivers, this.onRefresh, this.controller});
  final List<Widget> slivers;
  final Future<void> Function()? onRefresh;
  final ScrollController? controller;
  @override
  Widget build(BuildContext context) => CustomScrollView(
        controller: controller,
        physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
        slivers: [if (onRefresh != null) TickRefreshSliver(onRefresh: onRefresh!), ...slivers],
      );
}
