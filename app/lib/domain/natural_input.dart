import 'payday.dart';

class ParsedEntry {
  const ParsedEntry({required this.amountCents, required this.merchant, this.person, this.date, this.recurringDayOfMonth, this.categoryHint});
  final int amountCents; // negative out, positive in
  final String merchant;
  final String? person;
  final DateTime? date;
  final int? recurringDayOfMonth;
  final String? categoryHint;
  bool get isIncome => amountCents > 0;
  bool get isRecurring => recurringDayOfMonth != null;
}

const _catHints = {
  'uber': 'Rideshare', 'lyft': 'Rideshare', 'coffee': 'Coffee', 'starbucks': 'Coffee', 'rent': 'Rent',
  'grocer': 'Groceries', 'groceries': 'Groceries', 'whole foods': 'Groceries', 'trader joe': 'Groceries',
  'netflix': 'Subscriptions', 'spotify': 'Subscriptions', 'claude': 'Software', 'cursor': 'Software', 'github': 'Software',
  'flight': 'Travel', 'delta': 'Travel', 'united': 'Travel',
};

/// "uber 18", "got 40 from Alex", "rent 1850 on the 1st", "coffee 4.50 yesterday", "$12 chipotle".
ParsedEntry? parseNatural(String raw, DateTime now) {
  var s = raw.trim();
  if (s.isEmpty) return null;
  final lower = s.toLowerCase();

  final am = RegExp(r'\$?\s*(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d{1,2}))?').firstMatch(s);
  if (am == null) return null;
  final cents = int.parse(am.group(1)!.replaceAll(',', '')) * 100 + int.parse((am.group(2) ?? '0').padRight(2, '0'));
  if (cents == 0) return null;

  // Income: "got 40 from Alex", "received", "refund", "paid me"
  final inc = RegExp(r'^(?:got|received|recieved|earned)\b|\brefund\b|\bpaid me\b').hasMatch(lower);
  String? person;
  final fromM = RegExp(r'\bfrom\s+([a-zA-Z][\w\s\.]*?)(?:\s+(?:on|for|yesterday|today)\b|$)').firstMatch(s);
  if (fromM != null) person = _title(fromM.group(1)!.trim());

  // Date words
  DateTime? date;
  int? recurDay;
  if (RegExp(r'\byesterday\b').hasMatch(lower)) date = dayOnly(now).subtract(const Duration(days: 1));
  final dm = RegExp(r'\bon the (\d{1,2})(?:st|nd|rd|th)\b').firstMatch(lower);
  if (dm != null) {
    recurDay = int.parse(dm.group(1)!).clamp(1, 28);
  }

  // Merchant: strip amount, filler and date words.
  var m = s.replaceFirst(am.group(0)!, ' ');
  m = m.replaceAll(RegExp(r'\b(?:got|received|recieved|earned|from|on the \d{1,2}(?:st|nd|rd|th)|yesterday|today|for|at|paid me)\b', caseSensitive: false), ' ');
  if (person != null) m = m.replaceAll(RegExp(RegExp.escape(person), caseSensitive: false), ' ');
  m = m.replaceAll(RegExp(r'[\$,]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  final merchant = m.isEmpty ? (person ?? (inc ? 'Income' : 'Expense')) : _title(m);

  String? hint;
  for (final e in _catHints.entries) {
    if (lower.contains(e.key)) { hint = e.value; break; }
  }
  return ParsedEntry(
    amountCents: inc ? cents : -cents,
    merchant: inc && person != null && m.isEmpty ? person : merchant,
    person: person, date: date, recurringDayOfMonth: recurDay, categoryHint: inc ? 'Income' : hint,
  );
}

String _title(String s) => s.split(' ').map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1)).join(' ');

/// Next date that falls on [day] of the month, on or after [from].
DateTime nextDayOfMonth(int day, DateTime from) {
  final f = dayOnly(from);
  var d = DateTime(f.year, f.month, day);
  if (d.isBefore(f)) d = DateTime(f.year, f.month + 1, day);
  return d;
}

/// Merchants that should auto-suggest the Business tag (dev/SaaS).
bool looksBusiness(String merchant) {
  final m = merchant.toLowerCase();
  const keys = ['claude', 'anthropic', 'openai', 'cursor', 'github', 'vercel', 'railway', 'supabase', 'aws', 'amazon web', 'google cloud', 'cloudflare',
    'namecheap', 'godaddy', 'porkbun', 'apple developer', 'figma', 'notion', 'linear', 'sentry', 'twilio', 'stripe', 'digitalocean', 'heroku', 'netlify', 'canva', 'adobe', 'gemini', 'perplexity', 'replit'];
  return keys.any(m.contains);
}
