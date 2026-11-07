import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../data/env.dart';
import '../data/ledger.dart';
import '../data/settings.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../design/widgets/more.dart';
import '../design/widgets/pickers.dart';
import '../design/widgets/scaffold.dart';
import '../domain/csv.dart';
import '../services/ai_status.dart';
import '../services/api.dart';
import '../services/auth.dart';
import '../services/session.dart';
import '../services/haptics.dart';
import 'tally_people.dart';

enum SettingsPage { root, appearance, data, labs, about }

/// Settings, sparse: a profile header and a handful of grouped rows on the root; everything else lives on four quiet subpages.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key, this.page = SettingsPage.root});
  final SettingsPage page;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    final l = ref.watch(ledgerProvider);
    final c = context.c;
    Widget chevron() => TickIcon('chevron-right', size: 20, color: c.textSecondary);
    Widget row(String icon, String title, Widget right, {VoidCallback? onTap, String? sub}) => Pressable(
          onTap: onTap, scale: 1, semanticLabel: title,
          child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 52), child: Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Row(children: [
            TickIcon(icon, size: 22, color: c.text), const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: context.ts(TickType.title, size: 16)),
              if (sub != null) Text(sub, style: context.ts(TickType.bodyS, size: 12.5, color: c.textSecondary)),
            ])),
            const SizedBox(width: 8), Flexible(flex: 0, child: Align(alignment: Alignment.centerRight, child: right)),
          ]))),
        );
    Widget val(String t) => Text(t, textAlign: TextAlign.right, style: context.ts(TickType.bodyS, color: c.textSecondary));
    Widget group(List<Widget> rows) => TickCard(padding: const EdgeInsets.symmetric(horizontal: 16), child: Column(children: [for (final (i, r) in rows.indexed) ...[if (i > 0) const Hairline(), r]]));
    final signedIn = ref.watch(userIdProvider) != null;
    switch (page) {
      case SettingsPage.root:
        return TickPage(title: 'Settings', onBack: () => context.pop(), children: [
          TickCard(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Avatar(s.name ?? 'P', 'biz', size: 48), const SizedBox(width: 16),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s.name ?? 'Prithvi', maxLines: 1, overflow: TextOverflow.ellipsis, style: context.ts(TickType.title, size: 18)),
                Text(signedIn ? 'Signed in with Google' : 'Not signed in', style: context.ts(TickType.bodyS, color: c.textSecondary)),
              ])),
            ]),
            if (Env.hasSupabase && !signedIn) ...[const SizedBox(height: 12), PillButton('Sign in with Google', height: 48, onTap: () => _signIn(context, ref))],
          ])),
          if (signedIn) ...[const SectionLabel('Finding you on Tick'), const HandleSettings()],
          const SectionLabel('Security'),
          group([
            row('lock', 'Face ID lock', TickToggle(label: 'Face ID lock', on: s.faceIdLock, onChanged: (v) async {
              // Only turn the lock on if Face ID actually works, so you can never lock yourself out.
              if (v && !await ref.read(authServiceProvider).unlock()) return;
              n.update((x) => x.copyWith(faceIdLock: v));
            }), sub: s.faceIdLock ? 'Asks again after ${_lockLabel(s.lockAfterSeconds)}' : null, onTap: null),
            row('eye-off', 'Privacy blur', TickToggle(label: 'Privacy blur', on: s.privacyBlur, onChanged: (v) => n.update((x) => x.copyWith(privacyBlur: v))), sub: 'Hides Tick in the app switcher'),
          ]),
          if (s.faceIdLock) Padding(padding: const EdgeInsets.only(top: 8), child: Segmented(options: const ['Always', '1 min', '5 min', '15 min'], index: const [0, 60, 300, 900].indexOf(s.lockAfterSeconds).clamp(0, 3),
              onChanged: (i) => n.update((x) => x.copyWith(lockAfterSeconds: const [0, 60, 300, 900][i])))),
          const SectionLabel('Banks and cards'),
          group([
            row('bank', 'Bank connections', val(l.connections.isEmpty ? 'None' : '${l.connections.length} linked'), onTap: () => context.push('/banks')),
            row('receipt', 'Capture token and Shortcuts', chevron(), onTap: () => _tokenSheet(context, ref)),
            row('import', 'Import statements', chevron(), onTap: () => context.push('/import')),
          ]),
          const SectionLabel('More'),
          group([
            row('ask', 'Ask Tick', chevron(), onTap: () => context.push('/settings/ask')),
            row('calendar', 'Payday', chevron(), onTap: () => context.push('/settings/payday')),
            row('sliders', 'Appearance and feel', val('${s.theme[0].toUpperCase()}${s.theme.substring(1)}'), onTap: () => context.push('/settings/appearance')),
            row('goal', 'Data', chevron(), onTap: () => context.push('/settings/data')),
            row('heart-check', 'Labs', val('${featureFlags.where((f) => s.flag(f.$1)).length} on'), onTap: () => context.push('/settings/labs')),
            row('info', 'About and safety', chevron(), onTap: () => context.push('/settings/about')),
          ]),
        ]);
      case SettingsPage.appearance:
        return TickPage(title: 'Appearance and feel', onBack: () => context.pop(), children: [
          TickCard(padding: const EdgeInsets.fromLTRB(16, 12, 16, 12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Theme', style: context.ts(TickType.bodyS, size: 13, color: c.textSecondary).copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Segmented(options: const ['System', 'Dark', 'Light'], index: ['system', 'dark', 'light'].indexOf(s.theme), onChanged: (i) { TickHaptics.instance.selection(); n.update((x) => x.copyWith(theme: ['system', 'dark', 'light'][i])); }),
            const SizedBox(height: 16),
            Text('Haptics', style: context.ts(TickType.bodyS, size: 13, color: c.textSecondary).copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Segmented(options: const ['Full', 'Subtle', 'Off'], index: s.haptics.index, onChanged: (i) { n.update((x) => x.copyWith(haptics: HapticMode.values[i])); TickHaptics.instance.pop(); }),
          ])),
          const SizedBox(height: 8),
          group([
            row('play', 'Sound', TickToggle(label: 'Sound', on: s.sound, onChanged: (v) { n.update((x) => x.copyWith(sound: v)); if (v) TickHaptics.instance.sound('capture_pop'); })),
            row('eye-off', 'Hide amounts', TickToggle(label: 'Hide amounts', on: s.hideAmounts, onChanged: (v) => n.update((x) => x.copyWith(hideAmounts: v))), sub: 'Shows \$•••• instead. Also while the screen is recorded.'),
          ]),
        ]);
      case SettingsPage.data:
        return TickPage(title: 'Data', onBack: () => context.pop(), children: [
          group([
            row('settings', 'Categories and rules', chevron(), onTap: () => context.push('/categories')),
            row('goal', 'Budgets and goals', chevron(), onTap: () => context.push('/budgets')),
            row('share', 'Export CSV', chevron(), onTap: () => _exportCsv(ref)),
          ]),
          const SizedBox(height: 8),
          Text('Export is the only place amounts are never hidden. Tick never moves money; nothing here can.', style: context.ts(TickType.bodyS, color: c.textSecondary)),
        ]);
      case SettingsPage.labs:
        return TickPage(title: 'Labs', onBack: () => context.pop(), subtitle: 'Small ideas, each on its own switch.', children: [
          TickCard(padding: const EdgeInsets.fromLTRB(16, 4, 16, 4), child: Column(children: [
            for (final (i, (id, title, desc)) in featureFlags.indexed) ...[
              if (i > 0) const Hairline(),
              Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Row(children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: context.ts(TickType.title, size: 16)),
                  Text(desc, style: context.ts(TickType.bodyS, color: c.textSecondary)),
                ])),
                const SizedBox(width: 12),
                TickToggle(label: title, on: s.flag(id), onChanged: (v) => n.update((x) => x.copyWith(flagsOff: v ? ({...x.flagsOff}..remove(id)) : {...x.flagsOff, id}))),
              ])),
            ],
          ])),
        ]);
      case SettingsPage.about:
        return TickPage(title: 'About and safety', onBack: () => context.pop(), children: [
          group([
            row('ask', 'AI', val(ref.watch(aiStatusProvider).maybeWhen(data: (a) => a.line, orElse: () => '…')), onTap: () => _aiSheet(context, ref)),
            if (Env.hasSupabase && signedIn)
              row('arrow-out', 'Sign out', const SizedBox(), onTap: () async {
                await ref.read(authServiceProvider).signOut();
                await ref.read(ledgerProvider.notifier).wipeLocal();           // nothing of a signed-out account stays on the phone
                ref.read(settingsProvider.notifier).update((x) => x.copyWith(onboardingDone: false));
                if (context.mounted) context.go('/onboarding');
              }),
          ]),
          const SectionLabel('If your phone or a token leaks'),
          HoldToConfirm(label: 'Panic: lock everything', danger: true, onConfirmed: () => _panic(context, ref)),
          Padding(padding: const EdgeInsets.only(top: 8), child: Text('Turns off every capture token and signs out every device. Your data and bank links stay.', textAlign: TextAlign.center, style: context.ts(TickType.bodyS, color: c.textSecondary))),
          const SizedBox(height: 16),
          HoldToConfirm(label: 'Delete all data', danger: true, onConfirmed: () => _deleteAll(context, ref)),
          Padding(padding: const EdgeInsets.only(top: 8), child: Text('Deletes everything in Tick and removes every bank link at Plaid. Removing a link never gives the slot back. This can\'t be undone.', textAlign: TextAlign.center, style: context.ts(TickType.bodyS, color: c.textSecondary))),
          const SizedBox(height: 24),
          Text('Tick 1.0.0 · Tick never moves money.', textAlign: TextAlign.center, style: context.ts(TickType.bodyS, color: c.textSecondary)),
        ]);
    }
  }

  static String _lockLabel(int s) => s == 0 ? 'every time' : s < 120 ? '${s ~/ 60} min' : '${s ~/ 60} min';

  Future<void> _signIn(BuildContext context, WidgetRef ref) async {
    String? message;
    try {
      await ref.read(authServiceProvider).signInWithGoogle();
      final name = ref.read(authServiceProvider).displayName;
      ref.read(settingsProvider.notifier).update((s) => s.copyWith(name: name));
    } on AuthFailure catch (f) {
      message = f.message;
    } catch (_) {
      message = const AuthFailure(AuthFailureKind.failed).message;
    }
    if (message != null && context.mounted) {
      await showTickSheet<void>(context, builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Sign-in', style: ctx.ts(TickType.displayM)), const SizedBox(height: 8),
        Text(message!, style: ctx.ts(TickType.body, color: ctx.c.textSecondary)), const SizedBox(height: 16),
        ActionButton('Try again', onPressed: () async { Navigator.of(ctx).pop(); await _signIn(context, ref); }),
      ]));
    }
  }

  Future<void> _aiSheet(BuildContext context, WidgetRef ref) {
    final a = ref.read(aiStatusProvider).asData?.value ?? AiStatus.off();
    return showTickSheet<void>(context, builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(a.line, style: ctx.ts(TickType.displayM)),
      const SizedBox(height: 8),
      Text('Tick only uses free models, and only when rules can\'t answer. Alert parsing, merchant cleanup and Ask Tick use up to ${a.limit} calls a day.', style: ctx.ts(TickType.body, color: ctx.c.textSecondary)),
      const SizedBox(height: 16),
      if (a.models.isEmpty) Text(a.note ?? 'No free model is available right now. Everything still works without AI.', style: ctx.ts(TickType.body))
      else ...[Text('Free models in use', style: ctx.ts(TickType.bodyS, color: ctx.c.textSecondary).copyWith(fontWeight: FontWeight.w700)), const SizedBox(height: 8), for (final m in a.models) Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(m, style: ctx.ts(TickType.mono)))],
    ]));
  }

  Future<void> _exportCsv(WidgetRef ref) async {
    final l = ref.read(ledgerProvider);
    final csv = buildCsv(l);
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/tick-export.csv')..writeAsStringSync(csv);
    await SharePlus.instance.share(ShareParams(files: [XFile(f.path)]));
  }

  /// Panic button: the server revokes every capture token (and audits it), then this device signs out EVERY session.
  Future<void> _panic(BuildContext context, WidgetRef ref) async {
    String? plaid;
    var ok = true;
    if (ref.read(userIdProvider) != null) {
      try {
        final j = await ref.read(apiProvider).post('/security/panic');
        plaid = j['plaid'] as String?;
      } catch (_) {
        ok = false;
      }
      try {
        await Supabase.instance.client.auth.signOut(scope: SignOutScope.global);
      } catch (_) {
        ok = false;
      }
    }
    await ref.read(ledgerProvider.notifier).wipeLocal();
    ref.read(settingsProvider.notifier).update((x) => x.copyWith(onboardingDone: false));
    if (!context.mounted) return;
    await showTickSheet<void>(context, builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(ok ? 'Everything is locked' : 'Partly locked', style: ctx.ts(TickType.displayM)),
          const SizedBox(height: 8),
          Text(ok ? 'Capture tokens are off and every device is signed out.' : 'This phone is signed out. Try again when you are online to turn off tokens and other devices.',
              style: ctx.ts(TickType.body)),
          const SizedBox(height: 8),
          Text(plaid ?? 'To cut Plaid\'s access too, open my.plaid.com, sign in with your phone number and remove Tick.', style: ctx.ts(TickType.bodyS, color: ctx.c.textSecondary)),
          const SizedBox(height: 16),
          PillButton('Done', onTap: () => Navigator.of(ctx).pop()),
        ]));
    if (context.mounted) context.go('/onboarding');
  }

  /// Delete all my data, on the server: Plaid /item/remove for every bank, Vault tokens, every row and receipt photo.
  Future<void> _deleteAll(BuildContext context, WidgetRef ref) async {
    String? error;
    if (ref.read(userIdProvider) != null && !ref.read(settingsProvider).demoMode) {
      try {
        await ref.read(apiProvider).post('/me/delete', {'confirm': 'DELETE'}, const Duration(seconds: 60));
      } catch (e) {
        error = '${describeError(e, action: 'delete')} Nothing was deleted on the server.';
      }
    }
    if (error != null) {
      if (context.mounted) {
        await showTickSheet<void>(context, builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Not deleted yet', style: ctx.ts(TickType.displayM)), const SizedBox(height: 8),
              Text(error!, style: ctx.ts(TickType.body, color: ctx.c.textSecondary)),
            ]));
      }
      return;
    }
    ref.read(settingsProvider.notifier).update((x) => const AppSettings());
    await ref.read(ledgerProvider.notifier).wipeLocal();
    await ref.read(ledgerProvider.notifier).refresh();
    if (context.mounted) context.go('/onboarding');
  }

  Future<void> _tokenSheet(BuildContext context, WidgetRef ref) {
    return showTickSheet<void>(context, builder: (ctx) => _TokenSheet(ref: ref));
  }
}

