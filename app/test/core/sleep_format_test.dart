import 'package:eventide/core/format.dart';
import 'package:eventide/core/scene.dart';
import 'package:eventide/core/schedule.dart';
import 'package:eventide/core/sleep.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

void main() {
  group('Night', () {
    test('duration and JSON', () {
      final night = Night(
        start: DateTime(2026, 10, 27, 23, 5),
        end: DateTime(2026, 10, 28, 6, 25),
        listenedMinutes: 60,
      );
      expect(night.duration, const Duration(hours: 7, minutes: 20));
      expect(Night.fromJson(night.toJson()), night);
      expect(night.toJson().keys, ['start', 'end', 'listened_minutes']);
      expect(Night(start: night.end, end: night.start).duration, Duration.zero);
      expect(() => Night.fromJson(const {'start': 'x'}), throwsFormatException);
    });
  });

  group('SleepStats', () {
    final now = DateTime(2026, 10, 28, 9, 0);
    Night night(
      int day,
      int startHour,
      int endDay,
      int endHour, [
      int endMinute = 0,
    ]) => Night(
      start: DateTime(2026, 10, day, startHour),
      end: DateTime(2026, 10, endDay, endHour, endMinute),
    );

    test('empty', () {
      final stats = SleepStats.from(const [], now);
      expect(stats.lastNight, isNull);
      expect(stats.average7, isNull);
      expect(stats.last7Days, hasLength(7));
      expect(stats.last7Days.every((d) => d.duration == null), isTrue);
      expect(stats.last7Days.first.day, DateTime(2026, 10, 22));
      expect(stats.last7Days.last.day, DateTime(2026, 10, 28));
    });

    test('nights belong to their wake-up day; average over nights only', () {
      final nights = [
        night(27, 23, 28, 7), // 8 h, today
        night(25, 22, 26, 6), // 8 h
        night(23, 23, 24, 5), // 6 h
        night(10, 23, 11, 7), // too old
        night(28, 8, 28, 10), // not finished at 9:00
      ];
      final stats = SleepStats.from(nights, now);
      expect(stats.lastNight, nights.first);
      final durations = stats.last7Days
          .map((d) => d.duration?.inHours)
          .toList();
      expect(durations, [null, null, 6, null, 8, null, 8]);
      expect(stats.average7, const Duration(hours: 7, minutes: 20));
    });

    test('a nap and a night on the same day add up', () {
      final stats = SleepStats.from([
        night(27, 23, 28, 6),
        Night(
          start: DateTime(2026, 10, 28, 7),
          end: DateTime(2026, 10, 28, 8, 30),
        ),
      ], now);
      expect(
        stats.last7Days.last.duration,
        const Duration(hours: 8, minutes: 30),
      );
      expect(stats.lastNight!.end, DateTime(2026, 10, 28, 8, 30));
    });

    test('lists are immutable', () {
      final stats = SleepStats.from(const [], now);
      expect(() => stats.last7Days.clear(), throwsUnsupportedError);
    });
  });

  group('format', () {
    test('clock', () {
      expect(formatClock(22, 0), '22 h 00');
      expect(formatClock(7, 5), '7 h 05');
      expect(formatClockShort(22, 0), '22 h');
      expect(formatClockShort(22, 30), '22 h 30');
      expect(formatClockShort(7, 5), '7 h 05');
    });

    test('durations', () {
      expect(formatDuration(const Duration(minutes: 45)), '45 min');
      expect(formatDuration(const Duration(minutes: 60)), '1 h');
      expect(formatDuration(const Duration(minutes: 72)), '1 h 12');
      expect(formatDuration(const Duration(hours: 7, minutes: 20)), '7 h 20');
      expect(formatDuration(const Duration(hours: 1, minutes: 5)), '1 h 05');
      expect(formatDuration(const Duration(seconds: 59)), '0 min');
      expect(formatDuration(const Duration(minutes: -3)), '0 min');
      expect(formatPercent(70), '70 %');
    });

    test('timer chip and summary', () {
      expect(timerChipLabel(const TimerDuration(60)), 'Arrêt 1 h');
      expect(timerChipLabel(const TimerDuration(15)), 'Arrêt 15 min');
      expect(timerChipLabel(const TimerDuration(90)), 'Arrêt 1 h 30');
      expect(timerChipLabel(const TimerNight()), 'Toute la nuit');
      expect(timerChipLabel(const TimerNone()), 'Minuteur');
      expect(timerSummary(const TimerDuration(60)), 'Arrêt après 1 h');
      expect(timerSummary(const TimerNone()), 'Sans minuteur');
    });

    test('next start label', () {
      final now = DateTime(2026, 10, 28, 12, 0); // Wednesday
      expect(
        nextStartLabel(DateTime(2026, 10, 28, 22, 0), now),
        'Ce soir · 22 h 00',
      );
      expect(
        nextStartLabel(DateTime(2026, 10, 28, 18, 0), now),
        'Ce soir · 18 h 00',
      );
      expect(
        nextStartLabel(DateTime(2026, 10, 28, 13, 30), now),
        'Aujourd’hui · 13 h 30',
      );
      expect(
        nextStartLabel(DateTime(2026, 10, 29, 7, 30), now),
        'Demain · 7 h 30',
      );
      expect(
        nextStartLabel(DateTime(2026, 11, 2, 22, 0), now),
        'Lundi · 22 h 00',
      );
      expect(
        nextStartLabel(DateTime(2026, 11, 4, 22, 0), now),
        'Mercredi · 22 h 00',
      );
      expect(
        nextStartLabel(DateTime(2026, 11, 12, 22, 0), now),
        'Jeudi 12 nov. · 22 h 00',
      );
      // Across a month end and a DST change.
      expect(
        nextStartLabel(
          DateTime(2026, 11, 1, 0, 30),
          DateTime(2026, 10, 31, 23, 0),
        ),
        'Demain · 0 h 30',
      );
      expect(
        nextStartLabel(
          DateTime(2026, 10, 26, 22, 0),
          DateTime(2026, 10, 25, 1, 0),
        ),
        'Demain · 22 h 00',
      );
    });

    test('weekday names and calendar days', () {
      expect(weekdayName(DateTime.monday), 'lundi');
      expect(weekdayName(DateTime.sunday), 'dimanche');
      expect(
        calendarDaysBetween(
          DateTime(2026, 3, 28, 23),
          DateTime(2026, 3, 30, 1),
        ),
        2,
      );
    });

    test('schedule summaries', () {
      final catalog = loadCatalog();
      final s = Schedule(
        id: 'a',
        hour: 22,
        minute: 0,
        days: Schedule.everyDay,
        landscapeId: 'cascade-foret',
      );
      expect(
        scheduleSummary(s, catalog),
        'Tous les jours à 22 h · Cascade en forêt',
      );
      expect(scheduleSummary(s), 'Tous les jours à 22 h');
      expect(
        scheduleListLine(s.copyWith(rampMinutes: 10), catalog),
        '22 h 00 · Tous les jours · Pour dormir · Cascade en forêt',
      );
      expect(
        scheduleSummary(
          s.copyWith(hour: 13, minute: 30, days: {1, 2, 3, 4, 5}),
          catalog,
        ),
        'Du lundi au vendredi à 13 h 30 · Cascade en forêt',
      );
    });
  });
}
