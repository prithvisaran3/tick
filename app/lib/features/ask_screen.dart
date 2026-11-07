import '../services/api.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../data/env.dart';
import '../data/activity.dart';
import '../data/ledger.dart';
import '../data/nav.dart';
import '../data/remote.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/avatar.dart';
import '../design/widgets/core.dart';
import '../design/widgets/more.dart';
import '../design/widgets/scaffold.dart';
import '../domain/flows.dart';
import '../services/haptics.dart';
import 'common.dart';

class AskMessage {
  AskMessage(this.fromUser, this.text, {List<Map<String, dynamic>>? blocks, this.failed = false}) : blocks = blocks ?? [];
  String? logId;     // this answer's row in ask_log: what 👍 and 👎 attach to
  String? range;     // the dates it used
  int rating = 0;
  final bool fromUser;
  String text;
  final List<Map<String, dynamic>> blocks;
  bool failed; // the stream broke: partial text stays, with a retry
}

class AskNotifier extends Notifier<List<AskMessage>> {
  bool busy = false;
  http.Client? _client;
  String? _lastQuestion;
  bool _cancelled = false;
  Map<String, dynamic>? _context;   // what the last answer was about, for "and last month?"

  @override
  List<AskMessage> build() {
    ref.onDispose(cancel);
    return [];
  }

  /// Stop the current answer (leaving the screen, tapping stop). Partial text stays.
  void cancel() {
    _cancelled = true;
    _client?.close();
    _client = null;
  }

  Future<void> retry() async {
    final q = _lastQuestion;
    if (q == null || busy) return;
    if (state.isNotEmpty && !state.last.fromUser && state.last.failed) state = state.sublist(0, state.length - 2);   // drop the failed pair and ask again
    await ask(q);
  }

  /// Streams an answer from POST /ask (SSE). Events: {type:token,text}, {type:block,block}, {type:error}, {type:done}; `: ping` keepalives are ignored.
  /// Before the first token arrives, one automatic retry. After that a broken stream keeps the partial text and offers a retry.
  Future<void> ask(String q) async {
    final question = q.trim();
    if (busy || question.isEmpty) return;
    busy = true;
    _cancelled = false;
    _lastQuestion = question;
    final history = [for (final m in state.reversed.take(6).toList().reversed) {'role': m.fromUser ? 'user' : 'assistant', 'text': m.text}];
    final reply = AskMessage(false, '');
    state = [...state, AskMessage(true, question), reply];
    var attempt = 0;
    while (true) {
      try {
        final device = await AskDeviceModel.available();
        final again = await _stream(question, history, reply, deviceReady: device);
        if (again) await _stream(question, history, reply, deviceCall: await AskDeviceModel.route(question));
        reply.failed = false;
        if (reply.text.isEmpty) reply.text = 'I couldn\'t find an answer for that. Try asking it another way.';
        break;
      } catch (e) {
        if (_cancelled) break;
        final gotSomething = reply.text.isNotEmpty || reply.blocks.isNotEmpty;
        final refused = e is ApiException && e.status >= 400 && e.status < 500;        // 401/403/429: retrying can't help; say why
        if (refused && !gotSomething) { reply.failed = true; reply.text = e.message; break; }
        if (!gotSomething && attempt == 0) { attempt++; await Future<void>.delayed(const Duration(milliseconds: 700)); continue; }
        reply.failed = true;
        if (!gotSomething) reply.text = e is ApiException && e.status >= 500 ? '${e.message} Your numbers on Today and Flows are still here.' : 'Can\'t reach Tick right now. Your numbers on Today and Flows are still here.';
        break;
      }
    }
    busy = false;
    state = [...state];
  }

