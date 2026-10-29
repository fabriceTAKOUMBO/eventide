// SoLoudAudioEngine against a recording fake of SoLoud: the mute (parking) and the
// progressive entry of the music, without a real audio device.
import 'dart:math';

import 'package:eventide/services/audio/audio_engine.dart';
import 'package:eventide/services/audio/soloud_audio_engine.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:flutter_test/flutter_test.dart';

class _Voice {
  _Voice(this.source, {required this.volume, required this.paused, this.looping = false, this.pan = 0});

  final String source;
  double volume;
  bool paused;
  final bool looping;
  final double pan;
  double speed = 1;

  /// Every fade asked for this voice: (target, duration).
  final List<(double, Duration)> fades = [];

  (double, Duration)? get lastFade => fades.isEmpty ? null : fades.last;
}

/// Records what the engine asks of SoLoud. A fade jumps to its target at once (its
/// duration is what the tests check).
class _FakeSoLoud implements SoLoud {
  int _nextHandle = 1;
  int _nextHash = 1;
  final Map<int, _Voice> voices = {};
  double global = 1;
  Duration? globalFade;

  _Voice voice(String source) =>
      voices.values.singleWhere((v) => v.source == source);

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final args = invocation.positionalArguments;
    final named = invocation.namedArguments;
    switch (invocation.memberName) {
      case #isInitialized:
        return true;
      case #loadAsset:
      case #loadFile:
        return Future<AudioSource>.value(
          // ignore: invalid_use_of_internal_member
          AudioSource(SoundHash(_nextHash++), soundPath: args[0] as String),
        );
      case #play:
        final handle = SoundHandle(_nextHandle++);
        voices[handle.id] = _Voice(
          (args[0] as AudioSource).soundPath,
          volume: (named[#volume] as double?) ?? 1,
          paused: (named[#paused] as bool?) ?? false,
          looping: (named[#looping] as bool?) ?? false,
          pan: (named[#pan] as double?) ?? 0,
        );
        return handle;
      case #setRelativePlaySpeed:
        voices[(args[0] as SoundHandle).id]?.speed = args[1] as double;
        return null;
      case #getLength:
        return const Duration(seconds: 30);
      case #seek:
      case #setProtectVoice:
        return null;
      case #setPause:
        voices[(args[0] as SoundHandle).id]?.paused = args[1] as bool;
        return null;
      case #setVolume:
        voices[(args[0] as SoundHandle).id]?.volume = args[1] as double;
        return null;
      case #fadeVolume:
        final v = voices[(args[0] as SoundHandle).id];
        v?.fades.add((args[1] as double, args[2] as Duration));
        v?.volume = args[1] as double;
        return null;
      case #setGlobalVolume:
        global = args[0] as double;
        return null;
      case #fadeGlobalVolume:
        global = args[0] as double;
        globalFade = args[1] as Duration;
        return null;
      case #stop:
        voices.remove((args[0] as SoundHandle).id);
        return Future<void>.value();
      case #disposeSource:
        return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

const _rain = AssetAudioSource('assets/audio/sons/pluie-douce.ogg');
const _piano = AssetAudioSource('assets/audio/musiques/piano-doux.ogg');

EngineLayer _sound(double volume) =>
    EngineLayer(key: 'son:pluie-douce', source: _rain, volume: volume);

EngineLayer _music(double volume, {Duration? fadeIn}) => EngineLayer(
  key: 'musique:piano-doux',
  source: _piano,
  volume: volume,
  fadeIn: fadeIn,
  resumeFade: MixRules.musicResume,
);

void main() {
  late _FakeSoLoud soloud;
  late SoLoudAudioEngine engine;

  /// The engine is made inside the fake zone: its operation queue must run on fake time.
  void fake(void Function(FakeAsync async) body) => fakeAsync((async) {
    soloud = _FakeSoLoud();
    engine = SoLoudAudioEngine(soloud: soloud, random: Random(3));
    body(async);
    engine.stop();
    async.flushMicrotasks();
  });

  _Voice rain() => soloud.voice(_rain.assetKey);
  _Voice piano() => soloud.voice(_piano.assetKey);

  test(
    'a start from silence: the sounds in 2 s, the melody over its 20 s entry',
    () {
      fake((async) {
        engine.start([_sound(0.6), _music(0.16, fadeIn: MixRules.musicEntry)]);
        async.flushMicrotasks();
        expect(rain().paused, isFalse);
        expect(rain().lastFade, (0.6, const Duration(seconds: 2)));
        expect(piano().paused, isFalse);
        expect(piano().lastFade, (0.16, MixRules.musicEntry));
        expect(soloud.global, MixRules.masterCap);
      });
    },
  );

  test('a scheduled ramp-up and the melody entry both apply (master × voice, no overshoot)', () {
    fake((async) {
      engine.start([
        _sound(0.6),
        _music(0.16, fadeIn: MixRules.musicEntry),
      ], rampUp: const Duration(minutes: 10));
      async.flushMicrotasks();
      expect(soloud.globalFade, const Duration(minutes: 10));
      expect(soloud.global, MixRules.masterCap);
      expect(piano().lastFade, (0.16, MixRules.musicEntry));
    });
  });

  test('muting fades the voice out, then parks it (paused: no decoding); unmuting fades it back', () {
    fake((async) {
      engine.start([_sound(0.6), _music(0.16)]);
      async.flushMicrotasks();
      engine.update([_sound(0.6), _music(0)], fade: MixRules.muteFade);
      async.flushMicrotasks();
      expect(piano().lastFade, (0.0, MixRules.muteFade));
      expect(piano().paused, isFalse, reason: 'still fading out');
      async.elapse(MixRules.muteFade + const Duration(milliseconds: 60));
      expect(piano().paused, isTrue, reason: 'parked after the fade');
      expect(rain().paused, isFalse);
      expect(engine.isPlaying, isTrue);

      engine.update([_sound(0.6), _music(0.16)], fade: MixRules.muteFade);
      async.flushMicrotasks();
      expect(piano().paused, isFalse);
      expect(piano().lastFade, (
        0.16,
        MixRules.muteFade,
      ), reason: 'not the 20 s entry');
    });
  });

  test('unmuted before the end of the fade: never parked', () {
    fake((async) {
      engine.start([_sound(0.6), _music(0.16)]);
      async.flushMicrotasks();
      engine.update([_sound(0.6), _music(0)], fade: MixRules.muteFade);
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 300));
      engine.update([_sound(0.6), _music(0.16)], fade: MixRules.muteFade);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 2));
      expect(piano().paused, isFalse);
      expect(piano().volume, 0.16);
    });
  });

  test(
    'a layer muted from the start is loaded but stays parked until heard',
    () {
      fake((async) {
        engine.start([_sound(0.6), _music(0, fadeIn: MixRules.musicEntry)]);
        async.flushMicrotasks();
        expect(piano().paused, isTrue);
        expect(piano().fades, isEmpty);
        expect(engine.activeKeys, contains('musique:piano-doux'));
        engine.update([_sound(0.6), _music(0.16)], fade: MixRules.muteFade);
        async.flushMicrotasks();
        expect(piano().paused, isFalse);
        expect(piano().lastFade, (0.16, MixRules.muteFade));
      });
    },
  );

  test('everything muted: every voice parked, the session stays loaded', () {
    fake((async) {
      engine.start([_sound(0.6), _music(0.16)]);
      async.flushMicrotasks();
      engine.update([_sound(0), _music(0)], fade: MixRules.muteFade);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 2));
      expect(rain().paused, isTrue);
      expect(piano().paused, isTrue);
      expect(
        engine.isPlaying,
        isTrue,
        reason: 'muting is not pausing: timer and video go on',
      );
      expect(engine.isPaused, isFalse);
    });
  });

  test('resume after a pause: the music comes back over 3 s, a parked voice stays parked', () {
    fake((async) {
      engine.start([_sound(0.6), _music(0.16)]);
      async.flushMicrotasks();
      engine.pause();
      async.flushMicrotasks();
      async.elapse(MixRules.pauseFade);
      expect(rain().paused, isTrue);
      expect(piano().paused, isTrue);
      engine.resume();
      async.flushMicrotasks();
      expect(rain().paused, isFalse);
      expect(piano().paused, isFalse);
      expect(piano().lastFade, (0.16, MixRules.musicResume));
      expect(soloud.globalFade, MixRules.pauseFade);

      // Muted music during a pause: the resume does not wake it.
      engine.update([_sound(0.6), _music(0)], fade: MixRules.muteFade);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 2));
      engine.pause();
      async.flushMicrotasks();
      async.elapse(MixRules.pauseFade);
      engine.resume();
      async.flushMicrotasks();
      expect(rain().paused, isFalse);
      expect(piano().paused, isTrue);
    });
  });

  test(
    'a new melody during a cross-fade enters over 20 s; an added one over 1 s',
    () {
      fake((async) {
        engine.start([_sound(0.6)]);
        async.flushMicrotasks();
        engine.update([
          _sound(0.5),
          _music(0.16, fadeIn: MixRules.musicEntry),
        ], fade: MixRules.crossFade);
        async.flushMicrotasks();
        expect(piano().lastFade, (0.16, MixRules.musicEntry));
        expect(rain().lastFade, (0.5, MixRules.crossFade));
        engine.update([_sound(0.5)], fade: MixRules.levelFade);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 1));
        engine.update([_sound(0.5), _music(0.24)], fade: MixRules.levelFade);
        async.flushMicrotasks();
        expect(piano().lastFade, (0.24, MixRules.newLayerFade));
      });
    },
  );

