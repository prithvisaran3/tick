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
import 'common.dart';

class AskMessage {
  AskMessage(this.fromUser, this.text, {List<Map<String, dynamic>>? blocks}) : blocks = blocks ?? [];
  final bool fromUser;
  String text;
  final List<Map<String, dynamic>> blocks;
}

class AskNotifier extends Notifier<List<AskMessage>> {
  bool busy = false;
  @override
  List<AskMessage> build() => [];

  /// Streams an answer from POST /ask (SSE). Events: {type:token,text}, {type:block,block}, {type:done}.
  Future<void> ask(String q) async {
    if (busy || q.trim().isEmpty) return;
    busy = true;
    final reply = AskMessage(false, '');
    state = [...state, AskMessage(true, q.trim()), reply];
    try {
      final token = Env.hasSupabase ? Supabase.instance.client.auth.currentSession?.accessToken : null;
      if (token == null) throw StateError('offline');
      final req = http.Request('POST', Uri.parse('${Env.apiBaseUrl}/ask'))
        ..headers.addAll({'Authorization': 'Bearer $token', 'Content-Type': 'application/json', 'Accept': 'text/event-stream'})
        ..body = jsonEncode({'question': q.trim(), 'history': [for (final m in state.take(state.length - 2).toList().reversed.take(6).toList().reversed) {'role': m.fromUser ? 'user' : 'assistant', 'text': m.text}]});
      final res = await http.Client().send(req).timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) throw StateError('status ${res.statusCode}');
      await for (final line in res.stream.transform(utf8.decoder).transform(const LineSplitter())) {
        if (!line.startsWith('data:')) continue;
        final ev = jsonDecode(line.substring(5).trim()) as Map<String, dynamic>;
        switch (ev['type']) {
          case 'token': reply.text += ev['text'] as String;
          case 'block': reply.blocks.add(ev['block'] as Map<String, dynamic>);
          case 'done': break;
        }
        state = [...state];
      }
      if (reply.text.isEmpty) reply.text = 'I couldn\'t find an answer for that. Try asking it another way.';
    } catch (_) {
      reply.text = 'Can\'t reach Tick right now. Showing your last known numbers on Today and Flows.';
    }
    busy = false;
    state = [...state];
  }
}

final askProvider = NotifierProvider<AskNotifier, List<AskMessage>>(AskNotifier.new);

const suggestedQuestions = ['How much did I spend on food this month?', "What's due this week?", 'Business total this month', 'Which subscriptions am I paying for?', 'Can I afford \$200 today?'];

class AskScreen extends ConsumerStatefulWidget {
  const AskScreen({super.key});
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
    final text = q ?? _ctl.text;
    _ctl.clear();
    ref.read(askProvider.notifier).ask(text);
    setState(() {});
    Future.delayed(const Duration(milliseconds: 100), () { if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 250), curve: Curves.easeOut); });
  }

  @override
  Widget build(BuildContext context) {
    final msgs = ref.watch(askProvider);
    final l = ref.watch(ledgerProvider);
    final c = context.c;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const ScreenTitle('Ask Tick'),
      Expanded(
        child: msgs.isEmpty
            ? ListView(children: [
                const EmptyState('Ask me anything about your money.', 'Answers lead with the number.', icon: 'ask'),
                Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [for (final q in suggestedQuestions.take(4)) TickChip(q, onTap: () => _send(q))]),
              ])
            : ListView(controller: _scroll, padding: const EdgeInsets.only(bottom: 16), children: [
                for (final m in msgs) m.fromUser ? _UserBubble(m.text) : _Answer(m: m, ledger: l),
              ]),
      ),
      SizedBox(
        height: 36,
        child: ListView(scrollDirection: Axis.horizontal, clipBehavior: Clip.none, children: [for (final q in suggestedQuestions) Padding(padding: const EdgeInsets.only(right: 8), child: TickChip(q, onTap: () => _send(q)))]),
      ),
      const SizedBox(height: 8),
      Padding(
        padding: const EdgeInsets.only(bottom: 112),
        child: Container(
          height: 52, padding: const EdgeInsets.only(left: 16, right: 6), decoration: BoxDecoration(color: c.surface2, borderRadius: BorderRadius.circular(999)),
          child: Row(children: [
            Expanded(child: Stack(alignment: Alignment.centerLeft, children: [
              if (_ctl.text.isEmpty) IgnorePointer(child: Text('Ask anything about your money', style: context.ts(TickType.body, color: c.textSecondary))),
              EditableText(controller: _ctl, focusNode: _focus, style: context.ts(TickType.body), cursorColor: c.text, backgroundCursorColor: c.surface2, selectionColor: c.hairline, onChanged: (_) => setState(() {}), onSubmitted: (v) => _send()),
            ])),
            Pressable(onTap: _send, semanticLabel: 'Send', child: Container(width: 40, height: 40, decoration: BoxDecoration(color: _ctl.text.isEmpty ? c.surface1 : c.accent, shape: BoxShape.circle), alignment: Alignment.center, child: TickIcon('arrow-up', size: 20, color: _ctl.text.isEmpty ? c.textSecondary : c.onAccent))),
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
  const _Answer({required this.m, required this.ledger});
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