class _TokenSheet extends StatefulWidget {
  const _TokenSheet({required this.ref});
  final WidgetRef ref;
  @override
  State<_TokenSheet> createState() => _TokenSheetState();
}

class _TokenSheetState extends State<_TokenSheet> {
  String? _token;
  String? _err;
  Future<void> _make() async {
    try {
      // The server makes the token (32 random bytes), keeps only its hash, turns older tokens off and records it in the audit log.
      final j = await widget.ref.read(apiProvider).post('/tokens', {'label': 'Shortcuts', 'replace': true});
      setState(() => _token = j['token'] as String?);
    } catch (e) {
      setState(() => _err = describeError(e, action: 'make a token'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Capture token', style: context.ts(TickType.displayM)),
      const SizedBox(height: 8),
      Text('Paste this into your Shortcuts automations. Making a new one turns the old one off.', style: context.ts(TickType.body, color: c.textSecondary)),
      const SizedBox(height: 16),
      if (_token != null) ...[
        TickCard(raised: true, child: Text(_token!, style: context.ts(TickType.mono))),
        const SizedBox(height: 8),
        PillButton('Copy token', style: PillStyle.quiet, onTap: () => Clipboard.setData(ClipboardData(text: _token!))),
        const SizedBox(height: 8),
        Text('Shown once: Tick keeps only a fingerprint of it. Ingest URL: ${Env.apiBaseUrl}/ingest', style: context.ts(TickType.bodyS, color: c.textSecondary)),
      ] else ...[
        ActionButton('Make new token', onPressed: _make),
        if (_err != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_err!, style: context.ts(TickType.body, color: c.alert))),
      ],
    ]);
  }
}

