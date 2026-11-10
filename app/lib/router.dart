import 'dart:async';
import 'package:flutter/foundation.dart';
import 'domain/models.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:go_router/go_router.dart';
import 'data/bank_step.dart';
import 'data/env.dart';
import 'services/api.dart';
import 'services/bank_link.dart';
import 'services/session.dart';
import 'data/settings.dart';
import 'design/widgets/core.dart';
import 'design/widgets/more.dart';
import 'data/nav.dart';
import 'features/activity_screen.dart';
import 'features/import_screen.dart';
import 'features/insights_screen.dart';
import 'features/tally_screen.dart';
import 'features/tally_group_screen.dart';
import 'features/tally_manage.dart';
import 'domain/balances.dart';
import 'features/ask_screen.dart';
import 'features/avatar_builder.dart';
import 'features/pay_screens.dart';
import 'features/review.dart';
import 'features/payday_editor.dart';
import 'features/profile_screen.dart';
import 'features/tally_expense_screen.dart';
import 'features/tally_more.dart';
import 'design/motion.g.dart';
import 'design/widgets/motion.dart';
import 'features/tally_people.dart';
import 'features/tally_split_screen.dart';
import 'features/cards.dart';
import 'features/caught_screen.dart';
import 'features/gallery_screen.dart';
import 'features/incoming_screen.dart';
import 'features/bank_step_screen.dart';
import 'features/intro_cinematic.dart';
import 'features/onboarding_screen.dart';
import 'features/quick_add.dart';
import 'features/receipt_screen.dart';
import 'features/settings_screen.dart';
import 'features/today_screen.dart';
import 'features/txn_detail_screen.dart';
import 'design/theme.dart';
import 'design/tokens.g.dart';
import 'data/ledger.dart';
import 'package:intl/intl.dart';
import 'features/banks_screen.dart';
import 'features/budgets_screen.dart';
import 'features/payday_plan_screen.dart';
import 'domain/notification_plan.dart';
import 'services/haptics.dart';
import 'services/open_file.dart';
import 'services/notifications.dart';
import 'services/widget_sync.dart';
import 'features/tips.dart';

CustomTransitionPage<void> _page(GoRouterState s, Widget child) => CustomTransitionPage<void>(
      key: s.pageKey, child: child, transitionDuration: const Duration(milliseconds: TickMotion.pageInMs), reverseTransitionDuration: const Duration(milliseconds: TickMotion.pageOutMs),
      transitionsBuilder: (ctx, a, sa, ch) {
        if (ctx.reduceMotion) return FadeTransition(opacity: a, child: ch);
        final curved = CurvedAnimation(parent: a, curve: const SpringCurve(TickSprings.standard), reverseCurve: Curves.easeIn);
        return SlideTransition(position: Tween(begin: const Offset(TickMotion.pageFromOffsetX, 0), end: Offset.zero).animate(curved), child: FadeTransition(opacity: a, child: ch));
      },
    );

