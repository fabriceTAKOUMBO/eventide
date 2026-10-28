// Schedules (« Programmations », contract §2): start the sound by itself at a
// local wall-clock time on chosen days, with a progressive ramp.

import 'catalog.dart';

/// Reminder message shown with the scheduled start.
enum Reminder {
  dormir,
  detente;

  /// Notification text.
  String get notificationText => switch (this) {
    Reminder.dormir => 'C’est l’heure d’aller dormir',
    Reminder.detente => 'C’est l’heure de vous détendre',
  };

  /// Label of the choice on the « Nouvelle programmation » screen.
  String get label => switch (this) {
    Reminder.dormir => 'Pour dormir',
    Reminder.detente => 'Pour se détendre',
  };

  static Reminder? fromName(Object? value) {
    for (final r in Reminder.values) {
      if (r.name == value) return r;
    }
    return null;
  }
}

/// A schedule. [days] uses ISO weekdays: 1 = Monday … 7 = Sunday, like
/// [DateTime.weekday].
class Schedule {
  Schedule({
    required this.id,
    required this.hour,
    required this.minute,
    required Set<int> days,
    this.rampMinutes = defaultRampMinutes,
    required this.landscapeId,
    this.reminder = Reminder.dormir,
    this.active = true,
  }) : days = Set.unmodifiable(days);

  static const int defaultRampMinutes = 10;
  static const Set<int> everyDay = {1, 2, 3, 4, 5, 6, 7};

  final String id;

  /// Local hour, 0–23.
  final int hour;

  /// Local minute, 0–59.
  final int minute;
  final Set<int> days;

  /// `montee_minutes`: 5, 10, or 15–60 by steps of 5.
  final int rampMinutes;

  /// `paysage`.
  final String landscapeId;

  /// `rappel`.
  final Reminder reminder;

  /// `actif`.
  final bool active;

  /// `HH:MM`, as stored in the `heure` field.
  String get time =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  /// Days sorted Monday first.
  List<int> get sortedDays => days.toList()..sort();

  /// Parses `HH:MM` (24 h). A one-digit hour (`7:30`) is accepted when
  /// [strict] is false.
  static ({int hour, int minute})? parseTime(
    Object? value, {
    bool strict = true,
  }) {
    if (value is! String) return null;
    final match = (strict ? _strictTime : _looseTime).firstMatch(value);
    if (match == null) return null;
    final hour = int.parse(match.group(1)!);
    final minute = int.parse(match.group(2)!);
    if (hour > 23 || minute > 59) return null;
    return (hour: hour, minute: minute);
  }

  static final RegExp _strictTime = RegExp(r'^(\d{2}):(\d{2})$');
  static final RegExp _looseTime = RegExp(r'^(\d{1,2}):(\d{2})$');

  /// Formats a time as `HH:MM`.
  static String formatTime(int hour, int minute) =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  /// `montee_minutes`: 5 or 10, or the custom range
  /// (`montee_minutes_min`–`montee_minutes_max`) by steps of 5.
  static bool isValidRamp(Object? minutes, [Limits limits = const Limits()]) {
    if (minutes is! int) return false;
    if (minutes == 5 || minutes == 10) return true;
    return minutes >= limits.rampMinutesMin &&
        minutes <= limits.rampMinutesMax &&
        minutes % 5 == 0;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'heure': time,
    'jours': sortedDays,
    'montee_minutes': rampMinutes,
    'paysage': landscapeId,
    'rappel': reminder.name,
    'actif': active,
  };

