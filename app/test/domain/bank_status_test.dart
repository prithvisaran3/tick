import 'package:flutter_test/flutter_test.dart';
import 'package:tick/domain/bank_status.dart';
import 'package:tick/domain/models.dart';

void main() {
  final now = DateTime(2026, 11, 6, 12);
  Connection c(String state, {DateTime? synced, DateTime? started, DateTime? created, String? err}) =>
      Connection(id: 'x', institution: 'Discover', status: 'active', syncState: state, lastSyncedAt: synced, syncStartedAt: started, createdAt: created, lastError: err);

  test('up to date says when it last synced', () {
    expect(bankStatus(c('ok', synced: now.subtract(const Duration(minutes: 5))), now).title, 'Up to date · synced 5 min ago');
    expect(bankStatus(c('ok', synced: now.subtract(const Duration(seconds: 10))), now).title, 'Up to date · synced just now');
    expect(bankStatus(c('ok', synced: now.subtract(const Duration(hours: 3))), now).title, 'Up to date · synced 3 hours ago');
    expect(bankStatus(c('ok', synced: now.subtract(const Duration(days: 1))), now).title, 'Up to date · synced 1 day ago');
  });

  test('every state has a plain-words status and the right action', () {
    final login = bankStatus(c('login_required'), now);
    expect((login.title, login.action, login.actionLabel), ('Reconnect needed', BankAction.reconnect, 'Reconnect'));
    expect(login.detail, 'One tap to sign in again.');
    expect('${login.detail} ${bankStatus(c('partial'), now).detail}', isNot(contains('link')));      // never talk about link limits here
    final partial = bankStatus(c('partial'), now);
    expect((partial.title, partial.action, partial.actionLabel), ('Some accounts aren\'t shared', BankAction.fixAccounts, 'Fix'));
    expect(bankStatus(c('bank_issue'), now).title, 'Bank is having issues');
    expect(bankStatus(c('bank_issue'), now).detail, contains('retry'));
    final err = bankStatus(c('error', err: 'KeyError'), now);
    expect(err.title, 'Couldn\'t finish syncing');
    expect(err.detail, contains('couldn\'t save'));
    expect(err.action, BankAction.retry);
  });

  test('syncing shows progress, and never spins forever', () {
    final fresh = bankStatus(c('syncing', started: now.subtract(const Duration(minutes: 2))), now, txnCount: 1204);
    expect((fresh.title, fresh.busy, fresh.detail), ('Syncing your history…', true, '1204 transactions so far.'));
    expect(bankStatus(c('pending', created: now.subtract(const Duration(minutes: 1))), now).detail, contains('few minutes'));
    final stuck = bankStatus(c('syncing', started: now.subtract(const Duration(minutes: 11))), now);
    expect((stuck.title, stuck.busy, stuck.action), ('Taking longer than usual', false, BankAction.retry));
    expect(stuck.detail, 'The bank hasn\'t sent anything yet.');
    expect(bankStatus(c('syncing', started: now.subtract(const Duration(minutes: 30)), err: 'PRODUCT_NOT_READY'), now).detail, contains('still preparing'));
  });

  test('connections parse the sync columns, and old rows without them still read sensibly', () {
    expect(Connection.fromJson({'id': 'a', 'institution': 'Chase', 'status': 'active', 'last_synced_at': '2026-11-05T01:35:59Z'}).syncState, 'ok');
    expect(Connection.fromJson({'id': 'a', 'institution': 'Discover', 'status': 'error'}).syncState, 'error');
    expect(Connection.fromJson({'id': 'a', 'institution': 'X', 'status': 'login_required'}).needsRelink, isTrue);
    final j = Connection.fromJson({'id': 'a', 'institution': 'SoFi', 'status': 'active', 'sync_state': 'syncing', 'historical_complete': false, 'last_added': 4});
    expect((j.syncState, j.historicalComplete, j.lastAdded), ('syncing', false, 4));
    final back = Connection.fromCache(j.toJson());
    expect((back.syncState, back.institution), ('syncing', 'SoFi'));
  });
}
