import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/env.dart';
import 'api.dart';

class AiStatus {
  const AiStatus({required this.available, required this.used, required this.limit, required this.models, this.note});
  final bool available;
  final int used;
  final int limit;
  final List<String> models;
  final String? note;
  String get line => available ? 'AI today: $used of $limit' : 'AI is off';
  factory AiStatus.off([String? note]) => AiStatus(available: false, used: 0, limit: 40, models: const [], note: note ?? 'AI is off. Everything works without it.');
  factory AiStatus.fromJson(Map<String, dynamic> j) {
    final m = (j['models'] as Map?) ?? const {};
    final names = <String>{for (final k in ['tools', 'json', 'text']) ...((m[k] as List?) ?? const []).cast<String>()}.map((e) => e.replaceAll(':free', '')).toList();
    return AiStatus(available: (j['available'] ?? false) as bool, used: ((j['used'] ?? 0) as num).toInt(), limit: ((j['limit'] ?? 40) as num).toInt(), models: names, note: j['note'] as String?);
  }
}

/// Live status from the API: how many free-model calls were used today and which free models are in play.
final aiStatusProvider = FutureProvider.autoDispose<AiStatus>((ref) async {
  if (!Env.hasSupabase) return AiStatus.off();
  try {
    return AiStatus.fromJson(await ref.read(apiProvider).get('/ai/status'));
  } catch (_) {
    return AiStatus.off('Can\'t reach Tick right now.');
  }
});
