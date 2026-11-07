import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// Goldens are rendered and reviewed on the Mac (macOS font rendering). Linux CI draws text a few pixels
/// differently, so every golden would "fail" there. Off macOS, golden comparisons are skipped; everything
/// else in the test still runs. Regenerate with `flutter test --update-goldens` on the Mac.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  if (!Platform.isMacOS) goldenFileComparator = _MacOnlyGoldens(goldenFileComparator);
  await testMain();
}

class _MacOnlyGoldens extends GoldenFileComparator {
  _MacOnlyGoldens(this._inner);
  final GoldenFileComparator _inner;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async => true;

  @override
  Future<void> update(Uri golden, Uint8List imageBytes) => _inner.update(golden, imageBytes);

  @override
  Uri getTestUri(Uri key, int? version) => _inner.getTestUri(key, version);
}
