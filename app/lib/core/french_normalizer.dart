// Deterministic normalization of spoken French (voice chain, step 3):
// numbers (including Belgian/Swiss « septante », « huitante », « nonante »),
// clock times, durations, percentages and days.
//
// Output conventions:
// - clock times: `H:MM`, the hour kept as said (« une heure et quart » →
//   `1:15`, never converted to 13:15);
// - durations: `N min`;
// - percentages: `N %`.

const Map<String, int> _numberWords = {
  'zéro': 0,
  'zero': 0,
  'un': 1,
  'une': 1,
  'deux': 2,
  'trois': 3,
  'quatre': 4,
  'cinq': 5,
  'six': 6,
  'sept': 7,
  'huit': 8,
  'neuf': 9,
  'dix': 10,
  'onze': 11,
  'douze': 12,
  'treize': 13,
  'quatorze': 14,
  'quinze': 15,
  'seize': 16,
  'vingt': 20,
  'vingts': 20,
  'trente': 30,
  'quarante': 40,
  'cinquante': 50,
  'soixante': 60,
  'septante': 70,
  'huitante': 80,
  'octante': 80,
  'nonante': 90,
  'cent': 100,
  'cents': 100,
  'mille': 1000,
};

const Set<String> _hourWords = {'heure', 'heures', 'h'};
const Set<String> _minuteWords = {'minute', 'minutes', 'min', 'mn'};

/// Words after which « un »/« une » is a number rather than an article.
const Set<String> _unitWords = {
  ..._hourWords,
  ..._minuteWords,
  'seconde',
  'secondes',
  '%',
};

/// Words just before a quantity of hours that make it a duration.
const Set<String> _durationCues = {
  'dans',
  'pendant',
  'durant',
  'minuteur',
  'après',
  'sur',
  'en',
  'encore',
};

/// Words just before a quantity of hours that make it a clock time.
const Set<String> _timeCues = {'à', 'a', 'vers', 'dès', "jusqu'à", 'avant'};

/// Words that cannot follow a minute count (« 22 heures 7 jours »).
const Set<String> _notMinuteFollowers = {
  'jour',
  'jours',
  'fois',
  'h',
  'heure',
  'heures',
  '%',
};

final RegExp _digits = RegExp(r'^\d+$');

/// Normalizes a spoken French phrase: lowercase, apostrophes and spaces
/// normalized, punctuation removed, numbers as digits, then clock times
/// (`22:00`), durations (`90 min`) and percentages (`70 %`).
///
/// Quantities of hours are durations after « dans », « pendant », « durant »,
/// « après », « sur », « en », « encore » or « minuteur » (« minuteur de/à/pour
/// … » too); clock times after « à », « vers », « dès », « jusqu’à »,
/// « avant ». Without a cue, « une heure » and « une heure et demie » are
/// durations (60 and 90 min) and everything else is a clock time.
String normalizeFrench(String input) {
  var s = input.toLowerCase();
  s = s.replaceAll(RegExp('[’‘`´ʼ′]'), "'");
  s = s.replaceAll(RegExp('[    \t\r\n]'), ' ');
  s = s.replaceAll(RegExp(r'[?!.,;«»"“”()\[\]{}…–—/*+=_]'), ' ');
  // A colon survives only inside a clock time (« 22:30 »).
  s = s.replaceAll(RegExp(r'(?<!\d):|:(?!\d)'), ' ');
  s = s.replaceAllMapped(RegExp(r'(\d)\s*%'), (m) => '${m[1]} %');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (s.isEmpty) return s;

  // Fixed expressions, before numbers are converted.
  s = s.replaceAll(RegExp(r"\bpour ?cents?\b"), '%');
  s = s.replaceAll(RegExp(r"\btrois quarts? d'heure\b"), '45 min');
  s = s.replaceAll(RegExp(r"\b(?:un )?quart d'heure\b"), '15 min');
  s = s.replaceAll(RegExp(r'\b(?:une )?demie?[- ]heure\b'), '30 min');
  s = s.replaceAllMapped(
    RegExp(r"\b(d|qu)'(une?) (heures?|minutes?|h|min)\b"),
    (m) => '${m[1] == 'd' ? 'de' : 'que'} ${m[2]} ${m[3]}',
  );

  var tokens = s.split(' ');
  tokens = _convertNumbers(tokens);
  tokens = _convertTimes(tokens);
  tokens = _convertPercents(tokens);
  return tokens.join(' ');
}

