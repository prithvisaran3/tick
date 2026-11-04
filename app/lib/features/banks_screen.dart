import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../data/ledger.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../design/widgets/more.dart';

/// Bank connections. Plaid Link wiring lands in P4 (see services/plaid.dart).
class BanksScreen extends ConsumerWidget {
  const BanksScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = ref.watch(ledgerProvider);
    final c = context.c;
    final left = 10 - l.linksUsed;
    return TickScreen(
      child: ListView(children: [
        ScreenTitle('Banks', onBack: () => context.pop()),
        TickCard(child: Text('You have $left of 10 bank links left.', style: context.ts(TickType.title))),
        const SizedBox(height: 8),
        Text('Removing a link doesn\'t give the slot back.', style: context.ts(TickType.bodyS, color: c.textSecondary)),
      ]),
    );
  }
}
