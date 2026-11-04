import '../domain/natural_input.dart';

/// On-device fallback categorisation for quick add. Learned rules win; AI runs server-side for captures.
String categorizeLocal(String merchant, {Map<String, String> rules = const {}}) {
  final m = merchant.toLowerCase();
  for (final e in rules.entries) {
    if (m.contains(e.key)) return e.value;
  }
  const map = {
    'uber': 'cat-rideshare', 'lyft': 'cat-rideshare', 'starbucks': 'cat-coffee', 'coffee': 'cat-coffee', 'blue bottle': 'cat-coffee',
    'whole foods': 'cat-groceries', "trader joe": 'cat-groceries', 'safeway': 'cat-groceries', 'giant': 'cat-groceries', 'grocer': 'cat-groceries',
    'chipotle': 'cat-restaurants', 'sweetgreen': 'cat-restaurants', 'doordash': 'cat-restaurants', 'restaurant': 'cat-restaurants',
    'rent': 'cat-rent', 'comcast': 'cat-phone', 'verizon': 'cat-phone', 't-mobile': 'cat-phone', 'internet': 'cat-phone', 'phone': 'cat-phone',
    'pepco': 'cat-utilities', 'dominion': 'cat-utilities', 'water': 'cat-utilities', 'electric': 'cat-utilities',
    'netflix': 'cat-subscriptions', 'spotify': 'cat-subscriptions', 'hulu': 'cat-subscriptions',
    'delta': 'cat-travel', 'united': 'cat-travel', 'airbnb': 'cat-travel', 'flight': 'cat-travel',
    'cvs': 'cat-health', 'walgreens': 'cat-health', 'amazon': 'cat-shopping', 'target': 'cat-shopping',
  };
  for (final e in map.entries) {
    if (m.contains(e.key)) return e.value;
  }
  if (looksBusiness(merchant)) return 'cat-software';
  return 'cat-other';
}
