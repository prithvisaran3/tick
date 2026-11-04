import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../data/env.dart';
import '../data/ledger.dart';
import '../data/remote.dart';
import '../data/settings.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../design/widgets/more.dart';
import '../design/widgets/pickers.dart';
import '../services/ai_status.dart';
import '../services/auth.dart';
import '../services/session.dart';
import '../services/haptics.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    final l = ref.watch(ledgerProvider);
    final c = context.c;
    Widget row(String icon, String title, Widget right, {VoidCallback? onTap}) => Pressable(
          onTap: onTap, scale: 1, semanticLabel: title,
          child: SizedBox(height: 52, child: Row(children: [TickIcon(icon, size: 22, color: c.text), const SizedBox(width: 12), Expanded(child: Text(title, style: context.ts(TickType.title, size: 16))), right])),
        );
    Widget val(String t) => Text(t, style: context.ts(TickType.bodyS, color: c.textSecondary));
    return TickScreen(
      child: ListView(padding: const EdgeInsets.only(bottom: 48), children: [
        ScreenTitle('Settings', onBack: () => context.pop()),
        TickCard(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), child: Row(children: [
          Avatar(s.name ?? 'P', 'biz', size: 48), const SizedBox(width: 16),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.name ?? 'Prithvi', style: context.ts(TickType.title, size: 18)),
            Text(ref.watch(userIdProvider) != null ? 'Signed in with Google' : 'Not signed in', style: context.ts(TickType.bodyS, color: c.textSecondary)),
          ])),
        ])),
        const SizedBox(height: 8),
        TickCard(padding: const EdgeInsets.symmetric(horizontal: 16), child: Column(children: [
          row('lock', 'Face ID lock', TickToggle(label: 'Face ID lock', on: s.faceIdLock, onChanged: (v) async {
            // Only turn the lock on if Face ID actually works, so you can never lock yourself out.
            if (v && !await ref.read(authServiceProvider).unlock()) return;
            n.update((x) => x.copyWith(faceIdLock: v));
          })),
          const Hairline(),
          row('eye-off', 'Privacy blur', TickToggle(label: 'Privacy blur', on: s.privacyBlur, onChanged: (v) => n.update((x) => x.copyWith(privacyBlur: v)))),
        ])),
        const SizedBox(height: 8),
        TickCard(padding: const EdgeInsets.fromLTRB(16, 12, 16, 12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Haptics', style: context.ts(TickType.bodyS, size: 13, color: c.textSecondary).copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Segmented(options: const ['Full', 'Subtle', 'Off'], index: s.haptics.index, onChanged: (i) { n.update((x) => x.copyWith(haptics: HapticMode.values[i])); TickHaptics.instance.pop(); }),
          const SizedBox(height: 8),
          SizedBox(height: 44, child: Row(children: [Expanded(child: Text('Sound', style: context.ts(TickType.title, size: 16))), TickToggle(label: 'Sound', on: s.sound, onChanged: (v) { n.update((x) => x.copyWith(sound: v)); if (v) TickHaptics.instance.sound('capture_pop'); })])),
          const SizedBox(height: 4),
          Text('Theme', style: context.ts(TickType.bodyS, size: 13, color: c.textSecondary).copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Segmented(options: const ['System', 'Dark', 'Light'], index: ['system', 'dark', 'light'].indexOf(s.theme), onChanged: (i) => n.update((x) => x.copyWith(theme: ['system', 'dark', 'light'][i]))),
        ])),
        const SizedBox(height: 8),
        TickCard(padding: const EdgeInsets.symmetric(horizontal: 16), child: Column(children: [
          row('bank', 'Bank connections', val('${l.linksUsed} of 10 used'), onTap: () => context.push('/banks')),
          const Hairline(),
          row('receipt', 'Capture token', val('Shortcuts'), onTap: () => _tokenSheet(context, ref)),
          const Hairline(),
          row('goal', 'Budgets and goals', TickIcon('chevron-right', size: 20, color: c.textSecondary), onTap: () => context.push('/budgets')),
          const Hairline(),
          row('ask', 'AI', val(ref.watch(aiStatusProvider).maybeWhen(data: (a) => a.line, orElse: () => '…')), onTap: () => _aiSheet(context, ref)),
          const Hairline(),
          row('settings', 'Categories and rules', TickIcon('chevron-right', size: 20, color: c.textSecondary), onTap: () => context.push('/categories')),
        ])),
        const SizedBox(height: 8),
        TickCard(padding: const EdgeInsets.symmetric(horizontal: 16), child: Column(children: [
          row('share', 'Export CSV', TickIcon('chevron-right', size: 20, color: c.textSecondary), onTap: () => _exportCsv(ref)),
          const Hairline(),
          row('play', 'Demo mode', TickToggle(label: 'Demo mode', on: s.demoMode, onChanged: (v) => n.update((x) => x.copyWith(demoMode: v)))),
          if (Env.hasSupabase && ref.watch(userIdProvider) == null) ...[
            const Hairline(),
            row('check', 'Sign in with Google', TickIcon('chevron-right', size: 20, color: c.textSecondary), onTap: () => _signIn(context, ref)),
          ],
          if (Env.hasSupabase && ref.watch(userIdProvider) != null) ...[
            const Hairline(),
            row('arrow-out', 'Sign out', const SizedBox(), onTap: () async {
              await ref.read(authServiceProvider).signOut();
              await ref.read(ledgerProvider.notifier).wipeLocal();           // nothing of a signed-out account stays on the phone
              ref.read(settingsProvider.notifier).update((x) => x.copyWith(onboardingDone: false));
              if (context.mounted) context.go('/onboarding');
            }),
          ],
        ])),
        const SizedBox(height: 16),
        HoldToConfirm(label: 'Delete all data', danger: true, onConfirmed: () => _deleteAll(context, ref)),
        Padding(padding: const EdgeInsets.only(top: 8), child: Text('Deletes everything in Tick, including bank links. This can\'t be undone.', textAlign: TextAlign.center, style: context.ts(TickType.bodyS, color: c.textSecondary))),
      ]),
    );
  }

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
    String q(String s) => '"${s.replaceAll('"', '""')}"';
    final b = StringBuffer('date,merchant,amount,category,account,business,note\n');
    for (final t in l.txns) {
      b.writeln([t.occurredAt.toIso8601String(), q(t.merchant), (t.amountCents / 100).toStringAsFixed(2), q(l.category(t.categoryId)?.name ?? ''), q(l.account(t.accountId)?.label ?? ''), t.isBusiness, q(t.note ?? '')].join(','));
    }
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/tick-export.csv')..writeAsStringSync(b.toString());
    await SharePlus.instance.share(ShareParams(files: [XFile(f.path)]));
  }

  Future<void> _deleteAll(BuildContext context, WidgetRef ref) async {
    final remote = ref.read(remoteProvider);
    if (remote != null) {
      for (final t in ['transactions', 'recurring', 'expected', 'goals', 'budgets', 'rules', 'insights', 'chats', 'snapshots']) {
        try { await Supabase.instance.client.from(t).delete().neq('user_id', '00000000-0000-0000-0000-000000000000'); } catch (_) {}
      }
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
      final rnd = Random.secure();
      final raw = List.generate(32, (_) => rnd.nextInt(256));
      final token = 'tk_${base64Url.encode(raw).replaceAll('=', '')}';
      final hash = sha256.convert(utf8.encode(token)).toString();
      final db = Supabase.instance.client;
      await db.from('ingest_tokens').update({'revoked_at': DateTime.now().toUtc().toIso8601String()}).isFilter('revoked_at', null);
      await db.from('ingest_tokens').insert({'token_hash': hash, 'last4': token.substring(token.length - 4)});
      setState(() => _token = token);
    } catch (_) {
      setState(() => _err = 'That didn\'t go through. Try again, nothing was lost.');
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
        Text('Shown once. Ingest URL: ${Env.apiBaseUrl}/ingest', style: context.ts(TickType.bodyS, color: c.textSecondary)),
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
    return TickScreen(
      child: ListView(padding: const EdgeInsets.only(bottom: 40), children: [
        ScreenTitle('Categories', onBack: () => context.pop()),
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
      ]),
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