  /// True when the server asked this phone's model to pick the tool.
  Future<bool> _stream(String q, List<Map<String, String>> history, AskMessage reply, {bool deviceReady = false, Map<String, dynamic>? deviceCall}) async {
    final token = Env.hasSupabase ? Supabase.instance.client.auth.currentSession?.accessToken : null;
    if (token == null) throw ApiException(401, messageForStatus(401, null));
    final client = http.Client();
    _client = client;
    try {
      final req = http.Request('POST', Uri.parse('${Env.apiBaseUrl}/ask'))
        ..headers.addAll({'Authorization': 'Bearer $token', 'Content-Type': 'application/json', 'Accept': 'text/event-stream'})
        ..body = jsonEncode({'question': q, 'history': history, 'context': _context, 'device_ready': deviceReady, 'device_call': ?deviceCall});
      final res = await client.send(req).timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) throw ApiException(res.statusCode, messageForStatus(res.statusCode, null));
      var finished = false;
      final lines = res.stream.transform(utf8.decoder).transform(const LineSplitter()).timeout(const Duration(seconds: 30));   // idle timeout between chunks
      await for (final line in lines) {
        if (!line.startsWith('data:')) continue;                                  // comments (": ping") and blanks
        Map<String, dynamic> ev;
        try { ev = jsonDecode(line.substring(5).trim()) as Map<String, dynamic>; } catch (_) { continue; }
        switch (ev['type']) {
          case 'token': reply.text += (ev['text'] as String? ?? '');
          case 'block': if (ev['block'] is Map<String, dynamic>) reply.blocks.add(ev['block'] as Map<String, dynamic>);
          case 'error': throw StateError('server error');
          case 'need_device': return true;
          case 'meta':
            reply.logId = ev['log_id'] as String?;
            reply.range = ev['range'] as String?;
            _context = (ev['context'] as Map?)?.cast<String, dynamic>();
          case 'done': finished = true;
        }
        state = [...state];
        if (finished) break;
      }
      if (!finished && reply.text.isEmpty) throw StateError('empty stream');
      return false;
    } finally {
      client.close();
      if (identical(_client, client)) _client = null;
    }
  }
}

/// This phone's own model (ios/Runner/TickAskModel.swift). Soft-fails: no channel or no Apple Intelligence just means the server carries on without it.
class AskDeviceModel {
  static const _ch = MethodChannel('tick/ask_model');
  static Future<bool> available() async {
    try { return await _ch.invokeMethod<bool>('available') ?? false; } catch (_) { return false; }
  }
  /// {tool, params}, or {} when the model couldn't help.
  static Future<Map<String, dynamic>> route(String q) async {
    try { return (await _ch.invokeMapMethod<String, dynamic>('route', {'question': q})) ?? const {}; } catch (_) { return const {}; }
  }
}

class AskStats {
  const AskStats(this.count, this.noModelPct, this.thumbsUpPct, this.cloud);
  final int count;
  final int? noModelPct;
  final int? thumbsUpPct;
  final bool cloud;
}

final askStatsProvider = FutureProvider<AskStats>((ref) async {
  final j = await ref.read(apiProvider).get('/ask/stats');
  return AskStats((j['count'] as num?)?.toInt() ?? 0, (j['no_model_pct'] as num?)?.toInt(), (j['thumbs_up_pct'] as num?)?.toInt(), j['cloud'] != false);
});

/// Questions from this person's own data, with sensible ones until the server answers.
final askSuggestionsProvider = FutureProvider<List<String>>((ref) async {
  if (ref.watch(remoteProvider) == null) return suggestedQuestions;
  try {
    final j = await ref.read(apiProvider).get('/ask/suggested');
    final q = [for (final x in (j['questions'] as List? ?? const [])) '$x'];
    return q.isEmpty ? suggestedQuestions : q;
  } catch (_) {
    return suggestedQuestions;
  }
});

final askProvider = NotifierProvider<AskNotifier, List<AskMessage>>(AskNotifier.new);

const suggestedQuestions = ['How much did I spend on food this month?', "What's due this week?", 'Business total this month', 'Which subscriptions am I paying for?', 'Can I afford \$200 today?'];

class AskScreen extends ConsumerStatefulWidget {
  const AskScreen({super.key, this.inSheet = false});
  final bool inSheet;
  @override
  ConsumerState<AskScreen> createState() => _AskScreenState();
}

class _AskScreenState extends ConsumerState<AskScreen> {
  final _ctl = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  @override
  void dispose() { _ctl.dispose(); _focus.dispose(); _scroll.dispose(); super.dispose(); }

