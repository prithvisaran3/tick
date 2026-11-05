import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/ledger.dart';
import '../data/settings.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets/core.dart';
import '../design/widgets/more.dart';
import '../services/api.dart';

/// Picks the CSV that Wallet exports (Apple Card -> Statements -> Export Transactions) and sends it to the server, which skips
/// anything already captured live from Wallet. Tick never moves money; this only reads the statement.
Future<void> importAppleCard(BuildContext context, WidgetRef ref, {Future<(List<int>, String)?> Function()? pick}) async {
  if (ref.read(settingsProvider).demoMode) {
    await _result(context, 'Demo mode is on', 'Turn off demo mode to import a real statement.');
    return;
  }
  final ok = await showTickSheet<bool>(context, builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Import Apple Card statement', style: ctx.ts(TickType.displayM)),
        const SizedBox(height: 8),
        Text('In Wallet, open Apple Card, tap Statements, pick a month, then Export Transactions as CSV and save it to Files.', style: ctx.ts(TickType.body)),
        const SizedBox(height: 8),
        Text('Purchases Tick already caught from Wallet are skipped, so nothing shows twice.', style: ctx.ts(TickType.bodyS, color: ctx.c.textSecondary)),
        const SizedBox(height: 20),
        PillButton('Choose the CSV', onTap: () => Navigator.of(ctx).pop(true)),
      ]));
  if (ok != true || !context.mounted) return;
  (List<int>, String)? file;
  try {
    file = await (pick ?? _pickCsv)();
  } catch (_) {
    file = null;
  }
  if (file == null || !context.mounted) return;
  try {
    final j = await ref.read(apiProvider).postFile('/import/apple-card', 'file', file.$1, file.$2);
    final imported = (j['imported'] as num?)?.toInt() ?? 0;
    final skipped = (j['skipped_duplicates'] as num?)?.toInt() ?? 0;
    final again = (j['already_imported'] as num?)?.toInt() ?? 0;
    await ref.read(ledgerProvider.notifier).refresh();
    if (!context.mounted) return;
    await _result(context, 'Imported $imported, skipped $skipped ${skipped == 1 ? 'duplicate' : 'duplicates'}',
        again > 0 ? '$again were already in Tick from an earlier import.' : 'They are on your Apple Card in Activity.');
  } on ApiException catch (e) {
    if (context.mounted) await _result(context, 'That file didn\'t import', e.message);
  }
}

Future<(List<int>, String)?> _pickCsv() async {
  final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: const ['csv']);
  if (files.isEmpty) return null;
  final f = files.first.xFile;
  if (await f.length() > 2000000) throw const FormatException('too big');      // the server refuses larger files anyway
  return ((await f.readAsBytes()).toList(), files.first.name);
}

Future<void> _result(BuildContext context, String title, String body) => showTickSheet<void>(context, builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: ctx.ts(TickType.displayM)),
      const SizedBox(height: 8),
      Text(body, style: ctx.ts(TickType.body, color: ctx.c.textSecondary)),
      const SizedBox(height: 16),
      PillButton('Done', onTap: () => Navigator.of(ctx).pop()),
    ]));
