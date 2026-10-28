import 'dart:convert';

import 'package:eventide/core/catalog.dart';
import 'package:eventide/core/schedule.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Schedule schedule({
    int hour = 22,
    int minute = 0,
    Set<int> days = Schedule.everyDay,
    bool active = true,
    String id = 'a1b2',
  }) => Schedule(
    id: id,
    hour: hour,
    minute: minute,
    days: days,
    landscapeId: 'cascade-foret',
    active: active,
  );

  group('JSON', () {
    test('contract §2 example round-trips', () {
      final json = jsonDecode(
        '''
{"id": "a1b2", "heure": "22:00", "jours": [1,2,3,4,5,6,7], "montee_minutes": 10,
 "paysage": "cascade-foret", "rappel": "dormir", "actif": true}''',
      ) as Map<String, dynamic>;
      final s = Schedule.fromJson(json);
      expect(s.hour, 22);
      expect(s.minute, 0);
      expect(s.days, Schedule.everyDay);
      expect(s.rampMinutes, 10);
      expect(s.reminder, Reminder.dormir);
      expect(s.active, isTrue);
      expect(s.toJson(), json);
      expect(Schedule.fromJson(s.toJson()), s);
    });

    test('days are written sorted, time zero-padded', () {
      final s = Schedule(
        id: 'x',
        hour: 7,
        minute: 5,
        days: {5, 1, 3},
        rampMinutes: 25,
        landscapeId: 'sous-bois',
        reminder: Reminder.detente,
        active: false,
      );
      expect(s.toJson(), {
        'id': 'x',
        'heure': '07:05',
        'jours': [1, 3, 5],
        'montee_minutes': 25,
        'paysage': 'sous-bois',
        'rappel': 'detente',
        'actif': false,
      });
    });

    test('invalid documents throw', () {
      final valid = schedule().toJson();
      for (final patch in <Map<String, dynamic>>[
        {'id': null},
        {'heure': '25:00'},
        {'heure': 'soir'},
        {'jours': []},
        {
          'jours': [0, 1],
        },
        {
          'jours': [8],
        },
        {'paysage': null},
      ]) {
        expect(
          () => Schedule.fromJson({...valid, ...patch}),
          throwsFormatException,
          reason: '$patch',
        );
      }
    });
  });

  test('parseTime and isValidRamp', () {
    expect(Schedule.parseTime('22:00'), (hour: 22, minute: 0));
    expect(Schedule.parseTime('07:30'), (hour: 7, minute: 30));
    expect(Schedule.parseTime('7:30'), isNull);
    expect(Schedule.parseTime('7:30', strict: false), (hour: 7, minute: 30));
    expect(Schedule.parseTime('24:00'), isNull);
    expect(Schedule.parseTime('12:60'), isNull);
    expect(Schedule.parseTime(2200), isNull);
    for (final ok in [5, 10, 15, 20, 45, 60]) {
      expect(Schedule.isValidRamp(ok), isTrue, reason: '$ok');
    }
    for (final bad in [0, 3, 7, 12, 65, 61, 17, '10', null]) {
      expect(Schedule.isValidRamp(bad), isFalse, reason: '$bad');
    }
    expect(Schedule.isValidRamp(70, const Limits(rampMinutesMax: 90)), isTrue);
  });

  group('nextOccurrence', () {
    test('later today, else tomorrow', () {
      final s = schedule();
      expect(
        s.nextOccurrence(DateTime(2026, 10, 28, 18, 0)),
        DateTime(2026, 10, 28, 22, 0),
      );
      expect(
        s.nextOccurrence(DateTime(2026, 10, 28, 22, 30)),
        DateTime(2026, 10, 29, 22, 0),
      );
    });

    test('strictly after now', () {
      expect(
        schedule().nextOccurrence(DateTime(2026, 10, 28, 22, 0)),
        DateTime(2026, 10, 29, 22, 0),
      );
    });

    test('weekdays only: Friday night goes to Monday', () {
      final s = schedule(days: {1, 2, 3, 4, 5});
      // 2026-10-30 is a Friday.
      expect(DateTime(2026, 10, 30).weekday, DateTime.friday);
      expect(
        s.nextOccurrence(DateTime(2026, 10, 30, 23, 0)),
        DateTime(2026, 11, 2, 22, 0),
      );
    });

    test('a single weekday already passed today is next week', () {
      // 2026-10-28 is a Wednesday.
      final s = schedule(days: {3});
      expect(
        s.nextOccurrence(DateTime(2026, 10, 28, 23, 0)),
        DateTime(2026, 11, 4, 22, 0),
      );
    });

    test('month and year boundaries', () {
      final s = schedule(hour: 7, minute: 30);
      expect(
        s.nextOccurrence(DateTime(2026, 12, 31, 8, 0)),
        DateTime(2027, 1, 1, 7, 30),
      );
      expect(
        s.nextOccurrence(DateTime(2028, 2, 28, 9, 0)),
        DateTime(2028, 2, 29, 7, 30),
      );
    });

    test('inactive or empty schedules have none', () {
      expect(
        schedule(active: false).nextOccurrence(DateTime(2026, 10, 28)),
        isNull,
      );
      expect(schedule(days: {}).nextOccurrence(DateTime(2026, 10, 28)), isNull);
    });

    // The checks below hold in any time zone: they assert wall-clock fields
    // of local DateTimes. In a DST zone (e.g. TZ=Europe/Brussels) they
    // exercise the 2026 changes (29 March and 25 October).
    test('22:00 stays 22:00 across both DST changes', () {
      final s = schedule();
      var now = DateTime(2026, 3, 20, 23, 0);
      for (var i = 0; i < 230; i++) {
        final next = s.nextOccurrence(now)!;
        expect(next.hour, 22, reason: '$next');
        expect(next.minute, 0, reason: '$next');
        expect(next.isAfter(now), isTrue);
        expect(next.difference(now).inHours, lessThanOrEqualTo(25));
        now = next;
      }
      expect(now.year, 2026);
      expect(now.month, 11);
    });

    test('the day of a DST change itself', () {
      final s = schedule();
      expect(
        s.nextOccurrence(DateTime(2026, 3, 29, 1, 0)),
        DateTime(2026, 3, 29, 22, 0),
      );
      expect(
        s.nextOccurrence(DateTime(2026, 10, 25, 1, 0)),
        DateTime(2026, 10, 25, 22, 0),
      );
      expect(
        s.nextOccurrence(DateTime(2026, 3, 28, 22, 0, 1)),
        DateTime(2026, 3, 29, 22, 0),
      );
    });

    test('a time inside the spring-forward gap is moved forward, same day', () {
      final s = schedule(hour: 2, minute: 30);
      final next = s.nextOccurrence(DateTime(2026, 3, 28, 23, 0))!;
      expect(next.day, 29);
      expect(next.minute, 30);
      // 2:30 where it exists, 3:30 where 2:00–3:00 is skipped.
      expect(next.hour, anyOf(2, 3));
    });

    test('a repeated time on fall-back day is kept', () {
      final s = schedule(hour: 2, minute: 30);
      final next = s.nextOccurrence(DateTime(2026, 10, 24, 23, 0))!;
      expect([next.day, next.hour, next.minute], [25, 2, 30]);
    });

    test('a UTC now is read in local time', () {
      final now = DateTime(2026, 10, 28, 18, 0);
      expect(
        schedule().nextOccurrence(now.toUtc()),
        DateTime(2026, 10, 28, 22, 0),
      );
    });
  });

  test('nextOf picks the earliest active schedule', () {
    final now = DateTime(2026, 10, 28, 12, 0);
    final morning = schedule(id: 'm', hour: 7, minute: 30);
    final evening = schedule(id: 'e', hour: 22);
    final lunch = schedule(id: 'l', hour: 13, minute: 30, active: false);
    expect(
      Schedule.nextOf([morning, evening, lunch], now),
      DateTime(2026, 10, 28, 22, 0),
    );
    expect(Schedule.nextOf([morning], now), DateTime(2026, 10, 29, 7, 30));
    expect(Schedule.nextOf([lunch], now), isNull);
    expect(Schedule.nextOf(const [], now), isNull);
  });

  test('daysSummary', () {
    expect(schedule().daysSummary(), 'Tous les jours');
    expect(
      schedule(days: {1, 2, 3, 4, 5}).daysSummary(),
      'Du lundi au vendredi',
    );
    expect(schedule(days: {6, 7}).daysSummary(), 'Le week-end');
    expect(schedule(days: {5, 1, 3}).daysSummary(), 'lun. mer. ven.');
    expect(schedule(days: {7}).daysSummary(), 'dim.');
    expect(
      schedule(days: {1, 2, 3, 4, 6}).daysSummary(),
      'lun. mar. mer. jeu. sam.',
    );
  });

  test('reminders', () {
    expect(Reminder.dormir.notificationText, 'C’est l’heure d’aller dormir');
    expect(Reminder.detente.notificationText, 'C’est l’heure de vous détendre');
    expect(Reminder.dormir.label, 'Pour dormir');
    expect(Reminder.detente.label, 'Pour se détendre');
    expect(Reminder.fromName('detente'), Reminder.detente);
    expect(Reminder.fromName('sieste'), isNull);
  });

  test('copyWith and equality', () {
    final s = schedule();
    expect(s.copyWith(minute: 30).time, '22:30');
    expect(s.copyWith(), s);
    expect(s.copyWith(active: false), isNot(s));
    expect(() => s.days.add(1), throwsUnsupportedError);
  });
}
