import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tick/data/statement_import.dart';
import 'package:tick/domain/notification_plan.dart';
import 'package:tick/features/import_screen.dart';
import 'package:tick/services/api.dart';
import 'package:tick/services/haptics.dart';
import 'package:tick/services/open_file.dart';
import 'golden_harness.dart';

void main() {
  setUpAll(loadFonts);

  test('previews parse: counts, sample, account suggestions, and the generic-CSV mapping request', () {
    final p = ImportPreview.fromJson({
      'source': 'discover', 'label': 'Discover statement', 'account_id': 'a1', 'needs_account': false, 'new': 2, 'duplicates': 1, 'already_imported': 3, 'unreadable': 1,
      'date_from': '2026-10-18', 'date_to': '2026-11-03', 'accounts': [{'id': 'a1', 'label': 'Discover ••1545', 'type': 'credit'}],
      'sample': [{'date': '2026-11-03', 'merchant': "TRADER JOE'S", 'cents': -4210}],
    });
    expect([p.fresh, p.skipped, p.unreadable, p.sample.single.cents], [2, 4, 1, -4210]);
    expect(p.accounts.single.label, 'Discover ••1545');
    final m = ImportPreview.fromJson({'source': 'generic', 'label': 'CSV statement', 'needs_mapping': {'columns': ['Posted', 'Memo'], 'header_row': 0, 'sample': [['11/03/2026', 'COFFEE']]}});
    expect(m.needsMapping, isTrue);
    expect(m.mappingColumns, ['Posted', 'Memo']);
    expect(m.mappingSample.first.last, 'COFFEE');
    expect(ImportPreview.fromJson({'source': 'x', 'label': 'x', 'needs_account': true}).needsAccount, isTrue);
  });

  test('server JSON is decoded as UTF-8 even when the response has no charset (Discover ••1545 used to turn into mojibake)', () async {
    final api = Api(client: MockClient((r) async => http.Response.bytes(utf8.encode('{"label":"Discover ••1545 — café"}'), 200, headers: {'content-type': 'application/json'})));
    expect((await api.get('/x'))['label'], 'Discover ••1545 — café');
  });

  test('files from the system are offered once, however many times the native side repeats them', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final n = c.read(incomingFilesProvider.notifier);
    n.offer('/tmp/a.csv');
    n.offer('/tmp/a.csv');
    n.offer('/tmp/b.csv');
    expect(c.read(incomingFilesProvider), ['/tmp/a.csv', '/tmp/b.csv']);
    expect(n.take(), '/tmp/a.csv');
    expect(c.read(incomingFilesProvider), ['/tmp/b.csv']);
  });

  test('statement day: one nudge on the 2nd at 9:00 for people with an Apple Card, deep-linking into import', () {
    final plan = planNotifications(now: DateTime(2026, 11, 6, 12), morningTime: '08:00', weeklyTime: '19:00', sts: null, recurring: const [], goals: const [], statementDay: true);
    final n = plan.where((p) => p.payload == 'import').single;
    expect(n.when, DateTime(2026, 12, 2, 9));
    expect(n.title, contains('Apple Card statement'));
    expect(planNotifications(now: DateTime(2026, 11, 6), morningTime: '08:00', weeklyTime: '19:00', sts: null, recurring: const [], goals: const []).where((p) => p.payload == 'import'), isEmpty);
  });

  testWidgets('opening a statement: detect, preview, import with the signature moment, then undo', (tester) async {
    var commits = 0, undone = false;
    final client = MockClient((req) async {
      if (req.url.path.endsWith('/undo')) { undone = true; return http.Response('{"undone":true,"removed":2}', 200); }
      final body = utf8.decode(req.bodyBytes, allowMalformed: true);
      final commit = body.contains('commit');
      if (commit) commits++;
      return http.Response.bytes(utf8.encode(jsonEncode({
        'source': 'discover', 'label': 'Discover statement', 'account_id': 'a1', 'needs_account': false, 'new': 2, 'duplicates': 1, 'already_imported': 0, 'unreadable': 0,
        'date_from': '2026-10-18', 'date_to': '2026-11-03', 'accounts': [{'id': 'a1', 'label': 'Discover ••1545', 'type': 'credit'}],
        'sample': [{'date': '2026-11-03', 'merchant': "TRADER JOE'S #123", 'cents': -4210}],
        if (commit) 'batch_id': 'b1', if (commit) 'imported': 2,
      })), 200, headers: {'content-type': 'application/json'});
    });
    final c = await demoContainer(demo: false, overrides: [apiProvider.overrideWithValue(Api(client: client)), incomingReaderProvider.overrideWithValue((p) async => (utf8.encode('Trans. Date,Post Date,Description,Amount,Category\n'), 'discover.csv'))]);
    addTearDown(c.dispose);
    await pumpGolden(tester, frame(c, const ImportScreen(path: '/x/abc-discover.csv'), dark: true));
    expect(find.text('Discover statement'), findsOneWidget);
    expect(find.text('Import 2'), findsOneWidget);
    expect(find.text("Trader Joe's"), findsOneWidget);                                // cleaned merchant in the preview
    await tester.tap(find.text('Import 2'));
    await tester.pump(const Duration(milliseconds: 300));
    for (var i = 0; i < 20; i++) { await tester.pump(const Duration(milliseconds: 100)); }
    expect(commits, 1);
    expect(find.text('Imported 2, skipped 1 duplicate'), findsOneWidget);
    expect(TickHaptics.instance.log, containsAllInOrder(['sort_right', 'price_weight_mid']));
    await tester.tap(find.text('Undo import'));
    for (var i = 0; i < 10; i++) { await tester.pump(const Duration(milliseconds: 100)); }
    expect(undone, isTrue);
    expect(find.text('Import undone'), findsOneWidget);
  });

  testWidgets('demo mode and unreadable files end calmly, never in a red screen', (tester) async {
    final c = await demoContainer(demo: true, overrides: [incomingReaderProvider.overrideWithValue((p) async => (utf8.encode('a,b'), 'x.csv'))]);
    addTearDown(c.dispose);
    await pumpGolden(tester, frame(c, const ImportScreen(path: '/nope/missing.csv'), dark: false));
    expect(find.text('That file didn\'t import'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