// --- numbers ---------------------------------------------------------------

List<String> _convertNumbers(List<String> input) {
  // Split hyphenated number compounds (« vingt-deux », « soixante-et-onze »).
  final tokens = <String>[];
  for (final t in input) {
    if (t.contains('-')) {
      final parts = t.split('-');
      if (parts.every((p) => _numberWords.containsKey(p) || p == 'et') &&
          parts.any(_numberWords.containsKey)) {
        tokens.addAll(parts);
        continue;
      }
    }
    tokens.add(t);
  }

  final out = <String>[];
  var i = 0;
  while (i < tokens.length) {
    final t = tokens[i];
    if (_numberWords.containsKey(t)) {
      // « un »/« une » alone are articles unless a unit follows.
      final isArticle =
          (t == 'un' || t == 'une') &&
          !(i + 1 < tokens.length && _unitWords.contains(tokens[i + 1]));
      if (!isArticle) {
        final parsed = _parseNumber(tokens, i);
        if (parsed != null) {
          out.add('${parsed.value}');
          i += parsed.length;
          continue;
        }
      }
    }
    out.add(t);
    i++;
  }
  return out;
}

/// Parses the longest valid French number starting at [start].
({int value, int length})? _parseNumber(List<String> t, int start) {
  var total = 0;
  var current = 0;
  var j = start;
  var any = false;
  var previous = -1;
  while (j < t.length) {
    final w = t[j];
    if (w == 'et') {
      // « vingt et un », « soixante et onze », « septante et une ».
      final r = current % 100;
      if (any &&
          j + 1 < t.length &&
          const {'un', 'une', 'onze'}.contains(t[j + 1]) &&
          r >= 20 &&
          r % 10 == 0) {
        j++;
        continue;
      }
      break;
    }
    final v = _numberWords[w];
    if (v == null) break;
    if (v == 0) {
      if (!any) return (value: 0, length: 1);
      break;
    }
    if (v == 1000) {
      if (total > 0) break;
      total = (current == 0 ? 1 : current) * 1000;
      current = 0;
    } else if (v == 100) {
      if (current >= 10) break; // « deux cents », « cent »
      current = (current == 0 ? 1 : current) * 100;
    } else if (v == 20 && previous == 4 && current % 100 == 4) {
      current += 76; // « quatre-vingt(s) »
    } else if (v >= 20) {
      if (current % 100 != 0) break;
      current += v;
    } else if (v >= 10) {
      final r = current % 100;
      // « soixante-dix », « quatre-vingt-onze ».
      if (r != 0 && r != 60 && r != 80) break;
      current += v;
    } else {
      final r = current % 100;
      if (r % 10 != 0) break; // « vingt-deux trois » is two numbers
      if (r == 10 && v < 7) break; // only « dix-sept » … « dix-neuf »
      current += v;
    }
    previous = v;
    any = true;
    j++;
  }
  if (!any) return null;
  return (value: total + current, length: j - start);
}

// --- times and durations ----------------------------------------------------

typedef _Suffix = ({int minutes, int length, String kind});

/// Reads what follows « N heures »: « 30 », « et demie », « et quart »,
/// « moins le quart », « moins 10 ».
_Suffix _readSuffix(List<String> t, int j) {
  String? at(int k) => k < t.length ? t[k] : null;
  final a = at(j);
  if (a != null && _digits.hasMatch(a)) {
    final v = int.parse(a);
    if (v <= 59 && !_notMinuteFollowers.contains(at(j + 1))) {
      final extra = _minuteWords.contains(at(j + 1)) ? 1 : 0;
      return (minutes: v, length: 1 + extra, kind: 'digits');
    }
  }
  if (a == 'et' && (at(j + 1) == 'demie' || at(j + 1) == 'demi')) {
    return (minutes: 30, length: 2, kind: 'demie');
  }
  if (a == 'et' && at(j + 1) == 'quart') {
    return (minutes: 15, length: 2, kind: 'quart');
  }
  if (a == 'moins') {
    if (at(j + 1) == 'le' && at(j + 2) == 'quart') {
      return (minutes: -15, length: 3, kind: 'moins');
    }
    if (at(j + 1) == 'quart') return (minutes: -15, length: 2, kind: 'moins');
    final b = at(j + 1);
    if (b != null && _digits.hasMatch(b)) {
      final v = int.parse(b);
      if (v >= 1 && v <= 59) {
        final extra = _minuteWords.contains(at(j + 2)) ? 1 : 0;
        return (minutes: -v, length: 2 + extra, kind: 'moins');
      }
    }
  }
  return (minutes: 0, length: 0, kind: 'none');
}

