import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'ledger.dart';
import 'ledger_codec.dart';

/// Last-known ledger on disk so Today opens instantly and works offline. Never holds tokens or secrets.
class LedgerCache {
  static Future<File> _file() async => File('${(await getApplicationSupportDirectory()).path}/ledger_cache.json');

  /// (userId the snapshot belongs to, state). Decoding runs off the UI isolate.
  static Future<({String? userId, LedgerState state})?> read() async {
    try {
      final f = await _file();
      if (!await f.exists()) return null;
      if (await f.length() > 4 * 1024 * 1024) { await f.delete(); return null; }       // never let a runaway file slow launch
      final raw = await f.readAsString();
      final out = await compute(_decode, raw);
      return out == null ? null : (userId: out.$1, state: out.$2);
    } catch (_) {
      return null;
    }
  }

  static Future<void> write(LedgerState s, {String? userId}) async {
    try {
      final json = await compute(_encode, (s, userId));
      final f = await _file();
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(json, flush: true);
      await tmp.rename(f.path);                                  // atomic: a crash mid-write cannot corrupt the cache
    } catch (_) {/* the cache is an optimisation only */}
  }

  static Future<void> clear() async {
    try {
      final f = await _file();
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}

String _encode((LedgerState, String?) a) => jsonEncode(encodeLedger(a.$1, userId: a.$2));

(String?, LedgerState)? _decode(String raw) {
  final j = jsonDecode(raw) as Map<String, dynamic>;
  final s = decodeLedger(j);
  return s == null ? null : (j['userId'] as String?, s);
}
