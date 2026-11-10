import 'models.dart';
import 'safe_to_spend.dart';

/// What Home shows: Cash (checking that counts), Savings (never mixed in), and cards owed (never subtracted here).
class HomeBalances {
  const HomeBalances({required this.cash, required this.savings, required this.cardsOwedCents, this.nextCard, this.excludedCount = 0});
  final List<(Account, int)> cash;
  final List<(Account, int)> savings;
  final int cardsOwedCents;
  /// The card whose payment is due soonest, if any is due.
  final Account? nextCard;
  /// Checking accounts switched off in Profile, so Home can say one is left out.
  final int excludedCount;
  int get cashCents => cash.fold(0, (s, x) => s + x.$2);
  int get savingsCents => savings.fold(0, (s, x) => s + x.$2);
}

HomeBalances homeBalances(List<Account> accounts) {
  final cards = accounts.where((a) => a.isCard).toList();
  final due = cards.where((a) => a.dueDate != null && a.owedCents > 0).toList()..sort((a, b) => a.dueDate!.compareTo(b.dueDate!));
  return HomeBalances(
    cash: [for (final a in accounts.where(countsAsCash)) (a, cashOf(a))],
    savings: [for (final a in accounts.where((a) => a.type == 'savings')) (a, a.balanceCents ?? a.availableCents ?? 0)],
    cardsOwedCents: cards.fold(0, (s, a) => s + a.owedCents),
    nextCard: due.isEmpty ? null : due.first,
    excludedCount: accounts.where((a) => (a.type == 'checking' || a.type == 'cash') && !a.includeInSafe).length,
  );
}