String _clock(int hour, int minute) {
  var h = hour;
  var m = minute;
  if (m < 0) {
    h -= 1;
    m += 60;
  }
  h %= 24;
  return '$h:${m.toString().padLeft(2, '0')}';
}

List<String> _convertTimes(List<String> input) {
  // Expand glued forms: « 22h », « 22h30 », « 10min », « 07:30 ».
  final t = <String>[];
  for (final w in input) {
    final glued = RegExp(r'^(\d{1,2})h(\d{2})?$').firstMatch(w);
    if (glued != null) {
      t
        ..add(glued[1]!)
        ..add('h');
      if (glued[2] != null) t.add(glued[2]!);
      continue;
    }
    final clock = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(w);
    if (clock != null) {
      final h = int.parse(clock[1]!);
      final m = int.parse(clock[2]!);
      t.add(h <= 24 && m <= 59 ? _clock(h, m) : w);
      continue;
    }
    final minutes = RegExp(r'^(\d+)(?:min|mn)$').firstMatch(w);
    if (minutes != null) {
      t
        ..add(minutes[1]!)
        ..add('min');
      continue;
    }
    t.add(w);
  }

  final out = <String>[];
  var i = 0;
  while (i < t.length) {
    final w = t[i];
    final next = i + 1 < t.length ? t[i + 1] : null;
    if (_digits.hasMatch(w) && _hourWords.contains(next)) {
      final hours = int.parse(w);
      final suffix = _readSuffix(t, i + 2);
      if (_isDuration(out, hours, suffix.kind)) {
        final total = hours * 60 + suffix.minutes;
        out
          ..add('${total < 0 ? 0 : total}')
          ..add('min');
      } else {
        out.add(_clock(hours, suffix.minutes));
      }
      i += 2 + suffix.length;
      continue;
    }
    if (_digits.hasMatch(w) && _minuteWords.contains(next)) {
      out
        ..add(w)
        ..add('min');
      i += 2;
      continue;
    }
    if ((w == 'midi' || w == 'minuit') &&
        !(out.isNotEmpty && out.last.endsWith('après'))) {
      final suffix = _readSuffix(t, i + 1);
      out.add(_clock(w == 'midi' ? 12 : 0, suffix.minutes));
      i += 1 + suffix.length;
      continue;
    }
    out.add(w);
    i++;
  }
  return out;
}

bool _isDuration(List<String> before, int hours, String suffixKind) {
  final p1 = before.isNotEmpty ? before.last : null;
  final p2 = before.length >= 2 ? before[before.length - 2] : null;
  if (_durationCues.contains(p1)) return true;
  if (p2 == 'minuteur' &&
      const {'de', "d'", 'à', 'a', 'pour', 'sur'}.contains(p1)) {
    return true;
  }
  if (_timeCues.contains(p1)) return false;
  if (hours >= 24) return true;
  return hours == 1 && (suffixKind == 'none' || suffixKind == 'demie');
}

// --- percentages ----------------------------------------------------------------

List<String> _convertPercents(List<String> t) {
  final out = <String>[];
  var i = 0;
  while (i < t.length) {
    if (_digits.hasMatch(t[i]) &&
        i + 2 < t.length &&
        t[i + 1] == 'pour' &&
        t[i + 2] == '100') {
      out
        ..add(t[i])
        ..add('%');
      i += 3;
      continue;
    }
    out.add(t[i]);
    i++;
  }
  return out;
}

// --- extraction helpers -----------------------------------------------------------

/// First duration `N min` of a normalized phrase, or null.
int? parseDurationMinutes(String normalized) {
  final match = RegExp(r'(?:^|\s)(\d{1,4}) min(?=\s|$)').firstMatch(normalized);
  return match == null ? null : int.parse(match[1]!);
}

/// First clock time `H:MM` of a normalized phrase, or null.
({int hour, int minute})? parseClockTime(String normalized) {
  final match = RegExp(r'(?:^|\s)(\d{1,2}):(\d{2})(?=\s|$)')
      .firstMatch(normalized);
  if (match == null) return null;
  final hour = int.parse(match[1]!);
  final minute = int.parse(match[2]!);
  if (hour > 23 || minute > 59) return null;
  return (hour: hour, minute: minute);
}