  void _send([String? q]) {
    if (ref.read(askProvider.notifier).busy) return;                    // one question at a time
    final text = q ?? _ctl.text;
    if (text.trim().isEmpty) return;
    _ctl.clear();
    TickHaptics.instance.selection();
    ref.read(askProvider.notifier).ask(text).whenComplete(TickHaptics.instance.success);
    setState(() {});
    Future.delayed(const Duration(milliseconds: 100), () { if (mounted && _scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 250), curve: Curves.easeOut); });
  }

  @override
  Widget build(BuildContext context) {
    final msgs = ref.watch(askProvider);
    final busy = ref.read(askProvider.notifier).busy;
    final suggested = ref.watch(askSuggestionsProvider).value ?? suggestedQuestions;
    final l = ref.watch(ledgerProvider);
    final c = context.c;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (!widget.inSheet) const ScreenTitle('Ask Tick'),
      Expanded(
        child: msgs.isEmpty
            ? ListView(children: [
                const Padding(padding: EdgeInsets.only(top: 24), child: Center(child: AskMascot())),
                Padding(padding: const EdgeInsets.fromLTRB(24, 12, 24, 16), child: Column(children: [
                  Text('Ask me anything about your money.', textAlign: TextAlign.center, style: context.ts(TickType.title)),
                  const SizedBox(height: 4),
                  Text('Answers lead with the number.', textAlign: TextAlign.center, style: context.ts(TickType.body, color: c.textSecondary)),
                ])),
                Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [for (final q in suggested.take(4)) TickChip(q, onTap: () => _send(q))]),
              ])
            : ListView(controller: _scroll, padding: const EdgeInsets.only(bottom: 16), children: [
                for (final m in msgs) m.fromUser ? _UserBubble(m.text) : _Answer(m: m, ledger: l, onRetry: () => ref.read(askProvider.notifier).retry()),
              ]),
      ),
      ChipRow(children: [for (final q in suggested) TickChip(q, onTap: () => _send(q))]),
      const SizedBox(height: 8),
      Padding(
        padding: EdgeInsets.only(bottom: widget.inSheet ? 8 : 112),
        child: Container(
          height: 52, padding: const EdgeInsets.only(left: 16, right: 6), decoration: BoxDecoration(color: c.surface2, borderRadius: BorderRadius.circular(999)),
          child: Row(children: [
            Expanded(child: Stack(alignment: Alignment.centerLeft, children: [
              if (_ctl.text.isEmpty) IgnorePointer(child: Text('Ask anything about your money', style: context.ts(TickType.body, color: c.textSecondary))),
              EditableText(controller: _ctl, focusNode: _focus, style: context.ts(TickType.body), cursorColor: c.text, backgroundCursorColor: c.surface2, selectionColor: c.hairline, onChanged: (_) => setState(() {}), onSubmitted: (v) => _send()),
            ])),
            Pressable(
              onTap: busy ? () => ref.read(askProvider.notifier).cancel() : _send, semanticLabel: busy ? 'Stop' : 'Send', minSize: 44,
              child: Container(width: 40, height: 40, decoration: BoxDecoration(color: _ctl.text.isEmpty && !busy ? c.surface1 : c.accent, shape: BoxShape.circle), alignment: Alignment.center, child: busy ? TickLoader(color: c.onAccent, size: 5) : TickIcon('arrow-up', size: 20, color: _ctl.text.isEmpty ? c.textSecondary : c.onAccent)),
            ),
          ]),
        ),
      ),
    ]);
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerRight,
        child: Container(margin: const EdgeInsets.only(top: 8, left: 56), padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), decoration: BoxDecoration(color: context.c.surface2, borderRadius: const BorderRadius.only(topLeft: Radius.circular(22), topRight: Radius.circular(22), bottomLeft: Radius.circular(22), bottomRight: Radius.circular(8))), child: Text(text, style: context.ts(TickType.body))),
      );
}

