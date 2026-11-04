/// Month grid helpers for the custom date picker. Sunday-first.
List<DateTime?> monthCells(DateTime month) {
  final first = DateTime(month.year, month.month, 1);
  final lead = first.weekday % 7;
  final days = DateTime(month.year, month.month + 1, 0).day;
  return [for (var i = 0; i < lead; i++) null, for (var d = 1; d <= days; d++) DateTime(month.year, month.month, d)];
}

DateTime addMonths(DateTime m, int n) => DateTime(m.year, m.month + n, 1);
