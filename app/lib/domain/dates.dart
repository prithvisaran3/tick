/// Calendar-day arithmetic. `date.add(Duration(days: n))` adds n*24 hours, which lands an hour off (23:00 the day before) across a DST change
/// (the US fall-back is the first Sunday of November: right in the middle of paydays). Building a new DateTime from y/m/d+n keeps wall-clock time.
DateTime addDays(DateTime d, int n) => DateTime(d.year, d.month, d.day + n, d.hour, d.minute, d.second, d.millisecond);

/// Whole calendar days from [a] to [b] (b - a), immune to DST (`b.difference(a).inDays` is off by one across a spring-forward).
int daysBetween(DateTime a, DateTime b) => DateTime.utc(b.year, b.month, b.day).difference(DateTime.utc(a.year, a.month, a.day)).inDays;
