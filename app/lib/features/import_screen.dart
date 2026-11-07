import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../data/ledger.dart';
import '../data/settings.dart';
import '../data/statement_import.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../design/widgets/more.dart';
import '../design/widgets/scaffold.dart';
import '../domain/merchant_name.dart';
import '../services/api.dart';
import '../services/haptics.dart';
import '../services/open_file.dart';
import 'common.dart';

enum _Step { pick, reading, mapping, preview, importing, done, undone, failed }

/// Import a bank statement: "Open in Tick" from Wallet or Files lands here with the file; otherwise choose one. Detect the bank, preview
/// (account, dates, new vs duplicates), import with a small celebration, and "Undo import" removes exactly that batch.
class ImportScreen extends ConsumerStatefulWidget {
  const ImportScreen({super.key, this.path});
  final String? path;
  @override
  ConsumerState<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends ConsumerState<ImportScreen> {
  _Step _step = _Step.pick;
  (List<int>, String)? _file;
  ImportPreview? _p;
  String? _accountId;
  String? _error;
  Map<String, dynamic> _map = {'negative_is_out': true};
  bool _splitCols = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final p = widget.path ?? ref.read(incomingFilesProvider.notifier).take();
      if (p != null) { final f = await ref.read(incomingReaderProvider)(p); if (f != null) { _file = f; _analyse(); } else { setState(() { _step = _Step.failed; _error = 'Tick couldn\'t open that file.'; }); } }
    });
  }

  Future<void> _choose() async {
    try {
      final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: const ['csv', 'ofx', 'qfx', 'qbo', 'txt']);
      if (files.isEmpty) return;
      final f = files.first.xFile;
      if (await f.length() > 5 * 1024 * 1024) { setState(() { _step = _Step.failed; _error = 'That file is too big for one statement.'; }); return; }
      _file = ((await f.readAsBytes()).toList(), files.first.name);
      _analyse();
    } catch (_) {
      if (mounted) setState(() { _step = _Step.failed; _error = 'Tick couldn\'t open that file.'; });
    }
  }

  Future<void> _analyse({Map<String, dynamic>? mapping}) async {
    if (ref.read(settingsProvider).demoMode) { setState(() { _step = _Step.failed; _error = 'Turn off demo mode to import a real statement.'; }); return; }
    setState(() => _step = _Step.reading);
    try {
      final p = await ref.read(statementImportApiProvider).send(_file!.$1, _file!.$2, commit: false, accountId: _accountId, mapping: mapping);
      if (!mounted) return;
      _p = p;
      _accountId ??= p.accountId ?? (p.accounts.isNotEmpty ? p.accounts.first.id : null);
      if (p.needsMapping) { setState(() => _step = _Step.mapping); return; }
      if (p.needsAccount && _accountId != null) { await _analyse(mapping: mapping); return; }          // ask again with the best-matching account chosen
      setState(() => _step = _Step.preview);
    } catch (e) {
      if (mounted) setState(() { _step = _Step.failed; _error = describeError(e, action: 'read that statement'); });
    }
  }

  Future<void> _commit() async {
    setState(() => _step = _Step.importing);
    TickHaptics.instance.confirm();
    try {
      final p = await ref.read(statementImportApiProvider).send(_file!.$1, _file!.$2, commit: true, accountId: _accountId, mapping: _p?.source == 'generic' ? _map : null);
      if (!mounted) return;
      _p = p;
      await ref.read(ledgerProvider.notifier).refresh();
      TickHaptics.instance.success();
      setState(() => _step = _Step.done);
    } catch (e) {
      if (mounted) setState(() { _step = _Step.failed; _error = describeError(e, action: 'read that statement'); });
    }
  }

  Future<void> _undo() async {
    final id = _p?.batchId;
    if (id == null) return;
    try {
      await ref.read(statementImportApiProvider).undo(id);
      await ref.read(ledgerProvider.notifier).refresh();
      TickHaptics.instance.confirm();
      if (mounted) setState(() => _step = _Step.undone);
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e, action: 'undo that import'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final p = _p;
    return TickPage(
      title: 'Import statement', onBack: () => context.pop(),
      children: [
        switch (_step) {
          _Step.pick => _Pick(onChoose: _choose),
          _Step.reading => Padding(padding: const EdgeInsets.symmetric(vertical: 48), child: Column(children: [const TickLoader(), const SizedBox(height: 16), Text('Reading your statement…', style: context.ts(TickType.body, color: c.textSecondary))])),
          _Step.mapping => _Mapping(p: p!, map: _map, split: _splitCols, onSplit: (v) => setState(() => _splitCols = v), onChanged: () => setState(() {}),
              onContinue: () { _map = {..._map, 'header_row': p.mappingHeaderRow}; _analyse(mapping: _map); }),
          _Step.preview || _Step.importing => _Preview(p: p!, accountId: _accountId, busy: _step == _Step.importing, onAccount: (id) { setState(() => _accountId = id); _analyse(mapping: _p?.source == 'generic' ? _map : null); }, onImport: _commit),
          _Step.done => _Done(p: p!, error: _error, onUndo: _undo, onDone: () => context.pop()),
          _Step.undone => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const EmptyState('Import undone', 'Everything that import added is gone. Nothing else changed.', icon: 'undo'),
              PillButton('Done', onTap: () => context.pop()),
            ]),
          _Step.failed => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              EmptyState('That file didn\'t import', _error ?? 'Try another file.', icon: 'import'),
              PillButton('Choose another file', onTap: _choose),
            ]),
        },
      ],
    );
  }
}

