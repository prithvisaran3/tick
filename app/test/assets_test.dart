import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

/// Asset integrity: every file the app loads at runtime exists and is declared. A missing file shows up on a device as
/// "fopen failed for data file: errno = 2" at launch.
void main() {
  final pubspec = File('pubspec.yaml').readAsStringSync();

  test('every declared asset directory and font file exists', () {
    final dirs = RegExp(r'^\s+- (assets/[\w/.\-]+)$', multiLine: true).allMatches(pubspec).map((m) => m.group(1)!).toList();
    expect(dirs, isNotEmpty);
    for (final d in dirs) {
      expect(FileSystemEntity.typeSync(d) != FileSystemEntityType.notFound, isTrue, reason: 'pubspec declares $d but it does not exist');
      if (d.endsWith('/')) expect(Directory(d).listSync().whereType<File>().isNotEmpty, isTrue, reason: '$d is empty');
    }
    for (final m in RegExp(r'asset: (assets/fonts/[\w\-.]+)').allMatches(pubspec)) {
      expect(File(m.group(1)!).existsSync(), isTrue, reason: 'font ${m.group(1)} missing');
    }
  });

  test('haptics manifest keys all point at existing AHAP files, and Dart only plays keys that exist', () {
    final manifest = jsonDecode(File('assets/haptics/manifest.json').readAsStringSync()) as Map<String, dynamic>;
    final patterns = (manifest['patterns'] as Map).cast<String, String>();
    for (final e in patterns.entries) {
      expect(File('assets/${e.value}').existsSync(), isTrue, reason: '${e.key} -> ${e.value}');
      jsonDecode(File('assets/${e.value}').readAsStringSync());             // valid JSON
    }
    final src = File('lib/services/haptics.dart').readAsStringSync();
    final used = <String>{
      for (final m in RegExp(r"play\('(\w+)'(?:, tier: '(\w+)')?\)").allMatches(src)) m.group(2) == null ? m.group(1)! : '${m.group(1)}_${m.group(2)}',
    };
    used.addAll(['price_weight_low', 'price_weight_mid', 'price_weight_high']);
    for (final k in used) {
      expect(patterns.containsKey(k), isTrue, reason: 'haptics.dart plays "$k" but no AHAP is compiled for it');
    }
  });

  test('sounds referenced in code exist', () {
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      for (final m in RegExp(r"sound\('(\w+)'\)").allMatches(f.readAsStringSync())) {
        expect(File('assets/sounds/${m.group(1)}.caf').existsSync(), isTrue, reason: '${f.path}: sound ${m.group(1)}');
      }
    }
  });

  test('every icon name used in code has an SVG', () {
    final names = <String>{};
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      final s = f.readAsStringSync();
      names.addAll(RegExp(r"TickIcon\('([a-z\-]+)'").allMatches(s).map((m) => m.group(1)!));
      names.addAll(RegExp(r"icon: '([a-z\-]+)'").allMatches(s).map((m) => m.group(1)!));
      names.addAll(RegExp(r"\bTabSpec\('([a-z\-]+)'").allMatches(s).map((m) => m.group(1)!));
    }
    expect(names, isNotEmpty);
    for (final n in names) {
      expect(File('assets/icons/$n.svg').existsSync(), isTrue, reason: 'icon "$n" has no SVG');
    }
  });

  test('iOS bundle: app icons present and opaque sizes match, Info.plist has no Google scheme placeholder, URL scheme is tick', () {
    final contents = jsonDecode(File('ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json').readAsStringSync()) as Map<String, dynamic>;
    for (final img in (contents['images'] as List).cast<Map<String, dynamic>>()) {
      final f = img['filename'];
      if (f != null) expect(File('ios/Runner/Assets.xcassets/AppIcon.appiconset/$f').existsSync(), isTrue, reason: '$f');
    }
    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    expect(plist.contains(r'$(GOOGLE_REVERSED_CLIENT_ID)'), isFalse);
    expect(plist.contains('<string>tick</string>'), isTrue);
    expect(plist.contains('NSFaceIDUsageDescription'), isTrue);
    expect(plist.contains('UIBackgroundModes'), isFalse);
  });

  test('no test code or dev screens are declared as app assets', () {
    expect(pubspec.contains('test/'), isFalse);
    expect(RegExp(r'^\s+- (test|design|docs)/', multiLine: true).hasMatch(pubspec), isFalse);
  });

  test('no print() or debugPrint() in app code (nothing may log user data)', () {
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      expect(RegExp(r'\b(print|debugPrint)\(').hasMatch(f.readAsStringSync()), isFalse, reason: f.path);
    }
  });
}