/// Settings > Categories and rules: add and rename categories, review and remove learned rules.
class CategoriesScreen extends ConsumerWidget {
  const CategoriesScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = ref.watch(ledgerProvider);
    final c = context.c;
    return TickPage(
      title: 'Categories', onBack: () => context.pop(),
      children: [
        SectionLabel('Categories', trailing: TickChip('Add', icon: 'plus', onTap: () => _add(context, ref))),
        TickCard(padding: const EdgeInsets.symmetric(horizontal: 16), child: Column(children: [
          for (var i = 0; i < l.categories.length; i++) ...[
            if (i > 0) const Hairline(),
            Pressable(
              onTap: () async {
                final n = await showTextSheet(context, title: 'Rename category', initial: l.categories[i].name, confirm: 'Tick');
                if (n != null) ref.read(ledgerProvider.notifier).renameCategory(l.categories[i].id, n);
              },
              scale: 1,
              child: SizedBox(height: 52, child: Row(children: [Avatar(l.categories[i].name, l.categories[i].colorKey, size: 32), const SizedBox(width: 12), Expanded(child: Text(l.categories[i].name, style: context.ts(TickType.title, size: 16))), Text('${l.txns.where((t) => t.categoryId == l.categories[i].id).length}', style: context.ts(TickType.monoS, color: c.textSecondary))])),
            ),
          ],
        ])),
        SectionLabel('Learned rules'),
        if (l.rules.isEmpty)
          Text('Fix a category on any purchase and Tick remembers it for that merchant.', style: context.ts(TickType.body, color: c.textSecondary))
        else
          TickCard(padding: const EdgeInsets.symmetric(horizontal: 16), child: Column(children: [
            for (var i = 0; i < l.rules.length; i++) ...[
              if (i > 0) const Hairline(),
              SizedBox(height: 52, child: Row(children: [
                Expanded(child: Text('${l.rules[i].pattern} → ${l.category(l.rules[i].categoryId)?.name ?? 'Other'}', maxLines: 1, overflow: TextOverflow.ellipsis, style: context.ts(TickType.body))),
                Pressable(onTap: () => ref.read(ledgerProvider.notifier).deleteRule(l.rules[i].id), semanticLabel: 'Remove rule', child: SizedBox(width: 44, height: 44, child: Center(child: TickIcon('trash', size: 20, color: c.textSecondary)))),
              ])),
            ],
          ])),
      ],
    );
  }

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final name = await showTextSheet(context, title: 'New category', hint: 'Pets, Gifts, Gym');
    if (name == null || !context.mounted) return;
    final color = await showTickSheet<String>(context, builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Pick a color', style: ctx.ts(TickType.displayM)), const SizedBox(height: 16),
      Wrap(spacing: 12, runSpacing: 12, children: [for (final k in const ['food', 'ride', 'sub', 'home', 'biz', 'shop']) Pressable(onTap: () => Navigator.of(ctx).pop(k), semanticLabel: k, child: Avatar(name, k, size: 52))]),
    ]));
    if (color != null) ref.read(ledgerProvider.notifier).addCategory(name, color);
  }
}