class _Pick extends StatelessWidget {
  const _Pick({required this.onChoose});
  final VoidCallback onChoose;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    Widget step(int n, String t) => Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(width: 26, height: 26, alignment: Alignment.center, decoration: BoxDecoration(color: c.surface2, shape: BoxShape.circle), child: Text('$n', style: context.ts(TickType.monoS, size: 13))),
          const SizedBox(width: 12), Expanded(child: Text(t, style: context.ts(TickType.body))),
        ]));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Apple Card, Chase, Bank of America, Discover, Capital One, SoFi, or any CSV or OFX file. Tick recognises the bank from the file.', style: context.ts(TickType.body, color: c.textSecondary)),
      const SizedBox(height: 16),
      TickCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Apple Card, in three steps', style: context.ts(TickType.title, size: 16)),
        const SizedBox(height: 6),
        step(1, 'Wallet → Apple Card → Statements → pick a month → Export Transactions.'),
        step(2, 'Share → choose Tick.'),
        step(3, 'Check the preview and tap Import.'),
      ])),
      const SizedBox(height: 16),
      PillButton('Choose a file', icon: 'import', onTap: onChoose),
      const SizedBox(height: 12),
      Text('Statements are read, never sent anywhere but your own Tick server. Anything Tick already has is skipped, and you can undo an import.', style: context.ts(TickType.bodyS, color: c.textSecondary)),
    ]);
  }
}

