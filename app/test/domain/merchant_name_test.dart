import 'package:flutter_test/flutter_test.dart';
import 'package:tick/domain/merchant_name.dart';

void main() {
  test('bank names from real feeds read like a person wrote them', () {
    expect(cleanMerchant('JPMORGAN CHASE BANK, NA'), 'Chase');
    expect(cleanMerchant('Jpmorgan Chase Bank, Na'), 'Chase');
    expect(cleanMerchant('SoFi Bank TRANSFER PSathyasaran WEB ID: 9039430511'), 'SoFi transfer');
    expect(cleanMerchant('DISCOVER E-PAYMENT 7203'), 'Discover payment');
    expect(cleanMerchant('BANK OF AMERICA CREDIT CARD BILL PAYMENT'), 'Bank of America payment');
    expect(cleanMerchant('CAPITAL ONE MOBILE PMT'), 'Capital One payment');
    expect(cleanMerchant('APPLECARD GSBANK PAYMENT 5800'), 'Apple Card payment');
  });

  test('Zelle and friends: person names are title-cased, ids dropped', () {
    expect(cleanMerchant('Zelle payment to KAARTHIK KUMAR 31446078428'), 'Zelle to Kaarthik Kumar');
    expect(cleanMerchant('Zelle payment from ASWIN KAARTHIK SURESH KUMAR 31405259358'), 'Zelle from Aswin Kaarthik Suresh Kumar');
    expect(cleanMerchant('Zelle® Payment to Prithvi Chase'), 'Zelle to Prithvi Chase');
    expect(cleanMerchant('Zelle payment to Rent JPM99cr1tlu9'), 'Zelle to Rent');
    expect(cleanMerchant('VENMO CASHOUT'), 'Venmo Cashout');
  });

  test('shops: shouting becomes title case, processor prefixes and store numbers go', () {
    expect(cleanMerchant("TRADER JOE'S #123"), "Trader Joe's");
    expect(cleanMerchant('SQ *BLUE BOTTLE COFFEE'), 'Blue Bottle Coffee');
    expect(cleanMerchant('CVS PHARMACY'), 'CVS Pharmacy');
    expect(cleanMerchant('INSTITUTE OF NUC PAYROLL'), 'Institute Of Nuc Payroll');
    expect(cleanMerchant('Whole Foods'), 'Whole Foods');
    expect(cleanMerchant('Interest earned'), 'Interest earned');
  });

  test('idempotent, and never empty', () {
    for (final s in ['JPMORGAN CHASE BANK, NA', 'Zelle payment to KAARTHIK KUMAR 31446078428', "TRADER JOE'S #123", 'Blue Bottle', '']) {
      final once = cleanMerchant(s);
      expect(cleanMerchant(once), once);
    }
    expect(cleanMerchant('   '), '');
    expect(cleanMerchant('12345678901'), '12345678901');
  });
}
