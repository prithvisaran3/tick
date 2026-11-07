import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/link_info.dart';
import 'api.dart';
import 'errors.dart';
import 'web_auth.dart';

/// Opens Plaid's hosted page and returns its callback URL. A provider so tests never open a browser.
final webAuthProvider = Provider<Future<String> Function(String url)>((ref) => (u) => webAuthenticate(u));

enum LinkResult { linked, pending, cancelled, limited, failed }

class LinkOutcome {
  const LinkOutcome(this.result, {this.message, this.connections = 0});
  final LinkResult result;
  final String? message;   // a short, specific reason for `failed` / `pending`
  final int connections;
  bool get ok => result == LinkResult.linked;
}

const stillConnecting = 'Your bank may still be connecting. Pull to refresh in a minute before you link again.';

/// A person-readable reason for a failed link step. The owner lock (403) and the cap (409) are not failures: both read as the one calm line.
String linkErrorMessage(Object e, {bool bankDone = false, bool newLink = true}) {
  if (e is ApiException) {
    if (newLink && !bankDone && (e.status == 403 || e.status == 409)) return linkLimitedMessage;
    if (e.status == 429 || e.status == 401 || e.status == 403 || e.status == 404) return e.message;
    if (e.offline) return bankDone && newLink ? stillConnecting : e.message;
    if (bankDone && newLink) return stillConnecting;                       // the bank side finished; the webhook usually completes it
    return e.message;                                                      // 502 carries "Bank link unavailable (CODE)"
  }
  if (e is PlatformException) return 'The bank window closed before linking finished. Try again.';
  if (bankDone && newLink) return stillConnecting;
  return describeError(e, action: 'link that bank');
}

/// One Plaid Hosted Link run, new bank or update mode. Never throws; the real cause is recorded (type only) and a reason is returned.
/// Re-running after a kill is safe: /plaid/complete is idempotent (one session, one Item, one slot).
Future<LinkOutcome> runBankLink(Api api, Future<String> Function(String) authenticate, {String? connectionId, bool accounts = false, Future<void> Function(String token)? onStarted, Future<void> Function()? onFinished}) async {
  var bankDone = false;
  try {
    final j = await api.post('/plaid/link-token', {'connection_id': ?connectionId, if (accounts) 'accounts': true});
    final url = j['hosted_link_url'] as String?;
    if (url == null) throw ApiException(502, 'The bank link didn\'t open. Try again in a moment.');
    if (connectionId == null && onStarted != null) await onStarted(j['link_token'] as String);
    await authenticate(url);
    bankDone = true;
    if (connectionId == null) {
      final r = await api.post('/plaid/complete', {'link_token': j['link_token']});
      if (onFinished != null) await onFinished();
      final n = (r['connections'] as List?)?.length ?? 0;
      return n == 0 ? const LinkOutcome(LinkResult.pending, message: 'Still finishing up. Your bank shows here in a minute.') : LinkOutcome(LinkResult.linked, connections: n);
    }
    await api.post('/plaid/sync/$connectionId');
    return const LinkOutcome(LinkResult.linked, connections: 1);
  } on PlatformException catch (e, st) {
    if (e.code == 'CANCELED') { if (onFinished != null) await onFinished(); return const LinkOutcome(LinkResult.cancelled); }      // closing the sheet is not an error
    AppErrors.record(e, st, where: 'bank-link');
    return LinkOutcome(LinkResult.failed, message: linkErrorMessage(e, bankDone: bankDone, newLink: connectionId == null));
  } catch (e, st) {
    if (connectionId == null && !bankDone && e is ApiException && (e.status == 403 || e.status == 409)) {
      return const LinkOutcome(LinkResult.limited, message: linkLimitedMessage);       // the owner lock or the cap: expected, not a failure
    }
    AppErrors.record(e, st, where: 'bank-link');
    final pending = bankDone && connectionId == null;
    return LinkOutcome(pending ? LinkResult.pending : LinkResult.failed, message: linkErrorMessage(e, bankDone: bankDone, newLink: connectionId == null));
  }
}

/// After a kill or a dropped connection mid-link: finish the exchange of the link the person already completed at the bank.
/// Quiet by design (no error UI): if Plaid has nothing to exchange, the token is dropped; if the server is unreachable it stays for next time.
Future<bool> resumePendingLink(Api api, String token, Future<void> Function() clear) async {
  try {
    final r = await api.post('/plaid/complete', {'link_token': token});
    await clear();
    return ((r['connections'] as List?)?.isNotEmpty) ?? false;
  } on ApiException catch (e) {
    if (!e.offline && e.status < 500 && e.status != 429) await clear();                // 404/403/422: this token can never complete
    return false;
  } catch (_) {
    return false;
  }
}