class _Answer extends StatelessWidget {
  const _Answer({required this.m, required this.ledger, required this.onRetry});
  final VoidCallback onRetry;
  final AskMessage m;
  final LedgerState ledger;
  @override
  Widget build(BuildContext context) {
    // Lead with the number: pull a leading $ amount out as a display figure.
    final match = RegExp(r'^(−?\$[\d,]+(?:\.\d{2})?)\s*(.*)$', dotAll: true).firstMatch(m.text);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (m.text.isEmpty) const Skeleton(width: 160, height: 28, radius: 10)
        else if (match != null) ...[Text(match.group(1)!, style: context.ts(TickType.hero, size: 52)), const SizedBox(height: 2), Text(match.group(2)!, style: context.ts(TickType.bodyL))]
        else Text(m.text, style: context.ts(TickType.bodyL)),
        for (final b in m.blocks) Padding(padding: const EdgeInsets.only(top: 12), child: _Block(block: b, ledger: ledger)),
        if (m.range != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(m.range!, style: context.ts(TickType.bodyS, size: 12.5, color: context.c.textSecondary))),
        if (m.failed) Padding(padding: const EdgeInsets.only(top: 12), child: Row(children: [TickChip('Try again', icon: 'repeat', onTap: onRetry)])),
        if (m.logId != null) _Rate(m: m),
      ]),
    );
  }
}

/// 👍 teaches the matcher. 👎 asks what was wrong, and a correction is preferred next time.
class _Rate extends ConsumerStatefulWidget {
  const _Rate({required this.m});
  final AskMessage m;
  @override
  ConsumerState<_Rate> createState() => _RateState();
}

class _RateState extends ConsumerState<_Rate> {
  Future<void> _send(int rating, {Map<String, dynamic> extra = const {}}) async {
    TickHaptics.instance.selection();
    setState(() => widget.m.rating = rating);
    try { await ref.read(apiProvider).post('/ask/feedback', {'log_id': widget.m.logId, 'rating': rating, ...extra}); } catch (_) {/* the answer still stands */}
  }

  Future<void> _wrong() async {
    final extra = await showTickSheet<Map<String, dynamic>>(context, builder: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Text('What was wrong?', style: ctx.ts(TickType.title)),
      const SizedBox(height: 12),
      Text('The period', style: ctx.ts(TickType.bodyS, color: ctx.c.textSecondary)),
      const SizedBox(height: 4),
      Wrap(spacing: 8, runSpacing: 4, children: [for (final r in const ['this month', 'last month', 'this year', 'since payday']) TickChip(r, onTap: () => Navigator.of(ctx).pop({'reason': 'period', 'range': r}))]),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 4, children: [
        TickChip('The category', onTap: () => Navigator.of(ctx).pop({'reason': 'category'})),
        TickChip('The person', onTap: () => Navigator.of(ctx).pop({'reason': 'person'})),
        TickChip('Something else', onTap: () => Navigator.of(ctx).pop({'reason': 'other'})),
      ]),
    ]));
    await _send(-1, extra: extra ?? const {});
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final r = widget.m.rating;
    return Padding(padding: const EdgeInsets.only(top: 8), child: Row(mainAxisSize: MainAxisSize.min, children: [
      Pressable(onTap: () => _send(1), semanticLabel: 'Good answer', minSize: 44, child: Opacity(opacity: r < 0 ? 0.4 : 1, child: Text('👍', style: context.ts(TickType.bodyL, color: c.text)))),
      const SizedBox(width: 12),
      Pressable(onTap: _wrong, semanticLabel: 'Wrong answer', minSize: 44, child: Opacity(opacity: r > 0 ? 0.4 : 1, child: Text('👎', style: context.ts(TickType.bodyL, color: c.text)))),
    ]));
  }
}

/// Settings > Ask Tick.
class AskSettingsScreen extends ConsumerStatefulWidget {
  const AskSettingsScreen({super.key});
  @override
  ConsumerState<AskSettingsScreen> createState() => _AskSettingsState();
}

