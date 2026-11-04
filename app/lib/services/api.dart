import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../data/env.dart';

class ApiException implements Exception {
  ApiException(this.status, this.message);
  final int status;
  final String message;
  @override
  String toString() => message;
}

/// Thin client for the Tick FastAPI service. Sends the Supabase JWT; never touches Plaid tokens.
class Api {
  Map<String, String> get _h {
    final t = Env.hasSupabase ? Supabase.instance.client.auth.currentSession?.accessToken : null;
    return {'Content-Type': 'application/json', if (t != null) 'Authorization': 'Bearer $t'};
  }

  Future<Map<String, dynamic>> get(String path) async {
    final r = await http.get(Uri.parse('${Env.apiBaseUrl}$path'), headers: _h).timeout(const Duration(seconds: 20));
    return _decode(r);
  }

  Future<Map<String, dynamic>> post(String path, [Map<String, dynamic>? body]) async {
    final r = await http.post(Uri.parse('${Env.apiBaseUrl}$path'), headers: _h, body: jsonEncode(body ?? {})).timeout(const Duration(seconds: 30));
    return _decode(r);
  }

  Future<Map<String, dynamic>> postFile(String path, String field, List<int> bytes, String filename) async {
    final req = http.MultipartRequest('POST', Uri.parse('${Env.apiBaseUrl}$path'))..headers.addAll(_h)..headers.remove('Content-Type')
      ..files.add(http.MultipartFile.fromBytes(field, bytes, filename: filename));
    final r = await http.Response.fromStream(await req.send().timeout(const Duration(seconds: 40)));
    return _decode(r);
  }

  Map<String, dynamic> _decode(http.Response r) {
    Map<String, dynamic> j = {};
    try { j = jsonDecode(r.body) as Map<String, dynamic>; } catch (_) {}
    if (r.statusCode >= 300) throw ApiException(r.statusCode, (j['detail'] ?? 'That didn\'t go through. Try again, nothing was lost.').toString());
    return j;
  }
}

final apiProvider = Provider<Api>((ref) => Api());
