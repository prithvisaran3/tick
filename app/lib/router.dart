import 'package:flutter/foundation.dart';
import 'domain/models.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'data/settings.dart';
import 'design/widgets/more.dart';
import 'features/activity_screen.dart';
import 'features/ask_screen.dart';
import 'features/caught_screen.dart';
import 'features/flows_screen.dart';
import 'features/gallery_screen.dart';
import 'features/incoming_screen.dart';
import 'features/onboarding_screen.dart';
import 'features/quick_add.dart';
import 'features/receipt_screen.dart';
import 'features/settings_screen.dart';
import 'features/today_screen.dart';
import 'features/txn_detail_screen.dart';
import 'design/theme.dart';
import 'data/ledger.dart';
import 'package:intl/intl.dart';
import 'features/banks_screen.dart';
import 'domain/notification_plan.dart';
import 'services/notifications.dart';
import 'services/widget_sync.dart';

CustomTransitionPage<void> _page(GoRouterState s, Widget child) => CustomTransitionPage<void>(
      key: s.pageKey, child: child, transitionDuration: const Duration(milliseconds: 380), reverseTransitionDuration: const Duration(milliseconds: 260),
      transitionsBuilder: (ctx, a, sa, ch) {
        if (ctx.reduceMotion) return FadeTransition(opacity: a, child: ch);
        final curved = CurvedAnimation(parent: a, curve: Curves.easeOutBack, reverseCurve: Curves.easeIn);
        return SlideTransition(position: Tween(begin: const Offset(0.12, 0), end: Offset.zero).animate(curved), child: FadeTransition(opacity: a, child: ch));
      },
    );

GoRouter buildRouter(WidgetRef ref, {String initial = '/'}) => GoRouter(
      initialLocation: initial,
      redirect: (context, state) {
        final done = ref.read(settingsProvider).onboardingDone;
        if (!done && state.matchedLocation == '/') return '/onboarding';
        return null;
      },
      routes: [
        GoRoute(path: '/', pageBuilder: (c, s) => NoTransitionPage(key: s.pageKey, child: const Shell())),
        GoRoute(path: '/onboarding', pageBuilder: (c, s) => _page(s, const OnboardingScreen())),
        GoRoute(path: '/caught', pageBuilder: (c, s) => _page(s, const CaughtScreen())),
        GoRoute(path: '/incoming', pageBuilder: (c, s) => _page(s, const IncomingScreen())),
        GoRoute(path: '/landed', pageBuilder: (c, s) => _page(s, IncomingScreen(landed: s.extra as Expected?))),
        GoRoute(path: '/settings', pageBuilder: (c, s) => _page(s, const SettingsScreen())),
        GoRoute(path: '/categories', pageBuilder: (c, s) => _page(s, const CategoriesScreen())),
        GoRoute(path: '/banks', pageBuilder: (c, s) => _page(s, const BanksScreen())),
        GoRoute(path: '/receipt', pageBuilder: (c, s) => _page(s, const ReceiptScreen())),
        GoRoute(path: '/txn/:id', pageBuilder: (c, s) => _page(s, TxnDetailScreen(id: s.pathParameters['id']!))),
        GoRoute(path: '/add', pageBuilder: (c, s) => NoTransitionPage(key: s.pageKey, child: _AddRedirect(amount: s.uri.queryParameters['amount'], merchant: s.uri.queryParameters['merchant']))),
        if (kDebugMode) GoRoute(path: '/dev/gallery', pageBuilder: (c, s) => _page(s, const GalleryScreen())),
      ],
    );

/// Deep link tick://add?amount=18&merchant=Uber (App Intent / Shortcuts) -> quick add prefilled.
class _AddRedirect extends StatefulWidget {
  const _AddRedirect({this.amount, this.merchant});
  final String? amount;
  final String? merchant;
  @override
  State<_AddRedirect> createState() => _AddRedirectState();
}

class _AddRedirectState extends State<_AddRedirect> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      context.go('/');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final cents = widget.amount == null ? null : (double.tryParse(widget.amount!) == null ? null : (double.parse(widget.amount!) * 100).round());
      if (mounted) showQuickAdd(context, prefillCents: cents, prefillMerchant: widget.merchant);
    });
  }
  @override
  Widget build(BuildContext context) => const SizedBox();
}

/// Tab shell: Today · Activity · Flows · Ask Tick with the floating bar and the Add button.
class Shell extends ConsumerStatefulWidget {
  const Shell({super.key});
  @override
  ConsumerState<Shell> createState() => _ShellState();
}

class _ShellState extends ConsumerState<Shell> with WidgetsBindingObserver {
  int _i = 0;
  bool _receiptChecked = false;

  void _sync() {
    final l = ref.read(ledgerProvider);
    final s = ref.read(settingsProvider);
    final sts = ref.read(safeToSpendProvider);
    final now = ref.read(clockProvider)();
    writeWidgetSnapshot(buildWidgetSnapshot(sts: sts, txns: l.txns, recurring: l.recurring, now: now));
    {
      ref.read(notificationServiceProvider).apply(planNotifications(now: now, morningTime: s.morningTime, weeklyTime: s.weeklyTime, sts: sts, recurring: l.recurring, goals: l.goals));
    }
  }

  Future<void> _checkPendingAdd() async {
    final p = await takePendingAdd();
    if (p != null && mounted) {
      final amt = (p['amount'] as num?)?.toDouble();
      showQuickAdd(context, prefillCents: amt == null ? null : (amt * 100).round(), prefillMerchant: p['merchant'] as String?);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkPendingAdd();
  }

  @override
  void dispose() { WidgetsBinding.instance.removeObserver(this); super.dispose(); }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(notificationServiceProvider).requestPermission().then((_) => _sync());
      _checkPendingAdd();
      // First open of the day plays the Morning Receipt first.
      if (_receiptChecked) return;
      _receiptChecked = true;
      final s = ref.read(settingsProvider);
      final today = DateFormat('yyyy-MM-dd').format(ref.read(clockProvider)());
      if (s.onboardingDone && s.lastMorningReceipt != today) context.push('/receipt');
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = ref.watch(ledgerProvider);
    ref.listen(ledgerProvider, (_, _) => _sync());
    final pages = [const TodayScreen(), const ActivityScreen(), const FlowsScreen(), const AskScreen()];
    return TickScreen(
      child: Stack(children: [
        Positioned.fill(child: IndexedStack(index: _i, children: pages)),
        Positioned(left: -20, right: -20, bottom: 0, child: TickTabBar(index: _i, badge: l.needsReview.length, onTap: (i) => setState(() => _i = i), onAdd: () => showQuickAdd(context))),
      ]),
    );
  }
}
