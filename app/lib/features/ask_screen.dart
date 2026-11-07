import '../services/api.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../data/env.dart';
import '../data/ledger.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../design/widgets/more.dart';
import '../design/widgets/scaffold.dart';
import 'common.dart';

class AskMessage {
  AskMessage(this.fromUser, this.text, {List<Map<String, dynamic>>? blocks, this.failed = false}) : blocks = blocks ?? [];
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
        await _stream(question, history, reply);
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

  Future<void> _stream(String q, List<Map<String, String>> history, AskMessage reply) async {
    final token = Env.hasSupabase ? Supabase.instance.client.auth.currentSession?.accessToken : null;
    if (token == null) throw ApiException(401, messageForStatus(401, null));
    final client = http.Client();
    _client = client;
    try {
      final req = http.Request('POST', Uri.parse('${Env.apiBaseUrl}/ask'))
        ..headers.addAll({'Authorization': 'Bearer $token', 'Content-Type': 'application/json', 'Accept': 'text/event-stream'})
        ..body = jsonEncode({'question': q, 'history': history});
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
          case 'done': finished = true;
        }
        state = [...state];
        if (finished) break;
      }
      if (!finished && reply.text.isEmpty) throw StateError('empty stream');
    } finally {
      client.close();
      if (identical(_client, client)) _client = null;
    }
  }
}

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
    ref.read(askProvider.notifier).ask(text);
    setState(() {});
    Future.delayed(const Duration(milliseconds: 100), () { if (mounted && _scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 250), curve: Curves.easeOut); });
  }

  @override
  Widget build(BuildContext context) {
    final msgs = ref.watch(askProvider);
    final busy = ref.read(askProvider.notifier).busy;
    final l = ref.watch(ledgerProvider);
    final c = context.c;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (!widget.inSheet) const ScreenTitle('Ask Tick'),
      Expanded(
        child: msgs.isEmpty
            ? ListView(children: [
                const EmptyState('Ask me anything about your money.', 'Answers lead with the number.', icon: 'ask'),
                Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [for (final q in suggestedQuestions.take(4)) TickChip(q, onTap: () => _send(q))]),
              ])
            : ListView(controller: _scroll, padding: const EdgeInsets.only(bottom: 16), children: [
                for (final m in msgs) m.fromUser ? _UserBubble(m.text) : _Answer(m: m, ledger: l, onRetry: () => ref.read(askProvider.notifier).retry()),
              ]),
      ),
      ChipRow(children: [for (final q in suggestedQuestions) TickChip(q, onTap: () => _send(q))]),
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
        if (m.failed) Padding(padding: const EdgeInsets.only(top: 12), child: Row(children: [TickChip('Try again', icon: 'repeat', onTap: onRetry)])),
      ]),
    );
  }
}

class _Block extends StatelessWidget {
  const _Block({required this.block, required this.ledger});
  final Map<String, dynamic> block;
  final LedgerState ledger;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
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
