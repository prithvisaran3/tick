/// Display names for merchants. Bank descriptions are shouty and padded with ids: "JPMORGAN CHASE BANK, NA" should read "Chase",
/// "Zelle payment to KAARTHIK KUMAR 31446078428" should read "Zelle to Kaarthik Kumar". Pure and idempotent (cleaning a clean name is a no-op).
const _banks = <(String, String)>[
  (r'\b(jp ?morgan chase|jpmorgan|jpm|chase)\b', 'Chase'),
  (r'\bsofi\b', 'SoFi'),
  (r'\b(bank of america|bofa|bk of amer\w*)\b', 'Bank of America'),
  (r'\bcapital ?one\b', 'Capital One'),
  (r'\bdiscover\b', 'Discover'),
  (r'\b(apple ?card|goldman sachs|gs bank)\b', 'Apple Card'),
];
const _keepUpper = {'CVS', 'AWS', 'ATM', 'USA', 'LLC', 'IBM', 'HBO', 'BP', 'TJ', 'DMV', 'IRS', 'UPS', 'USPS', 'AT&T', 'T-Mobile', 'H&M', 'KFC', 'TD', 'PNC', 'GW', 'AI', 'TV', 'NYC', 'DC'};

String _title(String s) {
  // Mixed-case text was already written by a person or a processor that cased it ("Interest earned", "Whole Foods"): leave it.
  if (s != s.toUpperCase() && s != s.toLowerCase()) return s;
  final out = <String>[];
  for (final w in s.split(RegExp(r'\s+'))) {
    if (w.isEmpty) continue;
    if (_keepUpper.contains(w.toUpperCase()) && w.toUpperCase() == w) { out.add(w); continue; }
    final isShouty = w == w.toUpperCase() && w != w.toLowerCase();
    final isLower = w == w.toLowerCase() && w != w.toUpperCase();
    if (isShouty || isLower) {
      out.add(w.split('-').map((p) => p.isEmpty ? p : p[0].toUpperCase() + p.substring(1).toLowerCase()).join('-').replaceAllMapped(RegExp(r"'([a-z])"), (m) => "'${m[1]}"));
    } else {
      out.add(w);
    }
  }
  return out.join(' ');
}

/// Strips processor noise: prefixes, "WEB ID: 123", reference numbers, long ids glued to the end.
String _strip(String s) {
  var t = s.replaceAll('®', '').replaceAll(RegExp(r'\s+'), ' ').trim();
  t = t.replaceAll(RegExp(r'\b(web id|ppd id|ccd id|trace|ref|conf(irmation)?)\s*#?:?\s*\w+', caseSensitive: false), '');
  t = t.replaceAll(RegExp(r'(?<=\s)(?=[A-Za-z0-9]*\d)[A-Za-z0-9]{8,}$'), '');   // JPM99cr1tlu9, 0PE0ABS1MUQD (a long token with a digit)
  t = t.replaceAll(RegExp(r'(?<=\s)\d{5,}$'), '');                        // 31446078428
  t = t.replaceAll(RegExp(r'\s[#*]\s?\d{3,}$'), '');
  t = t.replaceAll(RegExp(r'^(sq|tst|sp|pp|dd)\s*\*\s*', caseSensitive: false), '');
  return t.replaceAll(RegExp(r'[\s,;:-]+$'), '').trim();
}

String cleanMerchant(String raw) {
  var s = _strip(raw);
  if (s.isEmpty) return raw.trim();
  final lower = s.toLowerCase();
  // Zelle / Venmo / Cash App to or from a person.
  final p2p = RegExp(r'^(zelle|venmo|cash ?app|paypal)\s*(?:payment|transfer)?\s*(to|from)\s+(.+)$', caseSensitive: false).firstMatch(s);
  if (p2p != null) {
    final who = _title(_strip(p2p.group(3)!));
    final app = p2p.group(1)!.toLowerCase().startsWith('cash') ? 'Cash App' : _title(p2p.group(1)!);
    return '$app ${p2p.group(2)!.toLowerCase()} $who';   // "Zelle to Kaarthik Kumar" (the word "payment" adds nothing)
  }
  // A bank by itself, or a transfer description naming a bank.
  for (final (pattern, name) in _banks) {
    final m = RegExp(pattern, caseSensitive: false).firstMatch(lower);
    if (m == null) continue;
    final rest = lower.replaceFirst(RegExp(pattern, caseSensitive: false), '').replaceAll(RegExp(r'\b(bank|na|n\.a\.|transfer|e-?payment|payment|pmt|web|autopay|credit card|bill)\b'), '').replaceAll(RegExp(r'[^a-z]+'), '');
    final isTransfer = lower.contains('transfer') || lower.contains('xfer');
    final isPayment = RegExp(r'payment|pmt|pymt|bill').hasMatch(lower);
    if (rest.length <= 14) return isPayment ? '$name payment' : isTransfer ? '$name transfer' : name;
  }
  return _title(s);
}