  /// Parses a stored schedule. Throws [FormatException] when a field is
  /// missing or invalid.
  factory Schedule.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final time = parseTime(json['heure'], strict: false);
    final days = json['jours'];
    final landscape = json['paysage'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('schedule: "id" must be a string');
    }
    if (time == null) {
      throw const FormatException('schedule: "heure" must be HH:MM');
    }
    if (days is! List ||
        days.isEmpty ||
        days.any((d) => d is! int || d < 1 || d > 7)) {
      throw const FormatException('schedule: "jours" must list 1..7');
    }
    if (landscape is! String || landscape.isEmpty) {
      throw const FormatException('schedule: "paysage" must be a string');
    }
    final ramp = json['montee_minutes'];
    return Schedule(
      id: id,
      hour: time.hour,
      minute: time.minute,
      days: days.cast<int>().toSet(),
      rampMinutes: ramp is int && ramp > 0 ? ramp : defaultRampMinutes,
      landscapeId: landscape,
      reminder: Reminder.fromName(json['rappel']) ?? Reminder.dormir,
      active: json['actif'] != false,
    );
  }

  /// Next start strictly after [now], in local wall-clock time: a 22:00
  /// schedule stays at 22:00 across daylight-saving changes. Returns null
  /// when the schedule is inactive or has no day.
  ///
  /// When the wall-clock time does not exist that day (spring-forward gap),
  /// [DateTime] moves it forward by the size of the gap.
  DateTime? nextOccurrence(DateTime now) {
    if (!active || days.isEmpty) return null;
    final local = now.toLocal();
    for (var offset = 0; offset <= 7; offset++) {
      // Calendar arithmetic on the date fields, never on durations: adding
      // 24 h would drift by one hour across a DST change.
      final day = DateTime(local.year, local.month, local.day + offset, 12);
      if (!days.contains(day.weekday)) continue;
      final candidate = DateTime(day.year, day.month, day.day, hour, minute);
      if (candidate.isAfter(local)) return candidate;
    }
    return null;
  }

  /// Earliest next start among active schedules, or null.
  static DateTime? nextOf(Iterable<Schedule> schedules, DateTime now) {
    DateTime? best;
    for (final s in schedules) {
      final next = s.nextOccurrence(now);
      if (next != null && (best == null || next.isBefore(best))) best = next;
    }
    return best;
  }

  /// « Tous les jours », « Du lundi au vendredi », « Le week-end », or the
  /// abbreviated days (« lun. mer. ven. »).
  String daysSummary() {
    if (days.length == 7) return 'Tous les jours';
    if (days.length == 5 && days.every((d) => d <= 5)) {
      return 'Du lundi au vendredi';
    }
    if (days.length == 2 && days.contains(6) && days.contains(7)) {
      return 'Le week-end';
    }
    if (days.isEmpty) return 'Aucun jour';
    return [for (final d in sortedDays) _dayAbbreviations[d - 1]].join(' ');
  }

  static const List<String> _dayAbbreviations = [
    'lun.',
    'mar.',
    'mer.',
    'jeu.',
    'ven.',
    'sam.',
    'dim.',
  ];

  Schedule copyWith({
    String? id,
    int? hour,
    int? minute,
    Set<int>? days,
    int? rampMinutes,
    String? landscapeId,
    Reminder? reminder,
    bool? active,
  }) {
    return Schedule(
      id: id ?? this.id,
      hour: hour ?? this.hour,
      minute: minute ?? this.minute,
      days: days ?? this.days,
      rampMinutes: rampMinutes ?? this.rampMinutes,
      landscapeId: landscapeId ?? this.landscapeId,
      reminder: reminder ?? this.reminder,
      active: active ?? this.active,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Schedule &&
      other.id == id &&
      other.hour == hour &&
      other.minute == minute &&
      other.days.length == days.length &&
      other.days.containsAll(days) &&
      other.rampMinutes == rampMinutes &&
      other.landscapeId == landscapeId &&
      other.reminder == reminder &&
      other.active == active;

  @override
  int get hashCode => Object.hash(
    id,
    hour,
    minute,
    Object.hashAll(sortedDays),
    rampMinutes,
    landscapeId,
    reminder,
    active,
  );

  @override
  String toString() => 'Schedule(${toJson()})';
}