class _AskSettingsState extends ConsumerState<AskSettingsScreen> {
  String? _note;
  Future<void> _run(Future<void> Function() f, String done) async {
    try {
      await f();
      ref.invalidate(askStatsProvider);
      if (mounted) setState(() => _note = done);
    } catch (e) {
      if (mounted) setState(() => _note = describeError(e, action: 'save that'));
    }
  }
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final s = ref.watch(askStatsProvider);
    final api = ref.read(apiProvider);
    return TickPage(title: 'Ask Tick', onBack: () => context.pop(), children: [
      switch (s) {
        AsyncData(:final value) => TickCard(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(value.noModelPct == null ? 'No questions yet' : '${value.noModelPct}% answered without a model', style: context.ts(TickType.title, size: 16)),
            Text('Last 30 days, ${value.count} ${value.count == 1 ? 'question' : 'questions'}.${value.thumbsUpPct == null ? '' : ' ${value.thumbsUpPct}% 👍.'}', style: context.ts(TickType.bodyS, color: c.textSecondary)),
            const SizedBox(height: 6),
            const Hairline(),
            Row(children: [
              Expanded(child: Text('Use cloud model', style: context.ts(TickType.body))),
              TickToggle(on: value.cloud, label: 'Use cloud model', onChanged: (v) => _run(() => api.post('/ask/settings', {'cloud': v}), v ? 'Cloud model on.' : 'Cloud model off.')),
            ]),
            Text('Off means rules, what Tick learned and this phone only. Questions those can\'t answer say so.', style: context.ts(TickType.bodyS, size: 12.5, color: c.textSecondary)),
          ])),
        AsyncError(:final error) => ErrorState(title: 'That didn\'t load', body: describeError(error, action: 'load this'), onRetry: () async => ref.invalidate(askStatsProvider)),
        _ => const Skeleton(height: 140, radius: 24),
      },
      const SizedBox(height: 12),
      PillButton('Clear what Ask Tick learned', style: PillStyle.quiet, onTap: () => _run(() => api.post('/ask/clear'), 'Cleared.')),
      if (_note != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_note!, style: context.ts(TickType.bodyS, color: c.textSecondary))),
    ]);
  }
}

class _Block extends ConsumerWidget {
  const _Block({required this.block, required this.ledger});
  final Map<String, dynamic> block;
  final LedgerState ledger;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    if (block['kind'] == 'see') {
      final f = (block['filter'] as Map).cast<String, dynamic>();
      final to = DateTime.parse(f['to'] as String);
      return Align(alignment: Alignment.centerLeft, child: TickChip('See the transactions', icon: 'activity', onTap: () {
        Navigator.of(context, rootNavigator: true).maybePop();
        openActivity(ref, ActivityQuery(since: etToUtc(DateTime.parse(f['from'] as String)), until: etToUtc(DateTime(to.year, to.month, to.day + 1)), categories: {...(f['categories'] as List? ?? const []).cast<String>()}, query: (f['query'] as String?) ?? ''));
      }));
    }
    if (block['kind'] == 'bars') {
      final vals = [for (final v in (block['values'] as List)) (v as Map)];
      final maxV = vals.fold<num>(1, (a, v) => (v['cents'] as num).abs() > a ? (v['cents'] as num).abs() : a);
      return TickCard(child: Column(children: [
        SizedBox(height: 80, child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          for (var i = 0; i < vals.length; i++) Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: Container(height: 80 * ((vals[i]['cents'] as num).abs() / maxV).clamp(0.05, 1.0).toDouble(), decoration: BoxDecoration(color: c.text.withValues(alpha: i == vals.length - 1 ? 1 : 0.25), borderRadius: BorderRadius.circular(8))))),
        ])),
        const SizedBox(height: 8),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [for (final v in vals) Text('${v['label']}', style: context.ts(TickType.monoS, size: 11.5, color: c.textSecondary))]),
      ]));
    }
    if (block['kind'] == 'txns') {
      final ts = [for (final id in (block['ids'] as List)) ledger.txns.where((t) => t.id == id).firstOrNull].whereType<dynamic>().toList();
      if (ts.isEmpty) return const SizedBox();
      return TickCard(padding: const EdgeInsets.symmetric(horizontal: 16), child: Column(children: [
        for (var i = 0; i < ts.length; i++) ...[if (i > 0) const Hairline(), TxRow(t: ts[i], ledger: ledger, onTap: () => context.push('/txn/${ts[i].id}'))],
      ]));
    }
    return const SizedBox();
  }
}