GoRouter buildRouter(WidgetRef ref, {String initial = '/'}) => GoRouter(
      initialLocation: initial,
      errorBuilder: (context, state) => const _NotFound(),
      redirect: (context, state) {
        // Custom-scheme deep links arrive here as tick://<host>?...: tick://add?amount=18&merchant=Uber opens quick add;
        // anything else (OAuth and Plaid callbacks are consumed by their own sessions) just lands on Today.
        if (state.uri.scheme == 'tick') {
          if (state.uri.host == 'add') {
            final q = state.uri.queryParameters;
            final amt = double.tryParse(q['amount'] ?? '');
            ref.read(pendingQuickAddProvider.notifier).state = PendingQuickAdd(amt == null ? null : (amt * 100).round(), q['merchant']);
          }
          return '/';
        }
        final done = ref.read(settingsProvider).onboardingDone;
        if (!done && state.matchedLocation == '/') return '/onboarding';
        return null;
      },
      routes: [
        GoRoute(path: '/', pageBuilder: (c, s) => NoTransitionPage(key: s.pageKey, child: const Shell())),
        GoRoute(path: '/onboarding', pageBuilder: (c, s) => _page(s, const OnboardingScreen())),
        GoRoute(path: '/intro', pageBuilder: (c, s) => _page(s, const IntroReplayScreen())),
        GoRoute(path: '/onboarding/bank', pageBuilder: (c, s) => _page(s, const BankStepScreen())),
        GoRoute(path: '/caught', pageBuilder: (c, s) => _page(s, const CaughtScreen())),
        GoRoute(path: '/incoming', pageBuilder: (c, s) => _page(s, const IncomingScreen())),
        GoRoute(path: '/landed', pageBuilder: (c, s) => _page(s, IncomingScreen(landed: s.extra as Expected?))),
        GoRoute(path: '/settings', pageBuilder: (c, s) => _page(s, const SettingsScreen())),
        GoRoute(path: '/avatar', pageBuilder: (c, s) => _page(s, AvatarBuilderScreen(member: s.uri.queryParameters['member']))),
        GoRoute(path: '/pay-statements', pageBuilder: (c, s) => _page(s, const PayStatementsScreen())),
        GoRoute(path: '/pay-statements/:id', pageBuilder: (c, s) => _page(s, PayStatementScreen(id: s.pathParameters['id']!))),
        GoRoute(path: '/pay', pageBuilder: (c, s) => _page(s, const PayByMonthScreen())),
        GoRoute(path: '/review', pageBuilder: (c, s) => _page(s, const ReviewQueueScreen())),
        GoRoute(path: '/profile', pageBuilder: (c, s) => _page(s, const ProfileScreen())),
        GoRoute(path: '/settings/ask', pageBuilder: (c, s) => _page(s, const AskSettingsScreen())),
        GoRoute(path: '/settings/payday', pageBuilder: (c, s) => _page(s, const PaydayScreen())),
        GoRoute(path: '/settings/appearance', pageBuilder: (c, s) => _page(s, const SettingsScreen(page: SettingsPage.appearance))),
        GoRoute(path: '/settings/data', pageBuilder: (c, s) => _page(s, const SettingsScreen(page: SettingsPage.data))),
        GoRoute(path: '/settings/labs', pageBuilder: (c, s) => _page(s, const SettingsScreen(page: SettingsPage.labs))),
        GoRoute(path: '/settings/about', pageBuilder: (c, s) => _page(s, const SettingsScreen(page: SettingsPage.about))),
        GoRoute(path: '/budgets', pageBuilder: (c, s) => _page(s, const BudgetsScreen())),
        GoRoute(path: '/payday-plan', pageBuilder: (c, s) => _page(s, const PaydayPlanScreen())),
        GoRoute(path: '/categories', pageBuilder: (c, s) => _page(s, const CategoriesScreen())),
        GoRoute(path: '/import', pageBuilder: (c, s) => _page(s, ImportScreen(path: s.extra as String?))),
        GoRoute(path: '/banks', pageBuilder: (c, s) => _page(s, const BanksScreen())),
        GoRoute(path: '/card/:id', pageBuilder: (c, s) => _page(s, CardScreen(id: s.pathParameters['id']!))),
        GoRoute(path: '/receipt', pageBuilder: (c, s) => _page(s, const ReceiptScreen())),
        GoRoute(path: '/tally/split/:txnId', pageBuilder: (c, s) => _page(s, TallySplitScreen(txnId: s.pathParameters['txnId']!))),
        GoRoute(path: '/tally/plan', pageBuilder: (c, s) => _page(s, const TallyPlanScreen())),
        GoRoute(path: '/tally/:id/receipt', pageBuilder: (c, s) => _page(s, TallyReceiptScreen(id: s.pathParameters['id']!))),
        GoRoute(path: '/tally/inbox', pageBuilder: (c, s) => _page(s, const TallyInboxScreen())),
        GoRoute(path: '/tally/:id', pageBuilder: (c, s) => _page(s, TallyGroupScreen(id: s.pathParameters['id']!))),
        GoRoute(path: '/tally/:id/expense/:eid', pageBuilder: (c, s) => _page(s, TallyExpenseScreen(groupId: s.pathParameters['id']!, id: s.pathParameters['eid']!))),
        GoRoute(path: '/tally/:id/settings', pageBuilder: (c, s) => _page(s, TallyGroupSettingsScreen(id: s.pathParameters['id']!))),
        GoRoute(path: '/tally/:id/activity', pageBuilder: (c, s) => _page(s, TallyActivityScreen(id: s.pathParameters['id']!))),
        GoRoute(path: '/tally/:id/person/:member', pageBuilder: (c, s) => _page(s, TallyPersonScreen(groupId: s.pathParameters['id']!, member: s.pathParameters['member']!))),
        GoRoute(path: '/txn/:id', pageBuilder: (c, s) => _page(s, TxnDetailScreen(id: s.pathParameters['id']!))),
        if (kDebugMode) GoRoute(path: '/dev/gallery', pageBuilder: (c, s) => _page(s, const GalleryScreen())),
      ],
    );

