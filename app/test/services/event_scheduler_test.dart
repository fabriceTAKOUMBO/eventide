// EventSoundScheduler (contract § 11) on fake time and a seeded random: first delay, gaps,
// never one of the last two variants, random variations in range, no overlap, pause/resume,
// level 0 and mute, the flash before each thunder.
import 'dart:math';

import 'package:eventide/core/catalog.dart';
import 'package:eventide/core/lightning.dart';
import 'package:eventide/services/audio/audio_engine.dart';
import 'package:eventide/services/audio/event_scheduler.dart';
import 'package:eventide/services/audio/fake_audio_engine.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

const _carrier = EngineLayer(key: 'son:pluie-douce', source: AssetAudioSource('assets/audio/sons/pluie-douce.ogg'), volume: 0.5);

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
    engine.start(const [_carrier]);
  }

  final FakeAsync async;
  final DateTime t0 = DateTime(2026, 10, 29, 22);
  final engine = _TimedEngine();
  late final EventSoundScheduler scheduler;
  final List<(Duration, LightningStrike)> strikes = [];

  List<Duration> get starts => engine.times;
}

class _TimedEngine extends FakeAudioEngine {
  late FakeAsync async;
  final List<Duration> times = [];

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
        final starts = rig.starts;
        expect(starts.length, greaterThan(30));
        expect(starts.first.inMilliseconds / 1000, inInclusiveRange(45, 120));
        for (var i = 1; i < starts.length; i++) {
          final gap = (starts[i] - starts[i - 1]).inMilliseconds / 1000;
          expect(gap, inInclusiveRange(120, 300), reason: 'event $i');
        }
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
      expect(rig.strikes.length, greaterThan(5), reason: 'events keep being planned');
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
}
