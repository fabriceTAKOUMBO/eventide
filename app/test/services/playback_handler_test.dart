import 'package:audio_service/audio_service.dart';
import 'package:eventide/core/scene.dart';
import 'package:eventide/services/audio/audio_engine.dart';
import 'package:eventide/services/audio/audio_focus.dart';
import 'package:eventide/services/audio/fake_audio_engine.dart';
import 'package:eventide/services/audio/playback_handler.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

class _Host implements PlaybackHost {
  PlayRequest? next;
  final List<String?> requested = [];
  final List<(StopReason, Duration)> stops = [];
  final List<PlayRequest> started = [];

  @override
  Future<PlayRequest?> requestPlay({String? scheduleId}) async {
    requested.add(scheduleId);
    return next;
  }

  @override
  void onPlaybackStarted(PlayRequest request) => started.add(request);

  @override
  void onPlaybackStopped(StopReason reason, Duration listened) => stops.add((reason, listened));
}

/// No audio device (headless emulator, broken audio HAL): the engine cannot start.
class _NoDeviceEngine extends FakeAudioEngine {
  int attempts = 0;

  @override
  Future<void> start(
    List<EngineLayer> layers, {
    Duration fadeIn = const Duration(seconds: 2),
    Duration rampUp = Duration.zero,
  }) async {
    attempts++;
    throw StateError('audio device unavailable');
  }
}

PlayRequest _request({
  TimerSetting timer = const TimerDuration(60),
  Duration rampUp = Duration.zero,
  String? scheduleId,
  String? subtitle,
}) =>
    PlayRequest(
      landscapeId: 'cascade-foret',
      title: 'Cascade en forêt',
      subtitle: subtitle,
      layers: const [
        EngineLayer(key: 'son:eau-vive', source: AssetAudioSource('assets/audio/sons/eau-vive.ogg'), volume: 0.6),
        EngineLayer(key: 'son:oiseaux', source: AssetAudioSource('assets/audio/sons/oiseaux.ogg'), volume: 0.4),
      ],
      timer: timer,
      rampUp: rampUp,
      scheduleId: scheduleId,
    );

