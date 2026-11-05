/// "Hide amounts" (Settings) and screen recording: every amount on screen and in notifications reads as ••••.
/// Set by the app shell; [raw] formats are for files the person exports, never for the screen.
class MoneyMask {
  static bool hidden = false;
}

/// All money is integer cents. Negative = money out.
String formatCents(int cents, {bool sign = false, bool whole = false, bool symbol = true, bool raw = false}) {
  if (MoneyMask.hidden && !raw) return '${symbol ? '\$' : ''}••••';
  final neg = cents < 0;
  final abs = cents.abs();
  final dollars = abs ~/ 100;
  final rem = abs % 100;
  final d = _group(dollars);
  final body = whole || (rem == 0 && false) ? d : '$d.${rem.toString().padLeft(2, '0')}';
  final s = symbol ? '\$' : '';
  if (neg) return '−$s$body';
  return sign && cents > 0 ? '+$s$body' : '$s$body';
}

String _group(int n) {
  final s = n.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

/// Whole dollars, rounded toward zero: `$214`.
String formatDollars(int cents) => formatCents(cents, whole: true);

/// Parse "18", "18.4", "$1,850.00" into cents; null if invalid.
int? parseCents(String input) {
  final t = input.replaceAll(RegExp(r'[\$,\s]'), '');
  final m = RegExp(r'^(\d+)(?:\.(\d{1,2}))?$').firstMatch(t);
  if (m == null) return null;
  final frac = (m.group(2) ?? '').padRight(2, '0');
  return int.parse(m.group(1)!) * 100 + int.parse(frac.isEmpty ? '00' : frac);
}
