import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'activity.dart';

/// Which tab the shell shows: 0 Today, 1 Activity, 2 Insights, 3 Tally. A provider so any screen can jump (Insights taps into Activity).
class ShellTab extends Notifier<int> {
  @override
  int build() => 0;
  void go(int i) => state = i;
}

final shellTabProvider = NotifierProvider<ShellTab, int>(ShellTab.new);

/// Show Activity with [q] already applied (a category from Insights, a merchant, a card).
void openActivity(WidgetRef ref, ActivityQuery q) {
  ref.read(activityProvider.notifier).setQuery(q);
  ref.read(shellTabProvider.notifier).go(1);
}