const List<String> _dayNames = [
  'lundi',
  'mardi',
  'mercredi',
  'jeudi',
  'vendredi',
  'samedi',
  'dimanche',
];

final RegExp _everyDay = RegExp(
  r"\b(?:tous les (?:jours|soirs|matins|apres midi)|toutes les (?:nuits|soirees)|chaque (?:jour|soir|matin|nuit)|7 jours sur 7|toute la semaine)\b",
);
final RegExp _weekdays = RegExp(
  r"\b(?:en semaine|(?:chaque|tous les) jours? de (?:la )?semaine|les jours de (?:la )?semaine|jours ouvrables|jours ouvres)\b",
);
final RegExp _weekend = RegExp(r'\b(?:les? week ?ends?|le we)\b');
final RegExp _dayRange = RegExp(
  r'\bdu (lundi|mardi|mercredi|jeudi|vendredi|samedi|dimanche) au (lundi|mardi|mercredi|jeudi|vendredi|samedi|dimanche)\b',
);
final RegExp _namedDay = RegExp(
  r'\b(lundi|mardi|mercredi|jeudi|vendredi|samedi|dimanche)s?\b',
);

/// Days named in a normalized phrase (1 = Monday … 7 = Sunday), or null.
///
/// « tous les jours/soirs », « chaque jour » → 1–7; « en semaine »,
/// « chaque jour de la semaine », « du lundi au vendredi » → 1–5;
/// « le week-end » → 6–7; « du X au Y » ranges; named days;
/// « sauf … » removes days.
Set<int>? parseDays(String normalized) {
  final text = ' ${foldFrench(normalized).replaceAll('-', ' ')} ';
  final sauf = text.indexOf(' sauf ');
  final main = sauf >= 0 ? text.substring(0, sauf) : text;
  final except = sauf >= 0 ? text.substring(sauf + 6) : '';

  Set<int>? read(String part) {
    Set<int>? days;
    void add(Iterable<int> d) => (days ??= <int>{}).addAll(d);
    var rest = part;
    if (_weekdays.hasMatch(rest)) {
      add([1, 2, 3, 4, 5]);
      rest = rest.replaceAll(_weekdays, ' ');
    }
    if (_everyDay.hasMatch(rest)) {
      add([1, 2, 3, 4, 5, 6, 7]);
      rest = rest.replaceAll(_everyDay, ' ');
    }
    if (_weekend.hasMatch(rest)) {
      add([6, 7]);
      rest = rest.replaceAll(_weekend, ' ');
    }
    for (final m in _dayRange.allMatches(rest)) {
      final from = _dayNames.indexOf(m[1]!) + 1;
      final to = _dayNames.indexOf(m[2]!) + 1;
      var d = from;
      while (true) {
        add([d]);
        if (d == to) break;
        d = d % 7 + 1;
      }
    }
    rest = rest.replaceAll(_dayRange, ' ');
    for (final m in _namedDay.allMatches(rest)) {
      add([_dayNames.indexOf(m[1]!) + 1]);
    }
    return days;
  }

  var days = read(main);
  final removed = except.isEmpty ? null : read(except);
  if (removed != null) {
    days = (days ?? {1, 2, 3, 4, 5, 6, 7}).difference(removed);
  }
  if (days == null || days.isEmpty) return null;
  return days;
}

const Map<String, String> _folds = {
  'à': 'a',
  'â': 'a',
  'ä': 'a',
  'á': 'a',
  'é': 'e',
  'è': 'e',
  'ê': 'e',
  'ë': 'e',
  'î': 'i',
  'ï': 'i',
  'í': 'i',
  'ô': 'o',
  'ö': 'o',
  'ó': 'o',
  'ù': 'u',
  'û': 'u',
  'ü': 'u',
  'ú': 'u',
  'ÿ': 'y',
  'ç': 'c',
  'ñ': 'n',
  'œ': 'oe',
  'æ': 'ae',
};

/// Lowercases and removes French diacritics (« forêt » → « foret »), for
/// accent-insensitive matching.
String foldFrench(String input) {
  final lower = input.toLowerCase();
  final buffer = StringBuffer();
  for (final rune in lower.runes) {
    final ch = String.fromCharCode(rune);
    buffer.write(_folds[ch] ?? ch);
  }
  return buffer.toString();
}
