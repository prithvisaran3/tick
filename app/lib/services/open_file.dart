import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Files the system hands to Tick: "Open in Tick" from Wallet / Files / Mail, and the Shortcuts action "Import statement to Tick".
/// The native side (ios/Runner/TickImport.swift) copies the file into the app's temp folder and tells Dart its path.
class IncomingFiles extends Notifier<List<String>> {
  static const _ch = MethodChannel('tick/import');
  final _seen = <String>{};
  @override
  List<String> build() {
    try {
      _ch.setMethodCallHandler((call) async {
        if (call.method == 'opened' && call.arguments is String) { offer(call.arguments as String); _takePending(); }
      });
    } catch (_) {}
    _takePending();
    return const [];
  }

  /// Files that arrived before Dart was listening (a cold start from "Open in Tick"). The native side queues every file and also sends a
  /// live event, so a path is offered once however it arrives.
  Future<void> _takePending() async {
    try {
      final r = await _ch.invokeMethod<List<Object?>>('takePending');
      for (final p in (r ?? const []).whereType<String>()) { offer(p); }
    } catch (_) {/* no native side (tests, simulator without the plugin) */}
  }

  /// The route takes the file: removes it from the queue so it is only offered once.
  String? take() {
    if (state.isEmpty) return null;
    final p = state.first;
    state = state.sublist(1);
    return p;
  }

  void offer(String path) {
    if (_seen.add(path)) state = [...state, path];
  }
}

final incomingFilesProvider = NotifierProvider<IncomingFiles, List<String>>(IncomingFiles.new);

/// Reads a file handed over by the system. A provider so tests can supply bytes without real file IO (which never completes under fake async).
final incomingReaderProvider = Provider<Future<(List<int>, String)?> Function(String)>((ref) => readIncoming);

/// Reads a file handed over by the system (size-checked; the server refuses anything over 5 MB anyway).
Future<(List<int>, String)?> readIncoming(String path) async {
  try {
    final f = File(path);
    if (!await f.exists() || await f.length() > 5 * 1024 * 1024) return null;
    final bytes = await f.readAsBytes();
    try { await f.delete(); } catch (_) {/* tmp is purged by iOS anyway */}   // don't leave a statement copy lying around
    return (bytes, path.split('/').last.replaceFirst(RegExp(r'^[0-9a-f-]{36}-'), ''));
  } catch (_) {
    return null;
  }
}