/// A quick-add request from a deep link (tick://add?amount=18&merchant=Uber); the Tab shell opens the sheet.
class PendingQuickAdd {
  const PendingQuickAdd(this.cents, this.merchant);
  final int? cents;
  final String? merchant;
}

final pendingQuickAddProvider = StateProvider<PendingQuickAdd?>((ref) => null);

/// Tab shell: Today · Activity · Flows · Ask Tick with the floating bar and the Add button.
/// Tabs build lazily on first visit and then stay alive; reminders and the widget snapshot re-plan on a debounce, never per state change.
class Shell extends ConsumerStatefulWidget {
  const Shell({super.key});
  @override
  ConsumerState<Shell> createState() => _ShellState();
}

class _ShellState extends ConsumerState<Shell> with WidgetsBindingObserver {
  final Set<int> _built = {0};
  Timer? _syncTimer;
  StreamSubscription<String>? _taps;
  bool _receiptChecked = false;
  bool _asked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _taps = notificationTaps.stream.listen((p) {
      if (!mounted) return;
      // Card reminders carry the account id; only ids that look like ours are routed (a payload is never trusted as a path).
      final card = RegExp(r'^card:([A-Za-z0-9-]{1,64})$').firstMatch(p);
      context.push(card != null ? '/card/${card.group(1)}' : p == 'payday' ? '/payday-plan' : p == 'import' ? '/import' : '/incoming');
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkPendingAdd();
      _maybeAskNotifications();
      _resumePendingLink();
    });
  }

  /// A link the person finished at the bank but the app was killed before exchanging it: finish it now, quietly. Cold start only
  /// (while a Plaid sheet is open in this process the flow itself completes it). The exchange is idempotent.
  Future<void> _resumePendingLink() async {
    if (ref.read(settingsProvider).demoMode) return;
    for (var i = 0; i < 30 && ref.read(userIdProvider) == null; i++) { await Future<void>.delayed(const Duration(milliseconds: 200)); }
    if (!mounted || ref.read(userIdProvider) == null) return;
    final store = ref.read(bankStepStoreProvider);
    final token = store.pendingLink;
    if (token == null) return;
    if (await resumePendingLink(ref.read(apiProvider), token, store.clearPendingLink)) ref.read(ledgerProvider.notifier).refresh();
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    _taps?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkPendingAdd();
      ref.read(ledgerProvider.notifier).refresh();
    }
  }

  void _scheduleSync() {
    _syncTimer?.cancel();
    _syncTimer = Timer(const Duration(seconds: 2), _sync);
  }

  void _sync() {
    if (!mounted) return;
    final l = ref.read(ledgerProvider);
    if (l.loading) return;
    final s = ref.read(settingsProvider);
    final sts = ref.read(safeToSpendProvider);
    final now = ref.read(clockProvider)();
    if (Env.widgetsEnabled) writeWidgetSnapshot(buildWidgetSnapshot(sts: sts, cashCents: homeBalances(l.accounts).cashCents, txns: l.txns, recurring: l.recurring, now: now));
    ref.read(notificationServiceProvider).apply(planNotifications(now: now, morningTime: s.morningTime, weeklyTime: s.weeklyTime, sts: sts, recurring: l.recurring, goals: l.goals, accounts: l.accounts, utilisationAlerts: s.flag('statement_cycle'), statementDay: l.accounts.any((a) => a.institution == 'Apple Card')));
  }

  /// Ask for notification permission once, after onboarding, a moment after the first frame, never at launch of a blank app.
  Future<void> _maybeAskNotifications() async {
    if (_asked) return;
    _asked = true;
    final s = ref.read(settingsProvider);
    if (!s.onboardingDone) return;
    await Future<void>.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    await ref.read(notificationServiceProvider).requestPermission();
    _scheduleSync();
  }

  Future<void> _checkPendingAdd() async {
    final p = await takePendingAdd();
    if (p != null && mounted) {
      final amt = (p['amount'] as num?)?.toDouble();
      showQuickAdd(context, prefillCents: amt == null ? null : (amt * 100).round(), prefillMerchant: p['merchant'] as String?);
    }
  }

  /// First open of the day plays the Morning Receipt first, once, and only when there is something to show.
  void _maybeReceipt(LedgerState l) {
    if (_receiptChecked || l.loading) return;
    final s = ref.read(settingsProvider);
    if (!s.onboardingDone) return;
    _receiptChecked = true;
    final now = ref.read(clockProvider)();
    final today = DateFormat('yyyy-MM-dd').format(now);
    if (s.lastMorningReceipt == today) return;
    if (l.txns.isEmpty) return;
    ref.read(settingsProvider.notifier).update((x) => x.copyWith(lastMorningReceipt: today));   // mark seen at open: "Show me today" can never re-trigger it
    context.push('/receipt');
  }

  @override
  Widget build(BuildContext context) {
    final l = ref.watch(ledgerProvider);
    // A statement handed to Tick ("Open in Tick" from Wallet or Files, or the Shortcuts action) opens the import flow.
    ref.listen(incomingFilesProvider, (prev, next) {
      if (next.isNotEmpty && (prev?.length ?? 0) < next.length) context.push('/import');
    });
    ref.listen(pendingQuickAddProvider, (prev, next) {
      if (next == null) return;
      ref.read(pendingQuickAddProvider.notifier).state = null;
      showQuickAdd(context, prefillCents: next.cents, prefillMerchant: next.merchant);
    });
    ref.listen(ledgerProvider, (prev, next) {
      _scheduleSync();
      _maybeReceipt(next);
      if (next.justLanded != null && prev?.justLanded?.id != next.justLanded!.id) {
        final e = next.justLanded!;
        ref.read(ledgerProvider.notifier).landedShown();
        context.push('/landed', extra: e);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _maybeReceipt(ref.read(ledgerProvider)); });
    final tab = ref.watch(shellTabProvider);
    if (!_built.contains(tab)) _built.add(tab);
    Widget page(int i) => _built.contains(i) ? const [TodayScreen(), ActivityScreen(), InsightsScreen(), TallyScreen()][i] : const SizedBox.shrink();
    // Each tab owns its own safe area and gutters (collapsing large titles need the full width), so the shell adds none.
    return ColoredBox(
      color: context.c.bg,
      child: Stack(clipBehavior: Clip.none, children: [
        Positioned.fill(child: TipHost(bottomInset: 84, child: IndexedStack(index: tab, children: [for (var i = 0; i < 4; i++) page(i)]))),
        Positioned(left: 0, right: 0, bottom: 0, child: TickTabBar(index: tab, badge: l.needsReview.length, onTap: (i) { TickHaptics.instance.selection(); ref.read(shellTabProvider.notifier).go(i); }, onAdd: () => showQuickAdd(context))),
      ]),
    );
  }
}

class _NotFound extends StatelessWidget {
  const _NotFound();
  @override
  Widget build(BuildContext context) => TickScreen(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Text('Nothing here.', style: context.ts(TickType.displayM)),
          const SizedBox(height: 16),
          SizedBox(width: 220, child: PillButton('Back to Today', onTap: () => context.go('/'))),
        ]),
      );
}
