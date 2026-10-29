// EventSoundScheduler (contract § 11) on fake time and a seeded random: first delay, gaps,
// never one of the last two variants, random variations in range, no overlap, pause/resume,
// level 0 and mute, the flash before each thunder; storm sequences (catalog `orage`): kinds by
// weight, their timings, the aftershock window, the swells of the rain and the wind.
import 'dart:math';

import 'package:eventide/core/catalog.dart';
import 'package:eventide/core/lightning.dart';
import 'package:eventide/services/audio/audio_engine.dart';
import 'package:eventide/services/audio/event_scheduler.dart';
import 'package:eventide/services/audio/fake_audio_engine.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

const _carrier = EngineLayer(key: 'son:pluie-douce', source: AssetAudioSource('assets/audio/sons/pluie-douce.ogg'), volume: 0.5);
const _wind = EngineLayer(key: 'son:vent', source: AssetAudioSource('assets/audio/sons/vent.ogg'), volume: 0.3);

List<EventVariant> _variants(int n) => [
      for (var i = 1; i <= n; i++)
        EventVariant('tonnerre-$i', () async => AssetAudioSource('assets/audio/sons/tonnerre-$i.ogg')),
    ];

EventLayer _thunder({double volume = 0.6, int variants = 10}) => EventLayer(
      key: 'son:tonnerre',
      variants: _variants(variants),
      volume: volume,
      interval: const SecondsRange(120, 300),
      firstDelay: const SecondsRange(45, 120),
    );

/// The engine plays the loops; each event is recorded with the fake time it started at.
class _Rig {
  _Rig(this.async, {int seed = 1}) {
    scheduler = EventSoundScheduler(engine: engine, random: Random(seed), now: () => t0.add(async.elapsed));
    scheduler.strikes.listen((s) => strikes.add((async.elapsed, s)));
    scheduler.sequences.listen((p) => plans.add((async.elapsed, p)));
    engine.start(const [_carrier, _wind]);
  }

  final FakeAsync async;
  final DateTime t0 = DateTime(2026, 10, 29, 22);
  final engine = _TimedEngine();
  late final EventSoundScheduler scheduler;
  final List<(Duration, LightningStrike)> strikes = [];
  final List<(Duration, StormPlan)> plans = [];

  List<Duration> get starts => engine.times;
}

class _TimedEngine extends FakeAudioEngine {
  late FakeAsync async;
  final List<Duration> times = [];
  final List<Duration> swellTimes = [];

  @override
  Future<void> swell(
    List<String> keys, {
    required double gainDb,
    required Duration rise,
    required Duration hold,
    required Duration fall,
  }) async {
    final before = swells.length;
    await super.swell(keys, gainDb: gainDb, rise: rise, hold: hold, fall: fall);
    if (swells.length > before) swellTimes.add(async.elapsed);
  }

  @override
  Future<Duration?> playEvent(
    String key,
    AudioSourceRef source, {
    required double volume,
    double gain = 1.0,
    double speed = 1.0,
    double pan = 0.0,
  }) async {
    final played = await super.playEvent(key, source, volume: volume, gain: gain, speed: speed, pan: pan);
    if (played != null) times.add(async.elapsed);
    return played;
  }
}

