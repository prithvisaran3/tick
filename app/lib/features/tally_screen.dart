import 'package:flutter/widgets.dart';
import '../design/widgets/scaffold.dart';
import 'ask_button.dart';
import 'common.dart';

class TallyScreen extends StatelessWidget {
  const TallyScreen({super.key});
  @override
  Widget build(BuildContext context) => const TickPage(title: 'Tally', trailing: AskButton(), bottomPad: 130, children: [EmptyState('All square ✓', 'Split a purchase with a friend and it shows up here.', icon: 'tally')]);
}