  group('events (sounds played by events, contract § 11)', () {
    const thunder = AssetAudioSource('assets/audio/sons/tonnerre-03.ogg');

    _Voice event() => soloud.voice(thunder.assetKey);

    test('an event plays once over the loops, with its gain, speed and pan', () {
      fake((async) {
        engine.start([_sound(0.6)]);
        async.flushMicrotasks();
        Duration? length;
        engine.playEvent('son:tonnerre', thunder, volume: 0.5, gain: 0.8, speed: 1.05, pan: -0.3).then((d) => length = d);
        async.flushMicrotasks();
        expect(event().looping, isFalse);
        expect(event().volume, closeTo(0.4, 1e-9));
        expect(event().pan, -0.3);
        expect(event().speed, 1.05);
        expect(length!.inMilliseconds, (30000 / 1.05).round());
        expect(rain().paused, isFalse, reason: 'the loops go on');
        // Over: its voice is stopped and its file released.
        async.elapse(length! + const Duration(seconds: 1));
        expect(soloud.voices.values.where((v) => v.source == thunder.assetKey), isEmpty);
      });
    });

    test('nothing while paused or stopped; a pause ends the event sounding', () {
      fake((async) {
        Duration? length = Duration.zero;
        engine.playEvent('son:tonnerre', thunder, volume: 0.5).then((d) => length = d);
        async.flushMicrotasks();
        expect(length, isNull, reason: 'no session');
        engine.start([_sound(0.6)]);
        async.flushMicrotasks();
        engine.playEvent('son:tonnerre', thunder, volume: 0.5);
        async.flushMicrotasks();
        expect(soloud.voices.values.where((v) => v.source == thunder.assetKey), hasLength(1));
        engine.pause();
        async.elapse(MixRules.pauseFade + const Duration(milliseconds: 50));
        expect(soloud.voices.values.where((v) => v.source == thunder.assetKey), isEmpty);
        length = Duration.zero;
        engine.playEvent('son:tonnerre', thunder, volume: 0.5).then((d) => length = d);
        async.flushMicrotasks();
        expect(length, isNull, reason: 'paused');
      });
    });

    test('level change and mute: the event sounding follows, then stops at 0', () {
      fake((async) {
        engine.start([_sound(0.6)]);
        async.flushMicrotasks();
        engine.playEvent('son:tonnerre', thunder, volume: 0.5, gain: 0.5);
        async.flushMicrotasks();
        engine.setEventVolume('son:tonnerre', 0.8);
        async.flushMicrotasks();
        expect(event().lastFade, (0.4, MixRules.levelFade), reason: 'its own gain is kept');
        engine.setEventVolume('son:tonnerre', 0, fade: MixRules.muteFade);
        async.flushMicrotasks();
        expect(event().lastFade, (0.0, MixRules.muteFade));
        async.elapse(MixRules.muteFade + const Duration(milliseconds: 100));
        expect(soloud.voices.values.where((v) => v.source == thunder.assetKey), isEmpty);
      });
    });

    test('stop ends the events with the loops', () {
      fake((async) {
        engine.start([_sound(0.6)]);
        async.flushMicrotasks();
        engine.playEvent('son:tonnerre', thunder, volume: 0.5);
        async.flushMicrotasks();
        engine.stop();
        async.flushMicrotasks();
        expect(soloud.voices, isEmpty);
      });
    });
  });
}
