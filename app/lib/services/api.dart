import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../data/env.dart';

class ApiException implements Exception {
  ApiException(this.status, this.message, {this.offline = false});
  final int status;
  final String message;
  final bool offline;
  @override
  String toString() => message;
}

/// What a person reads for a failed call. Every status gets its own plain sentence; the server's own `detail` wins when it is a short
/// string written for people (our 4xx and 502 details are). Nothing here is a bare "that didn't go through" with no cause.
String messageForStatus(int status, Object? detail) {
  if (detail is String && detail.trim().isNotEmpty && detail.length <= 220 && status != 401 && status != 500) return detail.trim();
  if (status == 401) return 'You\'re signed out. Sign in again to continue.';
  if (status == 403) return 'You don\'t have access to that.';
  if (status == 404) return 'That wasn\'t found. It may have been removed.';
  if (status == 409) return 'That conflicts with something already saved. Refresh and try again.';
  if (status == 422 || status == 400) return 'Something in that isn\'t valid. Check it and try again.';
  if (status == 429) return 'Too many tries. Wait a minute and try again.';
  if (status >= 500) return 'Tick is having trouble right now. Try again in a minute.';
  return 'Tick couldn\'t accept that. Check it and try again.';
}

/// A short, specific reason for any thrown error, for the "what happened" line under a failed action.
String describeError(Object e, {String action = 'do that'}) {
  if (e is ApiException) return e.message;
  if (e is TimeoutException) return 'Tick is taking too long. Try again in a moment.';
  if (e is SocketException || e is http.ClientException) return 'Can\'t reach Tick right now. Check your connection.';
  return 'Couldn\'t $action. Try again.';
}

/// Thin client for the Tick FastAPI service. Sends the Supabase JWT (refreshed when close to expiry), bounded timeouts,
/// retries idempotent GETs with backoff, retries once after a 401 with a refreshed token, and returns calm errors.
/// It never touches Plaid tokens and never logs request or response bodies.
class Api {
  Api({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;

  void close() => _client.close();

  Future<String?> _token({bool forceRefresh = false}) async {
    if (!Env.hasSupabase) return null;
    try {
      final auth = Supabase.instance.client.auth;
      var s = auth.currentSession;
      if (s == null) return null;
      final exp = s.expiresAt;
      final soon = exp != null && DateTime.fromMillisecondsSinceEpoch(exp * 1000).isBefore(DateTime.now().add(const Duration(seconds: 60)));
      if (forceRefresh || soon) {
        s = (await auth.refreshSession()).session ?? s;
      }
      return s.accessToken;
    } catch (_) {
      return Supabase.instance.client.auth.currentSession?.accessToken;
    }
  }

  Future<Map<String, dynamic>> get(String path, {Duration timeout = const Duration(seconds: 15)}) =>
      _go('GET', path, null, timeout, retries: 2);

  Future<Map<String, dynamic>> post(String path, [Map<String, dynamic>? body, Duration timeout = const Duration(seconds: 30)]) =>
      _go('POST', path, body ?? {}, timeout, retries: 0);

  Future<Map<String, dynamic>> _go(String method, String path, Map<String, dynamic>? body, Duration timeout, {required int retries}) async {
    var refreshed = false;
    for (var attempt = 0;; attempt++) {
      try {
        final token = await _token(forceRefresh: refreshed);
        final headers = {'Content-Type': 'application/json', if (token != null) 'Authorization': 'Bearer $token'};
        final uri = Uri.parse('${Env.apiBaseUrl}$path');
        final res = method == 'GET'
            ? await _client.get(uri, headers: headers).timeout(timeout)
            : await _client.post(uri, headers: headers, body: jsonEncode(body ?? {})).timeout(timeout);
        if (res.statusCode == 401 && !refreshed) { refreshed = true; continue; }          // token expired mid-flight: refresh once
        if (res.statusCode >= 500 && attempt < retries) { await _backoff(attempt); continue; }
        return _decode(res);
      } on SocketException {
        if (attempt < retries) { await _backoff(attempt); continue; }
        throw ApiException(0, 'Can\'t reach Tick right now.', offline: true);
      } on TimeoutException {
        if (attempt < retries) { await _backoff(attempt); continue; }
        throw ApiException(0, 'Tick is taking too long. Try again in a moment.', offline: true);
      } on http.ClientException {
        if (attempt < retries) { await _backoff(attempt); continue; }
        throw ApiException(0, 'Can\'t reach Tick right now.', offline: true);
      }
    }
  }

  Future<void> _backoff(int attempt) => Future<void>.delayed(Duration(milliseconds: 400 * (1 << attempt) + 100));

  Future<Map<String, dynamic>> postFile(String path, String field, List<int> bytes, String filename, {Map<String, String> fields = const {}}) async {
    try {
      final token = await _token();
      final req = http.MultipartRequest('POST', Uri.parse('${Env.apiBaseUrl}$path'))
        ..fields.addAll(fields)
        ..files.add(http.MultipartFile.fromBytes(field, bytes, filename: filename));
      if (token != null) req.headers['Authorization'] = 'Bearer $token';
      final res = await http.Response.fromStream(await _client.send(req).timeout(const Duration(seconds: 60)));
      return _decode(res);
    } on SocketException {
      throw ApiException(0, 'Can\'t reach Tick right now.', offline: true);
    } on TimeoutException {
      throw ApiException(0, 'Tick is taking too long. Try again in a moment.', offline: true);
    } on http.ClientException {
      throw ApiException(0, 'Can\'t reach Tick right now.', offline: true);
    }
  }

  Map<String, dynamic> _decode(http.Response r) {
    Map<String, dynamic> j = {};
    try {
      // JSON is UTF-8 by definition. `r.body` would decode as Latin-1 when the server sends no charset, turning "••1545" into mojibake.
      final d = jsonDecode(utf8.decode(r.bodyBytes, allowMalformed: true));
      if (d is Map<String, dynamic>) j = d;
    } catch (_) {/* non-JSON body */}
    if (r.statusCode >= 300) {
      throw ApiException(r.statusCode, messageForStatus(r.statusCode, j['detail']));          // validation lists become a plain sentence
    }
    return j;
  }
}

final apiProvider = Provider<Api>((ref) {
  final a = Api();
  ref.onDispose(a.close);
  return a;
});
