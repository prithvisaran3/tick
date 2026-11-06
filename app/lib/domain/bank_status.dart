import 'models.dart';

enum BankTone { good, working, warn, bad }
enum BankAction { none, retry, reconnect, fixAccounts }

/// What Banks says about one connection. Pure, so every state and the "never a forever-spinner" rule are unit-tested.
class BankStatus {
  const BankStatus(this.title, {this.detail, this.tone = BankTone.good, this.action = BankAction.none, this.actionLabel, this.busy = false});
  final String title;
  final String? detail;
  final BankTone tone;
  final BankAction action;
  final String? actionLabel;
  final bool busy; // show the Tick loader
}

/// After this long without progress, "syncing" turns into an honest "taking longer than usual".
const syncPatience = Duration(minutes: 10);

String ago(DateTime then, DateTime now) {
  final d = now.difference(then);
  if (d.inSeconds < 45) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes < 1 ? 1 : d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} ${d.inHours == 1 ? 'hour' : 'hours'} ago';
  return '${d.inDays} ${d.inDays == 1 ? 'day' : 'days'} ago';
}

String reasonFor(String? code) => switch (code) {
      'PRODUCT_NOT_READY' => 'The bank is still preparing your history.',
      'INSTITUTION_DOWN' || 'INSTITUTION_NOT_RESPONDING' || 'INTERNAL_SERVER_ERROR' => 'The bank isn\'t responding.',
      'SYNC_FAILED' || 'KeyError' || 'HTTPStatusError' => 'Tick couldn\'t save the latest transactions.',
      null => 'The bank hasn\'t sent anything yet.',
      _ => 'The bank reported a problem.',
    };

BankStatus bankStatus(Connection c, DateTime now, {int? txnCount}) {
  switch (c.syncState) {
    case 'login_required':
      return const BankStatus('Reconnect needed', detail: 'One tap. It doesn\'t use one of your links.', tone: BankTone.bad, action: BankAction.reconnect, actionLabel: 'Reconnect');
    case 'partial':
      return const BankStatus('Some accounts aren\'t shared', detail: 'Choose which accounts Tick can see. No new link.', tone: BankTone.warn, action: BankAction.fixAccounts, actionLabel: 'Fix');
    case 'bank_issue':
      return const BankStatus('Bank is having issues', detail: 'We\'ll retry on our own.', tone: BankTone.warn, action: BankAction.retry, actionLabel: 'Try now');
    case 'error':
      return BankStatus('Couldn\'t finish syncing', detail: '${reasonFor(c.lastError)} We\'ll retry on our own.', tone: BankTone.warn, action: BankAction.retry, actionLabel: 'Try now');
    case 'pending':
    case 'syncing':
      final since = c.syncStartedAt ?? c.createdAt;
      final stuck = since != null && now.difference(since) > syncPatience;
      if (stuck) {
        return BankStatus('Taking longer than usual', detail: reasonFor(c.lastError), tone: BankTone.warn, action: BankAction.retry, actionLabel: 'Try again');
      }
      final n = txnCount ?? 0;
      return BankStatus('Syncing your history…', detail: n > 0 ? '$n transactions so far.' : 'This can take a few minutes.', tone: BankTone.working, busy: true);
    default:
      final at = c.lastSyncedAt;
      return BankStatus(at == null ? 'Up to date' : 'Up to date · synced ${ago(at, now)}', tone: BankTone.good);
  }
}

/// True when a bank has been quiet so long that Today should say so (used by the nudge).
bool needsAttention(Connection c) => const {'login_required', 'partial', 'error', 'bank_issue'}.contains(c.syncState);