void main() {
  void run(void Function(FakeAsync async, _Rig rig) body, {int seed = 1}) => fakeAsync((async) {
        final rig = _Rig(async, seed: seed);
        rig.engine.async = async;
        async.flushMicrotasks();
        body(async, rig);
        rig.scheduler.dispose();
        async.flushMicrotasks();
      });

  test('first event 45-120 s after the start, then a gap of 120-300 s each time', () {
    for (final seed in [1, 2, 3, 4]) {
      run(seed: seed, (async, rig) {
        rig.scheduler.start([_thunder()]);
        async.elapse(const Duration(hours: 3));
        // Without `orage`, an event starts with its flash; its variant follows.
        final starts = [for (final (at, _) in rig.strikes) at];
        expect(starts.length, greaterThan(30));
        expect(starts.first.inMilliseconds / 1000, inInclusiveRange(45, 120));
        for (var i = 1; i < starts.length; i++) {
          final gap = (starts[i] - starts[i - 1]).inMilliseconds / 1000;
          expect(gap, inInclusiveRange(120, 300), reason: 'event $i');
        }
        expect(rig.plans.every((p) => p.$2.kind == StormKind.single), isTrue);
      });
    }
  });

  test('a variant is never one of the last two played; variations stay in range', () {
    run((async, rig) {
      rig.scheduler.start([_thunder()]);
      async.elapse(const Duration(hours: 6));
      final events = rig.engine.events;
      expect(events.length, greaterThan(60));
      final ids = [for (final e in events) (e.source as AssetAudioSource).assetKey];
      for (var i = 0; i < ids.length; i++) {
        if (i >= 1) expect(ids[i], isNot(ids[i - 1]), reason: 'event $i');
        if (i >= 2) expect(ids[i], isNot(ids[i - 2]), reason: 'event $i');
      }
      expect(ids.toSet().length, 10, reason: 'every variant comes up');
      for (final e in events) {
        expect(e.key, 'son:tonnerre');
        expect(e.volume, 0.6, reason: 'the level of the sound');
        expect(e.gain, inInclusiveRange(pow(10, -6 / 20), 1.0));
        expect(e.speed, inInclusiveRange(0.92, 1.08));
        expect(e.pan, inInclusiveRange(-0.4, 0.4));
      }
      // Not always the same variation.
      expect(events.map((e) => e.speed).toSet().length, events.length);
    });
  });

  test('with three variants, the next one is always the remaining one', () {
    run((async, rig) {
      rig.scheduler.start([_thunder(variants: 3)]);
      async.elapse(const Duration(hours: 2));
      final ids = [for (final e in rig.engine.events) (e.source as AssetAudioSource).assetKey];
      expect(ids.length, greaterThan(10));
      for (var i = 3; i < ids.length; i++) {
        expect(ids[i], ids[i - 3], reason: 'event $i');
      }
    });
  });

  test('a flash 0.4-3.5 s before each thunder, brighter when closer', () {
    run((async, rig) {
      rig.scheduler.start([_thunder()]);
      async.elapse(const Duration(hours: 1));
      // (The last flash may wait for its thunder past the end of the hour.)
      expect(rig.strikes.length - rig.starts.length, inInclusiveRange(0, 1));
      expect(rig.starts.length, greaterThan(8));
      for (var i = 0; i < rig.starts.length; i++) {
        final (at, strike) = rig.strikes[i];
        final lead = rig.starts[i] - at;
        expect(lead, strike.thunderDelay, reason: 'the thunder follows its flash');
        expect(strike.thunderDelay.inMilliseconds, inInclusiveRange(400, 3500));
        expect(strike.intensity, closeTo(StormRules.intensityFor(strike.thunderDelay), 1e-9));
      }
    });
  });

  test('never two events at the same time: the next one waits for the end of a long one', () {
    run((async, rig) {
      rig.engine.eventLength = const Duration(seconds: 400); // longer than the longest gap
      rig.scheduler.start([_thunder()]);
      async.elapse(const Duration(hours: 3));
      final events = rig.engine.events;
      expect(events.length, greaterThan(5));
      for (var i = 1; i < events.length; i++) {
        final end = rig.starts[i - 1] + events[i - 1].duration;
        expect(rig.starts[i] >= end, isTrue, reason: 'event $i starts before the end of event ${i - 1}');
      }
    });
  });

  test('nothing during a pause; a resume draws a new first delay', () {
    run((async, rig) {
      rig.scheduler.start([_thunder()]);
      async.elapse(const Duration(seconds: 40)); // before the earliest first event
      rig.scheduler.pause();
      rig.engine.pause();
      async.elapse(const Duration(hours: 1));
      expect(rig.engine.events, isEmpty);
      expect(rig.strikes, isEmpty);
      rig.engine.resume();
      final resumed = async.elapsed;
      rig.scheduler.resume();
      async.elapse(const Duration(minutes: 3));
      expect(rig.starts, isNotEmpty);
      expect((rig.starts.first - resumed).inMilliseconds / 1000, inInclusiveRange(45, 120));
    });
  });

  test('a pause during the flash delay cancels the thunder', () {
    run((async, rig) {
      rig.scheduler.start([_thunder()]);
      while (rig.strikes.isEmpty) {
        async.elapse(const Duration(milliseconds: 100));
      }
      rig.scheduler.pause();
      async.elapse(const Duration(seconds: 10));
      expect(rig.engine.events, isEmpty);
    });
  });

  test('level 0 (removed or muted): no event, the one sounding fades out; back above 0: a new first delay', () {
    run((async, rig) {
      rig.scheduler.start([_thunder()]);
      async.elapse(const Duration(seconds: 125)); // the first event has sounded
      expect(rig.engine.events, hasLength(1));
      rig.scheduler.update([_thunder(volume: 0)]);
      expect(rig.engine.calls, contains('eventVolume:son:tonnerre:0.00'));
      async.elapse(const Duration(hours: 1));
      expect(rig.engine.events, hasLength(1));
      final back = async.elapsed;
      rig.scheduler.update([_thunder(volume: 0.3)]);
      async.elapse(const Duration(minutes: 3));
      expect(rig.engine.events, hasLength(2));
      expect((rig.starts.last - back).inMilliseconds / 1000, inInclusiveRange(45, 120));
      expect(rig.engine.events.last.volume, 0.3);
    });
  });

  test('a level change applies to the event sounding and to the next ones', () {
    run((async, rig) {
      rig.scheduler.start([_thunder()]);
      async.elapse(const Duration(seconds: 125));
      final next = rig.scheduler.nextEventOf('son:tonnerre');
      rig.scheduler.update([_thunder(volume: 0.9)]);
      expect(rig.engine.calls, contains('eventVolume:son:tonnerre:0.90'));
      expect(rig.scheduler.nextEventOf('son:tonnerre'), next, reason: 'the schedule is kept');
      async.elapse(const Duration(minutes: 6));
      expect(rig.engine.events.last.volume, 0.9);
    });
  });

  test('removed from the mix: stopped; stop() ends everything', () {
    run((async, rig) {
      rig.scheduler.start([_thunder()]);
      async.elapse(const Duration(seconds: 30));
      rig.scheduler.update(const []);
      expect(rig.engine.calls, contains('eventVolume:son:tonnerre:0.00'));
      async.elapse(const Duration(hours: 1));
      expect(rig.engine.events, isEmpty);
      rig.scheduler.update([_thunder()]);
      async.elapse(const Duration(minutes: 2, seconds: 1));
      expect(rig.engine.events, hasLength(1));
      rig.scheduler.stop();
      expect(rig.scheduler.running, isFalse);
      async.elapse(const Duration(hours: 1));
      expect(rig.engine.events, hasLength(1));
    });
  });

  test('a variant that cannot be had is skipped; the next event is still planned', () {
    run((async, rig) {
      final layer = EventLayer(
        key: 'son:tonnerre',
        variants: [
          for (var i = 1; i <= 4; i++)
            EventVariant('tonnerre-$i', () => Future<AudioSourceRef>.error(StateError('offline'))),
        ],
        volume: 0.6,
      );
      rig.scheduler.start([layer]);
      async.elapse(const Duration(hours: 1));
      expect(rig.engine.events, isEmpty);
      expect(rig.strikes, isEmpty, reason: 'no flash without its thunder');
      expect(rig.plans.length, greaterThan(5), reason: 'events keep being planned');
    });
  });

  test('a mix change while paused waits for the resume', () {
    run((async, rig) {
      rig.scheduler.start(const []);
      rig.scheduler.pause();
      rig.scheduler.update([_thunder()]);
      async.elapse(const Duration(hours: 1));
      expect(rig.strikes, isEmpty);
      rig.scheduler.resume();
      async.elapse(const Duration(minutes: 2, seconds: 1));
      expect(rig.engine.events, hasLength(1));
    });
  });

  group('storm sequences (catalog `orage`)', () {
    const weights = {StormKind.lointain: 25.0, StormKind.orage: 55.0, StormKind.proche: 20.0};
    List<EventVariant> part(String name, int n, {Future<AudioSourceRef> Function(String id)? resolve}) => [
          for (var i = 1; i <= n; i++)
            EventVariant(
              'tonnerre-$name-0$i',
              () => resolve?.call('tonnerre-$name-0$i') ??
                  Future.value(AssetAudioSource('assets/audio/sons/tonnerre-$name-0$i.ogg')),
            ),
        ];
    Map<StormPart, List<EventVariant>> allParts() => {
          StormPart.avant: part('avant', 3),
          StormPart.coup: part('coup', 4),
          StormPart.coupProche: part('proche', 3),
          StormPart.replique: part('replique', 3),
          StormPart.lointain: part('lointain', 4),
        };
    EventLayer storm({
      double volume = 0.6,
      Map<StormKind, double> w = weights,
      List<String> averse = const ['son:pluie-douce'],
      List<String> rafale = const ['son:vent'],
      Map<StormPart, List<EventVariant>>? parts,
    }) {
      final p = parts ?? allParts();
      return EventLayer(
        key: 'son:tonnerre',
        variants: [for (final l in p.values) ...l],
        volume: volume,
        interval: const SecondsRange(70, 170),
        firstDelay: const SecondsRange(20, 60),
        storm: StormLayer(parts: p, weights: w, averseKeys: averse, rafaleKeys: rafale),
      );
    }

    String idOf(FakeEvent e) => (e.source as AssetAudioSource).assetKey.split('/').last.replaceAll('.ogg', '');
    double s(Duration d) => d.inMicroseconds / 1e6;

    /// Every sound played: (time, variant id, event).
    List<(Duration, String, FakeEvent)> played(_Rig rig) => [
          for (var i = 0; i < rig.engine.events.length; i++) (rig.starts[i], idOf(rig.engine.events[i]), rig.engine.events[i]),
        ];

    /// What happened during the event [i] of the rig: from its start to the next one.
    ({Duration start, StormPlan plan, List<(Duration, String, FakeEvent)> sounds, List<(Duration, LightningStrike)> flashes})
        event(_Rig rig, int i) {
      final (start, plan) = rig.plans[i];
      final end = i + 1 < rig.plans.length ? rig.plans[i + 1].$1 : const Duration(days: 365);
      return (
        start: start,
        plan: plan,
        sounds: [for (final x in played(rig)) if (x.$1 >= start && x.$1 < end) x],
        flashes: [for (final f in rig.strikes) if (f.$1 >= start && f.$1 < end) f],
      );
    }

    test('kinds drawn by their weights; first event 20-60 s, then 70-170 s; never two at once', () {
      run((async, rig) {
        rig.scheduler.start([storm()]);
        async.elapse(const Duration(hours: 24));
        final plans = rig.plans;
        expect(plans.length, greaterThan(500));
        expect(s(plans.first.$1), inInclusiveRange(20, 60));
        for (final e in weights.entries) {
          final share = plans.where((p) => p.$2.kind == e.key).length / plans.length;
          expect(share, closeTo(e.value / 100, 0.05), reason: e.key.key);
        }
        for (var i = 1; i < plans.length; i++) {
          final prev = event(rig, i - 1);
          final start = plans[i].$1;
          expect(s(start - prev.start), inInclusiveRange(70, 170), reason: 'event $i');
          for (final (at, _, e) in prev.sounds) {
            expect(start >= at + e.duration + const Duration(seconds: 1), isTrue,
                reason: 'event $i starts before the end of the previous one');
          }
        }
      });
    });

    test('orage: a soft pre-rumble, then the flash, then the strike after the distance delay', () {
      run((async, rig) {
        rig.scheduler.start([storm()]);
        async.elapse(const Duration(hours: 12));
        var seen = 0, aftershocks = 0;
        for (var i = 0; i < rig.plans.length - 1; i++) {
          final e = event(rig, i);
          if (e.plan.kind != StormKind.orage) continue;
          seen++;
          expect(e.sounds.first.$1, e.start, reason: 'the pre-rumble opens the event');
          expect(e.sounds.first.$2, startsWith('tonnerre-avant-'));
          final (flashAt, flash) = e.flashes.first;
          expect(s(flashAt - e.start), inInclusiveRange(2.5, 5.5));
          expect(s(flash.thunderDelay), inInclusiveRange(1.2, 3.5));
          expect(flash.intensity, closeTo(StormRules.intensityFor(flash.thunderDelay), 1e-9));
          final strike = e.sounds[1];
          expect(strike.$2, startsWith('tonnerre-coup-'));
          expect(strike.$1, flashAt + flash.thunderDelay, reason: 'the crack follows its flash');
          final after = [for (final x in e.sounds) if (x.$2.startsWith('tonnerre-replique-')) x];
          if (after.isNotEmpty) {
            aftershocks++;
            expect(s(after.single.$1 - strike.$1), inInclusiveRange(8, 20));
          }
          expect(e.sounds.length, 2 + after.length);
        }
        expect(seen, greaterThan(100));
        expect(aftershocks / seen, closeTo(StormRules.stormAftershock, 0.12));
      });
    });

    test('proche: the flash first, the close crack 0.4-1.2 s later, an aftershock 5-20 s after it', () {
      run((async, rig) {
        rig.scheduler.start([storm(w: const {StormKind.proche: 1})]);
        async.elapse(const Duration(hours: 6));
        var faint = 0;
        expect(rig.plans.length, greaterThan(100));
        for (var i = 0; i < rig.plans.length - 1; i++) {
          final e = event(rig, i);
          final (flashAt, flash) = e.flashes.first;
          expect(flashAt, e.start, reason: 'the flash opens a close strike');
          expect(s(flash.thunderDelay), inInclusiveRange(0.4, 1.2));
          expect(flash.intensity, inInclusiveRange(0.83, 1.0));
          final [strike, after] = e.sounds;
          expect(strike.$2, startsWith('tonnerre-proche-'));
          expect(strike.$1, flashAt + flash.thunderDelay);
          expect(after.$2, startsWith('tonnerre-replique-'));
          expect(s(after.$1 - strike.$1), inInclusiveRange(5, 20), reason: 'the aftershock window');
          if (e.flashes.length == 2) {
            faint++;
            final (at, f) = e.flashes[1];
            expect(at + f.thunderDelay, after.$1, reason: 'the faint flash announces the aftershock');
            expect(s(f.thunderDelay), lessThanOrEqualTo(3.5));
            expect(s(at - flashAt), greaterThanOrEqualTo(3), reason: 'never a strobe');
            expect(f.intensity, inInclusiveRange(0.15, 0.3));
          } else {
            expect(e.flashes, hasLength(1));
          }
        }
        expect(faint / (rig.plans.length - 1), closeTo(0.5, 0.12));
      });
    });

    test('lointain: a distant rumble alone, no flash 6 times in 10, else a faint one 3.5-6 s before', () {
      run((async, rig) {
        rig.scheduler.start([storm(w: const {StormKind.lointain: 1})]);
        async.elapse(const Duration(hours: 6));
        var dark = 0;
        for (var i = 0; i < rig.plans.length - 1; i++) {
          final e = event(rig, i);
          final rumble = e.sounds.single;
          expect(rumble.$2, startsWith('tonnerre-lointain-'));
          if (e.flashes.isEmpty) {
            dark++;
            expect(rumble.$1, e.start);
          } else {
            final (at, f) = e.flashes.single;
            expect(at, e.start);
            expect(rumble.$1, at + f.thunderDelay);
            expect(s(f.thunderDelay), inInclusiveRange(3.5, 6));
            expect(f.intensity, inInclusiveRange(0.12, 0.25));
          }
        }
        expect(dark / (rig.plans.length - 1), closeTo(0.6, 0.12));
        expect(rig.engine.swells, isEmpty, reason: 'no strike, no swell');
      });
    });

    test('after each strike the rain redoubles and the wind gusts, within their bounds', () {
      run((async, rig) {
        rig.scheduler.start([storm()]);
        async.elapse(const Duration(hours: 12));
        final strikes = [
          for (final x in played(rig))
            if (x.$2.startsWith('tonnerre-coup-') || x.$2.startsWith('tonnerre-proche-')) x.$1,
        ];
        final swells = rig.engine.swells;
        final rain = [for (var i = 0; i < swells.length; i++) if (swells[i].keys.contains('son:pluie-douce')) i];
        final wind = [for (var i = 0; i < swells.length; i++) if (swells[i].keys.contains('son:vent')) i];
        expect(strikes.length, greaterThan(100));
        expect(rain, hasLength(strikes.length));
        expect(wind, hasLength(strikes.length));
        for (final sw in swells) {
          expect(sw.gainDb, inInclusiveRange(StormRules.minSwellDb, StormRules.maxSwellDb));
        }
        Duration lastStrikeBefore(Duration t) => strikes.lastWhere((x) => x <= t);
        for (final i in rain) {
          final sw = swells[i];
          final at = rig.engine.swellTimes[i];
          expect(sw.keys, ['son:pluie-douce']);
          expect(s(at - lastStrikeBefore(at)), inInclusiveRange(0.8, 2.5));
          expect(s(sw.rise), inInclusiveRange(2.5, 4));
          expect(s(sw.hold), inInclusiveRange(2, 5));
          expect(s(sw.fall), inInclusiveRange(6, 10));
        }
        for (final i in wind) {
          final sw = swells[i];
          final at = rig.engine.swellTimes[i];
          expect(sw.keys, ['son:vent']);
          expect(s(at - lastStrikeBefore(at)), inInclusiveRange(0.3, 1.5));
          expect(s(sw.rise), inInclusiveRange(0.8, 1.5));
          expect(s(sw.hold), inInclusiveRange(0.3, 1));
          expect(s(sw.fall), inInclusiveRange(3, 5));
        }
      });
    });

    test('no swell without rain or wind in the mix', () {
      run((async, rig) {
        rig.scheduler.start([storm(averse: const [], rafale: const [])]);
        async.elapse(const Duration(hours: 3));
        expect(rig.engine.events, isNotEmpty);
        expect(rig.engine.swells, isEmpty);
      });
    });

    test('a part never repeats one of its two last; pieces vary in gain, speed and position', () {
      run((async, rig) {
        rig.scheduler.start([storm()]);
        async.elapse(const Duration(hours: 24));
        final byPart = <String, List<String>>{};
        for (final (_, id, e) in played(rig)) {
          byPart.putIfAbsent(id.substring(0, id.lastIndexOf('-')), () => []).add(id);
          expect(e.gain, inInclusiveRange(pow(10, -3 / 20), 1.0));
          expect(e.speed, inInclusiveRange(0.92, 1.08));
          expect(e.pan, inInclusiveRange(-0.4, 0.4));
        }
        expect(byPart.keys.toSet(), {
          'tonnerre-avant',
          'tonnerre-coup',
          'tonnerre-proche',
          'tonnerre-replique',
          'tonnerre-lointain',
        });
        for (final ids in byPart.values) {
          for (var i = 2; i < ids.length; i++) {
            expect(ids[i], isNot(ids[i - 1]));
            expect(ids[i], isNot(ids[i - 2]));
          }
        }
        // The parts of one event come from one direction (± 0.15 around the event's position).
        for (var i = 0; i < rig.plans.length - 1; i++) {
          final pans = [for (final x in event(rig, i).sounds) x.$3.pan];
          if (pans.length > 1) expect(pans.reduce(max) - pans.reduce(min), lessThanOrEqualTo(0.3 + 1e-9));
        }
      });
    });

    test('a pause in the middle of a storm drops the rest; a resume draws a new first delay', () {
      run((async, rig) {
        rig.scheduler.start([storm(w: const {StormKind.orage: 1})]);
        while (rig.engine.events.isEmpty) {
          async.elapse(const Duration(milliseconds: 100));
        }
        // The pre-rumble sounds; the flash, the strike and the swells are still to come.
        rig.scheduler.pause();
        rig.engine.pause();
        async.elapse(const Duration(hours: 1));
        expect(rig.engine.events, hasLength(1));
        expect(rig.strikes, isEmpty);
        expect(rig.engine.swells, isEmpty);
        rig.engine.resume();
        final resumed = async.elapsed;
        rig.scheduler.resume();
        async.elapse(const Duration(minutes: 2));
        expect(s(rig.plans[1].$1 - resumed), inInclusiveRange(20, 60));
      });
    });

    test('level 0 or mute in the middle of a storm: the aftershock is dropped, the sounding part fades out', () {
      run((async, rig) {
        rig.scheduler.start([storm(w: const {StormKind.proche: 1})]);
        while (rig.engine.events.isEmpty) {
          async.elapse(const Duration(milliseconds: 100));
        }
        expect(idOf(rig.engine.events.single), startsWith('tonnerre-proche-'));
        rig.scheduler.update([storm(volume: 0, w: const {StormKind.proche: 1})]);
        expect(rig.engine.calls, contains('eventVolume:son:tonnerre:0.00'));
        async.elapse(const Duration(hours: 1));
        expect(rig.engine.events, hasLength(1), reason: 'no aftershock, no new event');
        expect(rig.plans, hasLength(1));
        final back = async.elapsed;
        rig.scheduler.update([storm(w: const {StormKind.proche: 1})]);
        async.elapse(const Duration(minutes: 2));
        expect(s(rig.plans[1].$1 - back), inInclusiveRange(20, 60));
      });
    });

    test('a strike whose file cannot be had: neither its flash nor the strike nor a swell; the rest goes on', () {
      run((async, rig) {
        final parts = allParts()
          ..[StormPart.coup] = part('coup', 4, resolve: (id) => Future<AudioSourceRef>.error(StateError('offline')));
        rig.scheduler.start([storm(w: const {StormKind.orage: 1}, parts: parts)]);
        async.elapse(const Duration(hours: 2));
        expect(rig.plans.length, greaterThan(20));
        final ids = [for (final x in played(rig)) x.$2];
        expect(ids.where((id) => id.startsWith('tonnerre-coup-')), isEmpty);
        expect(ids.where((id) => id.startsWith('tonnerre-avant-')), hasLength(rig.plans.length),
            reason: 'the pre-rumble still plays');
        expect(rig.strikes.where((f) => f.$2.intensity > 0.3), isEmpty, reason: 'no flash without its strike');
        expect(rig.engine.swells, isEmpty);
      });
    });

    test('the flash waits for a slow file: the crack still follows after the drawn delay', () {
      run((async, rig) {
        final parts = allParts()
          ..remove(StormPart.avant)
          ..[StormPart.coup] = part('coup', 4,
              resolve: (id) => Future.delayed(const Duration(seconds: 2), () => AssetAudioSource('assets/audio/sons/$id.ogg')));
        rig.scheduler.start([storm(w: const {StormKind.orage: 1}, parts: parts)]);
        async.elapse(const Duration(hours: 1));
        expect(rig.plans.length, greaterThan(10));
        for (var i = 0; i < rig.plans.length - 1; i++) {
          final e = event(rig, i);
          final (flashAt, flash) = e.flashes.first;
          expect(flashAt - e.start, const Duration(seconds: 2), reason: 'the flash waited for the file');
          expect(e.sounds.first.$1, flashAt + flash.thunderDelay);
        }
      });
    });

    test('no kind can be drawn (no strike nor distant part): one variant per event', () {
      run((async, rig) {
        final parts = {StormPart.replique: part('replique', 3)};
        rig.scheduler.start([storm(parts: parts)]);
        async.elapse(const Duration(hours: 1));
        expect(rig.plans, isNotEmpty);
        expect(rig.plans.every((p) => p.$2.kind == StormKind.single), isTrue);
        expect(rig.engine.events, isNotEmpty);
      });
    });
  });
}
