import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:tick/domain/models.dart';
import 'package:tick/domain/payday.dart';

/// The same vectors as supabase/tests/pay_period.sql: the Dart mirror and the SQL can't drift.
void main() {
  PaydayRule rule(Map<String, dynamic> r) => PaydayRule(frequency: PayFrequency.values.byName(r['frequency'] as String), anchor: DateTime.parse(r['next_date'] as String), amountCents: 0, days: (r['days'] as List?)?.cast<int>());
  for (final v in jsonDecode(File('../api/tests/data/pay_period.json').readAsStringSync()) as List) {
    test(v['name'] as String, () {
      final (prev, next) = payDates(rule(v['rule'] as Map<String, dynamic>), DateTime.parse(v['on'] as String));
      expect((prev, next), (DateTime.parse(v['prev'] as String), DateTime.parse(v['next'] as String)));
    });
  }

  test('the preview for anchor Nov 13: current Oct 30 to Nov 12, then Nov 13, Nov 27, Dec 11', () {
    final p = payPreview(PaydayRule(frequency: PayFrequency.biweekly, anchor: DateTime(2026, 11, 13), amountCents: 0), DateTime(2026, 11, 6));
    expect((p.period.start, p.period.end), (DateTime(2026, 10, 30), DateTime(2026, 11, 12)));
    expect(p.next, [DateTime(2026, 11, 13), DateTime(2026, 11, 27), DateTime(2026, 12, 11)]);
  });

  test('on payday, the preview still counts today as the next one', () {
    final r = PaydayRule(frequency: PayFrequency.biweekly, anchor: DateTime(2026, 11, 13), amountCents: 0);
    expect(nextPayday(r, DateTime(2026, 11, 13)), DateTime(2026, 11, 13));
    expect(payPeriod(r, DateTime(2026, 11, 13)).nextPayday, DateTime(2026, 11, 27));
  });
}
