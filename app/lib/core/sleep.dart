// Sleep nights recorded on the phone (« Sommeil »). Indicative only: no
// fall-asleep latency nor awakenings, since there is no reliable measurement
// (dossier, screen 7).

class Night {
  Night({required this.start, required this.end, this.listenedMinutes = 0});

  final DateTime start;
  final DateTime end;

  /// Minutes of sound actually played during the night.
  final int listenedMinutes;

  /// Elapsed time between start and end (real time, DST-safe).
  Duration get duration =>
      end.isAfter(start) ? end.difference(start) : Duration.zero;

  Map<String, dynamic> toJson() => {
    'start': start.toIso8601String(),
    'end': end.toIso8601String(),
    'listened_minutes': listenedMinutes,
  };

  /// Throws [FormatException] when a date is missing or invalid.
  factory Night.fromJson(Map<String, dynamic> json) {
    final start = json['start'];
    final end = json['end'];
    if (start is! String || end is! String) {
      throw const FormatException('night: "start" and "end" are required');
    }
    final listened = json['listened_minutes'];
    return Night(
      start: DateTime.parse(start),
      end: DateTime.parse(end),
      listenedMinutes: listened is num ? listened.toInt() : 0,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Night &&
      other.start == start &&
      other.end == end &&
      other.listenedMinutes == listenedMinutes;

  @override
  int get hashCode => Object.hash(start, end, listenedMinutes);

  @override
  String toString() => 'Night($start → $end, $listenedMinutes min)';
}

/// Figures of the Sleep screen.
class SleepStats {
  const SleepStats._({
    required this.lastNight,
    required this.last7Days,
    required this.average7,
  });

  /// Computes the stats at [now]. A night belongs to the local calendar day
  /// on which it ends (the wake-up day). Nights not finished yet or with
  /// `end <= start` are ignored.
  factory SleepStats.from(List<Night> nights, DateTime now) {
    final local = now.toLocal();
    final done = [
      for (final n in nights)
        if (n.end.isAfter(n.start) && !n.end.isAfter(now)) n,
    ]..sort((a, b) => a.end.compareTo(b.end));

    final days = <({DateTime day, Duration? duration})>[];
    final durations = <Duration>[];
    for (var back = 6; back >= 0; back--) {
      final day = DateTime(local.year, local.month, local.day - back);
      Duration? total;
      for (final n in done) {
        final end = n.end.toLocal();
        if (end.year == day.year &&
            end.month == day.month &&
            end.day == day.day) {
          total = (total ?? Duration.zero) + n.duration;
        }
      }
      days.add((day: day, duration: total));
      if (total != null) durations.add(total);
    }

    Duration? average;
    if (durations.isNotEmpty) {
      final seconds =
          durations.fold<int>(0, (sum, d) => sum + d.inSeconds) /
          durations.length;
      average = Duration(minutes: (seconds / 60).round());
    }

    return SleepStats._(
      lastNight: done.isEmpty ? null : done.last,
      last7Days: List.unmodifiable(days),
      average7: average,
    );
  }

  /// Most recent finished night (« Cette nuit »).
  final Night? lastNight;

  /// The 7 local days ending today, oldest first; duration null when no night
  /// ended that day.
  final List<({DateTime day, Duration? duration})> last7Days;

  /// Average over the days of [last7Days] that have a night.
  final Duration? average7;
}
