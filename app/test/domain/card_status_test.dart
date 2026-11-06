import 'package:flutter_test/flutter_test.dart';
import 'package:tick/domain/models.dart';
import 'package:tick/features/cards.dart';

void main() {
  final now = DateTime(2026, 11, 6);
  // The exact shapes Plaid returned for the live cards.
  final boa = Account(id: 'b', name: 'Visa Signature', institution: 'Bank of America', mask: '5498', type: 'credit', balanceCents: -32179, creditLimitCents: 220000,
      statementBalanceCents: 6485, minimumPaymentCents: 0, dueDate: DateTime(2026, 11, 22), lastPaymentCents: 6485, lastPaymentDate: DateTime(2026, 10, 28));
  final disc = Account(id: 'd', name: 'Discover it', institution: 'Discover', mask: '1545', type: 'credit', balanceCents: -31714,
      statementBalanceCents: 37023, minimumPaymentCents: 0, dueDate: DateTime(2026, 11, 2), lastStatementDate: DateTime(2026, 10, 5), lastPaymentCents: 55926, lastPaymentDate: DateTime(2026, 10, 18));

  test('BofA: the statement was paid on Oct 28, so it is not "due Nov 22", and a zero minimum is "not shared"', () {
    expect(boa.statementPaid, isTrue);
    expect((boa.statementDueCents, boa.newSinceStatementCents), (0, 32179));
    expect(boa.knownMinimumCents, isNull);
    expect(dueLine(boa, now), r'Statement paid · $321 new');
    expect(statementExplainer(boa), contains('due with your next statement'));
  });

  test('Discover: "Statement paid" now explains the \$317.14 owed instead of contradicting it', () {
    expect(disc.statementPaid, isTrue);
    expect(disc.newSinceStatementCents, 31714);
    expect(statementExplainer(disc), contains(r'$317.14 is new spending since it closed'));
    expect(dueLine(disc, now), r'Statement paid · $317 new');
  });

  test('an unpaid statement shows what is due and by when; a partial payment lowers it', () {
    final unpaid = Account(id: 'u', name: 'C', type: 'credit', balanceCents: -50000, statementBalanceCents: 40000, minimumPaymentCents: 3500, dueDate: DateTime(2026, 11, 12));
    expect(unpaid.statementPaid, isFalse);
    expect(dueLine(unpaid, now), r'$400 due Thursday');
    expect(unpaid.knownMinimumCents, 3500);
    expect(statementExplainer(unpaid), isNull);
    final partial = Account(id: 'p', name: 'C', type: 'credit', balanceCents: -50000, statementBalanceCents: 40000, minimumPaymentCents: 3500, dueDate: DateTime(2026, 11, 12),
        lastStatementDate: DateTime(2026, 10, 20), lastPaymentCents: 30000, lastPaymentDate: DateTime(2026, 11, 2));
    expect(partial.statementDueCents, 10000);
    expect(partial.statementPaid, isFalse);
  });

  test('partial data from the bank is explained in plain words, never contradicted', () {
    final noStatement = Account(id: 'n', name: 'Apple Card', type: 'credit', balanceCents: -31840);
    expect(dueLine(noStatement, now), 'The bank shares the balance, not the statement');
    expect(statementExplainer(noStatement), contains('not the statement'));
    final noMin = Account(id: 'm', name: 'C', type: 'credit', balanceCents: -50000, statementBalanceCents: 40000, minimumPaymentCents: 0, dueDate: DateTime(2026, 11, 12));
    expect(statementExplainer(noMin), contains('didn\'t share a minimum'));
    expect(dueLine(Account(id: 'z', name: 'C', type: 'credit', balanceCents: 0), now), 'Paid off');
    expect(dueLine(Account(id: 'q', name: 'C', type: 'credit', balanceCents: -5000, statementBalanceCents: 5000), now), r'$50 due, date not shared');
  });

  test('every screen labels an account through Account.shortLabel / label, so a mask can never differ between screens', () {
    expect(boa.shortLabel, 'Bank of America ••5498');
    expect(boa.label, boa.shortLabel);
  });
}
