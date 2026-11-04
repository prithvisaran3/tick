import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../data/env.dart';
import '../data/ledger.dart';
import '../data/settings.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../design/widgets/more.dart';
import '../design/widgets/pickers.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import '../domain/natural_input.dart';
import '../domain/payday.dart';
import '../services/auth.dart';
import '../services/haptics.dart';

/// Three steps: welcome + Google, paycheck, the big stuff (rent, goal) or demo data.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key, this.initialStep = 0});
  final int initialStep;
  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  late int _step = widget.initialStep;
  String? _error;
  bool _busy = false;
  // paycheck
  int _freq = 1;
  int _dateIdx = 0;
  DateTime? _customDate;
  String _amount = '';
  // basics
  String _rent = '';
  String _savings = '';
  int _field = 0; // 0 = rent, 1 = savings

  List<DateTime> _dateOptions(DateTime now) {
    var d = dayOnly(now);
    while (d.weekday != DateTime.friday) { d = d.add(const Duration(days: 1)); }
    return [d, d.add(const Duration(days: 7)), d.add(const Duration(days: 14))];
  }

  Future<void> _google() async {
    setState(() { _busy = true; _error = null; });
    try {
      if (!Env.hasSupabase) throw StateError('no config');
      await ref.read(authServiceProvider).signInWithGoogle();
      final name = ref.read(authServiceProvider).displayName;
      ref.read(settingsProvider.notifier).update((s) => s.copyWith(name: name));
      await ref.read(ledgerProvider.notifier).refresh();
      if (mounted) setState(() { _step = 1; _busy = false; });
    } catch (_) {
      if (mounted) setState(() { _error = 'That didn\'t go through. Try again, nothing was lost.'; _busy = false; });
    }
  }

  void _key(String k, String Function() get, void Function(String) set) {
    var a = get();
    if (k == '<') { if (a.isNotEmpty) a = a.substring(0, a.length - 1); }
    else if (k == '.') { if (!a.contains('.')) a = a.isEmpty ? '0.' : '$a.'; }
    else if (a.length < 9 && !RegExp(r'\.\d\d$').hasMatch(a)) { a += k; }
    setState(() => set(a));
  }

  Future<void> _finish({bool demo = false}) async {
    final n = ref.read(settingsProvider.notifier);
    final now = ref.read(clockProvider)();
    if (demo) {
      n.update((s) => s.copyWith(demoMode: true, onboardingDone: true));
    } else {
      final amt = parseCents(_amount) ?? 0;
      final freq = [PayFrequency.weekly, PayFrequency.biweekly, PayFrequency.semimonthly, PayFrequency.monthly][_freq];
      n.update((s) => s.copyWith(rule: PaydayRule(frequency: freq, anchor: _dateIdx < 0 && _customDate != null ? _customDate! : _dateOptions(now)[_dateIdx.clamp(0, 2)], amountCents: amt), onboardingDone: true));
      final led = ref.read(ledgerProvider.notifier);
      final save = parseCents(_savings);
      if (save != null && save > 0) await led.saveGoal(Goal(id: 'local-g-savings', name: 'Savings', targetCents: save * 24, savedCents: 0, perPaydayCents: save));
      final rent = parseCents(_rent);
      if (rent != null && rent > 0) await led.addRecurring(Recurring(id: 'local-rent', merchant: 'Rent', cadence: Cadence.monthly, expectedCents: rent, nextDate: nextDayOfMonth(1, now), categoryId: 'cat-rent', priceHistory: [rent]));
    }
    TickHaptics.instance.pop();
    if (mounted) context.go('/');
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final now = ref.watch(clockProvider)();
    final dots = Row(mainAxisSize: MainAxisSize.min, children: [
      for (var i = 0; i < 3; i++) Container(margin: const EdgeInsets.only(left: 6), width: i == _step ? 24 : 8, height: 8, decoration: BoxDecoration(color: i == _step ? c.text : c.hairline, borderRadius: BorderRadius.circular(8))),
    ]);
    Widget body;
    if (_step == 0) {
      body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SizedBox(height: 56),
        Center(child: PopIn(fromTilt: -0.15, child: Sticker(hole: true, padding: const EdgeInsets.fromLTRB(40, 16, 32, 16), child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('\$214', style: context.ts(TickType.heroXL, color: c.onAccent, size: 70)),
          Text('Safe to spend until Friday', style: TextStyle(fontFamily: TickFamilies.text, fontWeight: FontWeight.w900, fontSize: 14, color: c.onAccent, decoration: TextDecoration.none)),
        ])))),
        const SizedBox(height: 48),
        Text('Know where you stand in three seconds.', style: context.ts(TickType.displayL, size: 42)),
        const SizedBox(height: 16),
        Text('Tick catches every purchase and tells you what is safe to spend until payday.', style: context.ts(TickType.bodyL, color: c.textSecondary)),
        const Spacer(),
        if (_error == null) Center(child: Text('Your data stays yours. Only you can read it.', style: context.ts(TickType.bodyS, color: c.textSecondary))),
        const SizedBox(height: 8),
        if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(_error!, style: context.ts(TickType.body, color: c.alert))),
        PillButton(_busy ? 'Signing in…' : 'Continue with Google', style: PillStyle.inverse, onTap: _busy ? null : _google),
        const SizedBox(height: 8),
        Center(child: Pressable(onTap: () => setState(() => _step = 1), semanticLabel: 'Skip sign in', child: Padding(padding: const EdgeInsets.all(8), child: Text('Look around first', style: context.ts(TickType.body, color: c.textSecondary).copyWith(fontWeight: FontWeight.w700))))),
        const SizedBox(height: 28),
      ]);
    } else if (_step == 1) {
      final dates = _dateOptions(now);
      body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SizedBox(height: 16),
        Text('When do you get paid?', style: context.ts(TickType.displayL)),
        const SizedBox(height: 16),
        Segmented(options: const ['Weekly', 'Biweekly', 'Twice a month', 'Monthly'], index: _freq, onChanged: (i) => setState(() => _freq = i)),
        const SizedBox(height: 16),
        SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [
          for (var i = 0; i < 2; i++) ...[if (i > 0) const SizedBox(width: 8), TickChip(DateFormat('EEE MMM d').format(dates[i]), on: i == _dateIdx, onTap: () => setState(() => _dateIdx = i))],
          const SizedBox(width: 8),
          TickChip(_customDate == null ? 'Pick date' : DateFormat('EEE MMM d').format(_customDate!), icon: 'calendar', on: _dateIdx < 0, onTap: () async {
            final d = await showDateSheet(context, initial: _customDate ?? dates.first);
            if (d != null) setState(() { _customDate = d; _dateIdx = -1; });
          }),
        ])),
        const SizedBox(height: 16),
        Center(child: Column(children: [
          Sticker(padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 12), child: Text('\$${_amount.isEmpty ? '0' : _amount}', style: context.ts(TickType.hero, color: c.onAccent, size: 52))),
          const SizedBox(height: 8),
          Text('Take-home per paycheck', style: context.ts(TickType.bodyS, color: c.textSecondary)),
        ])),
        const SizedBox(height: 8),
        NumberPad(onKey: (k) => _key(k, () => _amount, (v) => _amount = v)),
        const Spacer(),
        PillButton('Add', onTap: (parseCents(_amount) ?? 0) > 0 ? () => setState(() => _step = 2) : null),
        const SizedBox(height: 28),
      ]);
    } else {
      body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SizedBox(height: 16),
        Text('The big stuff.', style: context.ts(TickType.displayL)),
        const SizedBox(height: 8),
        Text('Rent and a goal is plenty. Add the rest any time.', style: context.ts(TickType.body, color: c.textSecondary)),
        const SizedBox(height: 16),
        TickCard(padding: const EdgeInsets.symmetric(horizontal: 16), child: Column(children: [
          _amountRow(context, 'Rent', 'Monthly · the 1st', _rent, _field == 0, () => setState(() => _field = 0), 'home'),
          const Hairline(),
          _amountRow(context, 'Savings', 'Each payday', _savings, _field == 1, () => setState(() => _field = 1), 'biz'),
        ])),
        const SizedBox(height: 8),
        NumberPad(onKey: (k) => _field == 0 ? _key(k, () => _rent, (v) => _rent = v) : _key(k, () => _savings, (v) => _savings = v)),
        const Spacer(),
        PillButton('Add', onTap: () => _finish()),
        const SizedBox(height: 8),
        PillButton('Start with demo data', style: PillStyle.ghost, height: 52, onTap: () => _finish(demo: true)),
        Center(child: Pressable(onTap: () => _finish(), child: Padding(padding: const EdgeInsets.all(12), child: Text('Skip for now', style: context.ts(TickType.body, color: c.textSecondary).copyWith(fontWeight: FontWeight.w700))))),
      ]);
    }
    return TickScreen(child: Column(children: [
      SizedBox(height: 52, child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Wordmark(size: 24), dots])),
      Expanded(child: body),
    ]));
  }

  Widget _amountRow(BuildContext context, String t, String sub, String v, bool on, VoidCallback tap, String colorKey) => Pressable(
        onTap: tap, scale: 1,
        child: Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Row(children: [
          Avatar(t, colorKey), const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(t, style: context.ts(TickType.title, size: 16)), Text(sub, style: context.ts(TickType.bodyS, color: context.c.textSecondary))])),
          Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), decoration: BoxDecoration(borderRadius: BorderRadius.circular(99), border: Border.all(color: on ? context.c.text : context.c.hairline, width: 1.5)), child: Text('\$${v.isEmpty ? '0' : v}', style: context.ts(TickType.mono))),
        ])),
      );
}
