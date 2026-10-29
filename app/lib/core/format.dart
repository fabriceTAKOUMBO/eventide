// French formatting helpers. Plain spaces are used everywhere (« 22 h 00 »,
// « 70 % ») so strings compare predictably across the app.

import 'catalog.dart';
import 'scene.dart';
import 'schedule.dart';

String _two(int n) => n.toString().padLeft(2, '0');

/// « 22 h 00 », « 7 h 05 ».
String formatClock(int hour, int minute) => '$hour h ${_two(minute)}';

/// « 45 min », « 1 h », « 1 h 12 », « 7 h 20 ». Seconds are dropped.
String formatDuration(Duration duration) {
  final total = duration.isNegative ? 0 : duration.inMinutes;
  if (total < 60) return '$total min';
  final hours = total ~/ 60;
  final minutes = total % 60;
  return minutes == 0 ? '$hours h' : '$hours h ${_two(minutes)}';
}

/// Label of the timer chip on the home screen.
String timerChipLabel(TimerSetting timer) => switch (timer) {
  TimerDuration(:final minutes) =>
    'Arrêt ${formatDuration(Duration(minutes: minutes))}',
  TimerNight() => 'Toute la nuit',
  TimerNone() => 'Minuteur',
};

const List<String> _weekdayNames = [
  'lundi',
  'mardi',
  'mercredi',
  'jeudi',
  'vendredi',
  'samedi',
  'dimanche',
];

const List<String> _monthAbbreviations = [
  'janv.',
  'févr.',
  'mars',
  'avr.',
  'mai',
  'juin',
  'juil.',
  'août',
  'sept.',
  'oct.',
  'nov.',
  'déc.',
];

/// « lundi » … « dimanche » for an ISO weekday (1 = Monday).
String weekdayName(int weekday) => _weekdayNames[(weekday - 1) % 7];

String _capitalize(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// Whole calendar days between the dates of [from] and [to] (DST-safe).
int calendarDaysBetween(DateTime from, DateTime to) {
  final a = DateTime.utc(from.year, from.month, from.day);
  final b = DateTime.utc(to.year, to.month, to.day);
  return b.difference(a).inDays;
}

/// Home tile label for the next scheduled start: « Ce soir · 22 h 00 »
/// (today from 18 h), « Aujourd’hui · 13 h 30 », « Demain · 7 h 30 »,
/// « Lundi · 22 h 00 » within a week, « Lundi 3 nov. · 22 h 00 » beyond.
String nextStartLabel(DateTime next, DateTime now) {
  final n = next.toLocal();
  final days = calendarDaysBetween(now.toLocal(), n);
  final clock = formatClock(n.hour, n.minute);
  final String day;
  if (days == 0) {
    day = n.hour >= 18 ? 'Ce soir' : 'Aujourd’hui';
  } else if (days == 1) {
    day = 'Demain';
  } else if (days > 1 && days <= 7) {
    day = _capitalize(weekdayName(n.weekday));
  } else {
    day =
        '${_capitalize(weekdayName(n.weekday))} ${n.day} ${_monthAbbreviations[n.month - 1]}';
  }
  return '$day · $clock';
}

/// Line of the schedules list: « 22 h 00 · Tous les jours · Pour dormir ·
/// Cascade en forêt ».
String scheduleListLine(Schedule schedule, [Catalog? catalog]) {
  final name = catalog?.landscape(schedule.landscapeId)?.name;
  return [
    formatClock(schedule.hour, schedule.minute),
    schedule.daysSummary(),
    schedule.reminder.label,
    ?name,
  ].join(' · ');
}