class _Preview extends StatelessWidget {
  const _Preview({required this.p, required this.accountId, required this.busy, required this.onAccount, required this.onImport});
  final ImportPreview p;
  final String? accountId;
  final bool busy;
  final ValueChanged<String> onAccount;
  final VoidCallback onImport;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final fmt = DateFormat('MMM d');
    final range = p.from == null || p.to == null ? '' : '${fmt.format(p.from!)} to ${fmt.format(p.to!)}';
    if (p.empty || (p.fresh == 0 && p.skipped == 0)) {
      return const EmptyState('Nothing to import', 'That file has no transactions Tick can read.', icon: 'import');
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(p.label, style: context.ts(TickType.bodyS, size: 13, color: c.textSecondary).copyWith(fontWeight: FontWeight.w700)),
      if (range.isNotEmpty) Text(range, style: context.ts(TickType.body, color: c.textSecondary)),
      const SizedBox(height: 12),
      TickCard(raised: true, child: Semantics(
        label: '${p.fresh} new transactions, ${p.skipped} skipped as duplicates', excludeSemantics: true,
        child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text('${p.fresh}', style: context.ts(TickType.hero, size: 44))),
            Text('new', style: context.ts(TickType.body, color: c.textSecondary)),
          ])),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text('${p.skipped}', style: context.ts(TickType.hero, size: 44, color: c.textSecondary))),
            Text('already in Tick', style: context.ts(TickType.body, color: c.textSecondary)),
          ])),
        ]),
      )),
      if (p.accounts.length > 1 && p.source != 'apple_card') ...[
        const SectionLabel('Add them to'),
        Wrap(spacing: 8, runSpacing: 4, children: [for (final a in p.accounts) TickChip(a.label, on: a.id == accountId, onTap: busy ? null : () => onAccount(a.id))]),
      ],
      if (p.sample.isNotEmpty) ...[
        const SectionLabel('A few of the new ones'),
        TickCard(padding: const EdgeInsets.symmetric(horizontal: 16), child: Column(children: [
          for (final (i, r) in p.sample.indexed) ...[
            if (i > 0) const Hairline(),
            Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(cleanMerchant(r.merchant), maxLines: 1, overflow: TextOverflow.ellipsis, style: context.ts(TickType.title, size: 15.5)),
                Text(fmt.format(r.date), style: context.ts(TickType.bodyS, size: 12.5, color: c.textSecondary)),
              ])),
              const SizedBox(width: 8),
              Money(r.cents),
            ])),
          ],
        ])),
      ],
      if (p.unreadable > 0) Padding(padding: const EdgeInsets.only(top: 8), child: Text('${p.unreadable} ${p.unreadable == 1 ? 'row' : 'rows'} couldn\'t be read and will be skipped.', style: context.ts(TickType.bodyS, color: c.textSecondary))),
      const SizedBox(height: 16),
      PillButton(p.fresh == 0 ? 'Nothing new to add' : 'Import ${p.fresh}', busy: busy, onTap: p.fresh == 0 || accountId == null ? null : onImport),
    ]);
  }
}

class _Mapping extends StatelessWidget {
  const _Mapping({required this.p, required this.map, required this.split, required this.onSplit, required this.onChanged, required this.onContinue});
  final ImportPreview p;
  final Map<String, dynamic> map;
  final bool split;
  final ValueChanged<bool> onSplit;
  final VoidCallback onChanged;
  final VoidCallback onContinue;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final cols = p.mappingColumns ?? const [];
    Widget pick(String key, String label) => Padding(padding: const EdgeInsets.only(bottom: 12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: context.ts(TickType.bodyS, size: 13, color: c.textSecondary).copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 4, children: [for (final col in cols) if (col.isNotEmpty) TickChip(col, on: map[key] == col, onTap: () { map[key] = col; onChanged(); })]),
        ]));
    final ok = map['date'] != null && map['description'] != null && (split ? (map['debit'] != null || map['credit'] != null) : map['amount'] != null);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Tick doesn\'t know this bank\'s layout. Tell it which column is which, once.', style: context.ts(TickType.body, color: c.textSecondary)),
      const SizedBox(height: 16),
      if (p.mappingSample.isNotEmpty) TickCard(padding: const EdgeInsets.all(12), child: Text(p.mappingSample.first.join('  ·  '), maxLines: 3, overflow: TextOverflow.ellipsis, style: context.ts(TickType.monoS, size: 12, color: c.textSecondary))),
      const SizedBox(height: 16),
      pick('date', 'Date'),
      pick('description', 'Description'),
      Row(children: [Expanded(child: Text('Separate debit and credit columns', style: context.ts(TickType.body))), TickToggle(label: 'Separate debit and credit columns', on: split, onChanged: onSplit)]),
      const SizedBox(height: 12),
      if (!split) ...[pick('amount', 'Amount'), Row(children: [Expanded(child: Text('Money out is negative', style: context.ts(TickType.body))), TickToggle(label: 'Money out is negative', on: map['negative_is_out'] == true, onChanged: (v) { map['negative_is_out'] = v; onChanged(); })]), const SizedBox(height: 12)]
      else ...[pick('debit', 'Money out column'), pick('credit', 'Money in column')],
      PillButton('Continue', onTap: ok ? onContinue : null),
    ]);
  }
}