void main() {
  late FakeAudioEngine engine;
  late FakeFocus focus;
  late FakeNativeBridge native;
  late _Host host;

  PlaybackHandler build(FakeAsync async, DateTime start) {
    engine = FakeAudioEngine();
    focus = FakeFocus();
    native = FakeNativeBridge();
    host = _Host();
    final handler = PlaybackHandler(
      engine: engine,
      focus: focus,
      native: native,
      now: () => start.add(async.elapsed),
      nightMaxHours: 10,
    );
    handler.attachHost(host);
    return handler;
  }

  final t0 = DateTime(2026, 10, 28, 22);

  test('start plays the layers, shows the notification state and arms the timer', () {
    fakeAsync((async) {
      final handler = build(async, t0);
      handler.start(_request());
      async.flushMicrotasks();
      expect(engine.calls, ['start']);
      expect(engine.activeKeys, {'son:eau-vive', 'son:oiseaux'});
      expect(handler.status.value.playing, isTrue);
      expect(handler.status.value.timerEndsAt, t0.add(const Duration(minutes: 60)));
      expect(handler.playbackState.value.playing, isTrue);
      expect(handler.playbackState.value.processingState, AudioProcessingState.ready);
      expect(handler.mediaItem.value?.title, 'Cascade en forêt');
      expect(host.started, hasLength(1));
    });
  });

  test('end of timer: 30 s fade then full stop, listened time reported', () {
    fakeAsync((async) {
      final handler = build(async, t0);
      handler.start(_request(timer: const TimerDuration(15)));
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 15, seconds: 1));
      expect(engine.calls.last, 'fadeOut:30');
      expect(handler.status.value.playing, isFalse);
      expect(handler.playbackState.value.processingState, AudioProcessingState.idle);
      expect(host.stops.single.$1, StopReason.timer);
      expect(host.stops.single.$2.inMinutes, 15);
      expect(focus.deactivations, 1);
    });
  });

  test('« Toute la nuit » stops after nuit_max_heures', () {
    fakeAsync((async) {
      final handler = build(async, t0);
      handler.start(_request(timer: const TimerNight()));
      async.flushMicrotasks();
      expect(handler.status.value.timerEndsAt, t0.add(const Duration(hours: 10)));
      async.elapse(const Duration(hours: 9, minutes: 59));
      expect(handler.status.value.playing, isTrue);
      async.elapse(const Duration(minutes: 2));
      expect(host.stops.single.$1, StopReason.nightLimit);
    });
  });

  test('no timer: keeps playing', () {
    fakeAsync((async) {
      final handler = build(async, t0);
      handler.start(_request(timer: const TimerNone()));
      async.flushMicrotasks();
      expect(handler.status.value.timerEndsAt, isNull);
      async.elapse(const Duration(hours: 20));
      expect(handler.status.value.playing, isTrue);
    });
  });

  test('pause freezes the countdown, resume continues it', () {
    fakeAsync((async) {
      final handler = build(async, t0);
      handler.start(_request(timer: const TimerDuration(30)));
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 10));
      handler.pause();
      async.flushMicrotasks();
      expect(handler.status.value.paused, isTrue);
      expect(handler.status.value.timerEndsAt, isNull);
      async.elapse(const Duration(hours: 1));
      expect(host.stops, isEmpty);
      handler.play();
      async.flushMicrotasks();
      expect(engine.calls, ['start', 'pause', 'resume']);
      expect(handler.status.value.timerEndsAt, t0.add(const Duration(hours: 1, minutes: 30)));
      async.elapse(const Duration(minutes: 20, seconds: 1));
      expect(host.stops.single.$1, StopReason.timer);
      expect(host.stops.single.$2.inMinutes, 30);
    });
  });

  test('setTimer restarts the countdown from now', () {
    fakeAsync((async) {
      final handler = build(async, t0);
      handler.start(_request(timer: const TimerDuration(60)));
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 5));
      handler.setTimer(const TimerDuration(15));
      expect(handler.status.value.timerEndsAt, t0.add(const Duration(minutes: 20)));
      async.elapse(const Duration(minutes: 15, seconds: 1));
      expect(host.stops, hasLength(1));
    });
  });

  test('stop during the end-of-timer fade ends once', () {
    fakeAsync((async) {
      final handler = build(async, t0);
      handler.start(_request(timer: const TimerDuration(1)));
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 1));
      handler.stop();
      async.flushMicrotasks();
      expect(host.stops, hasLength(1));
      expect(handler.status.value.playing, isFalse);
    });
  });

  test('a scheduled start from idle asks the host with the pending schedule id and ramps up', () {
    fakeAsync((async) {
      final handler = build(async, t0);
      native.pendingStart = 'sched-1';
      host.next = _request(rampUp: const Duration(minutes: 10), scheduleId: 'sched-1', subtitle: 'C’est l’heure d’aller dormir');
      handler.click();
      // The notification is shown at once (foreground-service deadline).
      expect(handler.playbackState.value.playing, isTrue);
      async.flushMicrotasks();
      expect(host.requested, ['sched-1']);
      expect(engine.lastRampUp, const Duration(minutes: 10));
      expect(handler.mediaItem.value?.artist, 'C’est l’heure d’aller dormir');
      expect(handler.status.value.scheduleId, 'sched-1');
    });
  });

  test('a scheduled start while already playing keeps the current sound', () {
    fakeAsync((async) {
      final handler = build(async, t0);
      handler.start(_request());
      async.flushMicrotasks();
      native.pendingStart = 'sched-1';
      handler.click();
      async.flushMicrotasks();
      expect(handler.status.value.playing, isTrue);
      expect(engine.calls, ['start']);
      // A real media button press (no pending start) toggles.
      handler.click();
      async.flushMicrotasks();
      expect(handler.status.value.paused, isTrue);
    });
  });

  test('host refusing to play (free user offline) ends the service', () {
    fakeAsync((async) {
      final handler = build(async, t0);
      native.pendingStart = 'sched-1';
      host.next = null;
      handler.click();
      async.flushMicrotasks();
      expect(engine.calls, isEmpty);
      expect(handler.playbackState.value.processingState, AudioProcessingState.idle);
      expect(handler.playbackState.value.playing, isFalse);
    });
  });

  test('audio focus: transient loss pauses then resumes; ducking; permanent loss stays paused', () {
    fakeAsync((async) {
      final handler = build(async, t0);
      handler.start(_request());
      async.flushMicrotasks();
      focus.emit(FocusChange.pauseBegin);
      async.flushMicrotasks();
      expect(handler.status.value.paused, isTrue);
      focus.emit(FocusChange.pauseEnd);
      async.flushMicrotasks();
      expect(handler.status.value.playing, isTrue);
      focus.emit(FocusChange.duckBegin);
      async.flushMicrotasks();
      expect(engine.ducked, isTrue);
      focus.emit(FocusChange.duckEnd);
      async.flushMicrotasks();
      expect(engine.ducked, isFalse);
      focus.emit(FocusChange.lost);
      async.flushMicrotasks();
      focus.emit(FocusChange.pauseEnd);
      async.flushMicrotasks();
      expect(handler.status.value.paused, isTrue);
    });
  });

  test('headphones unplugged pause playback', () {
    fakeAsync((async) {
      final handler = build(async, t0);
      handler.start(_request());
      async.flushMicrotasks();
      focus.unplug();
      async.flushMicrotasks();
      expect(handler.status.value.paused, isTrue);
    });
  });

  test('focus refused (call in progress): nothing starts', () {
    fakeAsync((async) {
      final handler = build(async, t0);
      focus.granted = false;
      bool? ok;
      handler.start(_request()).then((v) => ok = v);
      async.flushMicrotasks();
      expect(ok, isFalse);
      expect(engine.calls, isEmpty);
    });
  });

  test('a mix change while playing updates the engine, a landscape change cross-fades', () {
    fakeAsync((async) {
      final handler = build(async, t0);
      handler.start(_request());
      async.flushMicrotasks();
      handler.updateLayers(_request());
      async.flushMicrotasks();
      expect(engine.lastFade, MixRules.levelFade);
      handler.updateLayers(_request(), crossFade: true);
      async.flushMicrotasks();
      expect(engine.lastFade, MixRules.crossFade);
    });
  });

  test('swiping the app away keeps playing, but closes a paused session', () {
    fakeAsync((async) {
      final handler = build(async, t0);
      handler.start(_request());
      async.flushMicrotasks();
      handler.onTaskRemoved();
      async.flushMicrotasks();
      expect(handler.status.value.playing, isTrue);
      handler.pause();
      async.flushMicrotasks();
      handler.onTaskRemoved();
      async.flushMicrotasks();
      expect(handler.status.value.paused, isFalse);
      expect(host.stops.single.$1, StopReason.user);
    });
  });
  test('no audio device: start fails cleanly, back to idle, a retry is possible', () {
    fakeAsync((async) {
      final failing = _NoDeviceEngine();
      final focus = FakeFocus();
      final host = _Host();
      final handler = PlaybackHandler(engine: failing, focus: focus, native: FakeNativeBridge(), now: () => t0)
        ..attachHost(host);
      bool? started;
      handler.start(_request()).then((v) => started = v);
      async.flushMicrotasks();
      expect(started, isFalse);
      expect(handler.status.value.playing, isFalse);
      expect(handler.status.value.paused, isFalse);
      expect(handler.status.value.loading, isFalse);
      expect(handler.playbackState.value.processingState, AudioProcessingState.idle);
      expect(host.stops.single.$1, StopReason.failed);
      expect(focus.deactivations, 1);
      // A scheduled start through the media button fails the same way, without hanging.
      host.next = _request(scheduleId: 's1');
      handler.play();
      async.flushMicrotasks();
      expect(failing.attempts, 2);
      expect(handler.status.value.loading, isFalse);
      expect(handler.status.value.playing, isFalse);
    });
  });
}
