import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/settings.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import 'auth.dart';

/// After [away] in the background, does Face ID need to be asked again? 0 seconds = every time the app was left.
bool shouldRelock(Duration away, int lockAfterSeconds) => away > Duration.zero && away.inSeconds >= lockAfterSeconds;

/// Face ID lock + privacy blur. Covers the app in the app switcher; asks for Face ID when returning if the lock is on.
class AppLock extends ConsumerStatefulWidget {
  const AppLock({super.key, required this.child});
  final Widget child;
  @override
  ConsumerState<AppLock> createState() => _AppLockState();
}

class _AppLockState extends ConsumerState<AppLock> with WidgetsBindingObserver {
  bool _covered = false;
  bool _locked = false;
  bool _authing = false;
  DateTime? _pausedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) { if (ref.read(settingsProvider).faceIdLock) { setState(() => _locked = true); _unlock(); } });
  }

  @override
  void dispose() { WidgetsBinding.instance.removeObserver(this); super.dispose(); }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final s = ref.read(settingsProvider);
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      if (_authing) return;
      if (state == AppLifecycleState.paused) _pausedAt ??= DateTime.now();
      // The app-switcher snapshot is taken now: cover everything (stronger than a blur).
      setState(() => _covered = s.privacyBlur || s.faceIdLock);
    } else if (state == AppLifecycleState.resumed) {
      final away = _pausedAt == null ? Duration.zero : DateTime.now().difference(_pausedAt!);
      _pausedAt = null;
      // Ask for Face ID again only after the chosen timeout (Settings > Lock after); 0 = every time.
      if (s.faceIdLock && (_locked || shouldRelock(away, s.lockAfterSeconds))) {
        setState(() => _locked = true);
        _unlock();
      } else {
        setState(() => _covered = false);
      }
    }
  }

  Future<void> _unlock() async {
    if (_authing) return;
    _authing = true;
    final ok = await ref.read(authServiceProvider).unlock();
    _authing = false;
    if (ok && mounted) setState(() { _locked = false; _covered = false; });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Stack(children: [
      widget.child,
      if (_covered || _locked)
        Positioned.fill(
          child: ColoredBox(
            color: c.bg,
            child: Center(child: _locked
                ? Column(mainAxisSize: MainAxisSize.min, children: [
                    Text('tick', style: context.ts(TickType.displayL)), const SizedBox(height: 24),
                    SizedBox(width: 220, child: PillButton('Unlock', icon: 'lock', onTap: _unlock)),
                  ])
                : Text('tick', style: context.ts(TickType.displayL))),
          ),
        ),
    ]);
  }
}