/// The signature moment: tally marks draw in one by one (four strokes, then the diagonal), the count rolls up, a mid price-weight haptic.
class _Done extends StatefulWidget {
  const _Done({required this.p, required this.error, required this.onUndo, required this.onDone});
  final ImportPreview p;
  final String? error;
  final VoidCallback onUndo;
  final VoidCallback onDone;
  @override
  State<_Done> createState() => _DoneState();
}

class _DoneState extends State<_Done> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));
  bool _started = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) { _started = true; if (context.reduceMotion) { _c.value = 1; } else { _c.forward(); } }
  }
  @override
  void dispose() { _c.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final n = widget.p.imported ?? widget.p.fresh;
    final s = widget.p.skipped;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Center(child: SizedBox(width: 120, height: 90, child: AnimatedBuilder(animation: _c, builder: (_, _) => CustomPaint(painter: TallyPainter(progress: Curves.easeOutCubic.transform(_c.value), color: c.text, accent: context.isDark ? c.accent : c.text))))),
      const SizedBox(height: 12),
      Semantics(liveRegion: true, child: Text('Imported $n, skipped $s ${s == 1 ? 'duplicate' : 'duplicates'}', textAlign: TextAlign.center, style: context.ts(TickType.displayM))),
      const SizedBox(height: 6),
      Text(n == 0 ? 'Tick already had everything in that file.' : 'They\'re in Activity now, with transfers and card payments kept out of your spending.', textAlign: TextAlign.center, style: context.ts(TickType.body, color: c.textSecondary)),
      if (widget.error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(widget.error!, textAlign: TextAlign.center, style: context.ts(TickType.bodyS, color: c.alert))),
      const SizedBox(height: 24),
      PillButton('Done', onTap: widget.onDone),
      if (n > 0 && widget.p.batchId != null) ...[const SizedBox(height: 8), PillButton('Undo import', style: PillStyle.quiet, onTap: widget.onUndo)],
    ]);
  }
}

/// Four tally strokes and the crossing fifth, drawn by [progress] 0..1. Shared with Tally's "All square".
class TallyPainter extends CustomPainter {
  TallyPainter({required this.progress, required this.color, required this.accent});
  final double progress;
  final Color color;
  final Color accent;
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = color..strokeWidth = size.width / 22..strokeCap = StrokeCap.round;
    final gap = size.width / 5.4;
    final top = size.height * 0.12, bottom = size.height * 0.88;
    for (var i = 0; i < 4; i++) {
      final t = ((progress * 5) - i).clamp(0.0, 1.0);
      if (t <= 0) continue;
      final x = size.width * 0.14 + gap * i;
      canvas.drawLine(Offset(x, top), Offset(x, top + (bottom - top) * t), p);
    }
    final t5 = ((progress * 5) - 4).clamp(0.0, 1.0);
    if (t5 > 0) {
      final a = Offset(0, size.height * 0.78), b = Offset(size.width, size.height * 0.22);
      canvas.drawLine(a, Offset(a.dx + (b.dx - a.dx) * t5, a.dy + (b.dy - a.dy) * t5), p..color = accent);
    }
  }
  @override
  bool shouldRepaint(TallyPainter old) => old.progress != progress || old.color != color || old.accent != accent;
}

