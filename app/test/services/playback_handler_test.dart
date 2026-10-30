import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:eventide/core/catalog.dart';
import 'package:eventide/core/lightning.dart';
import 'package:eventide/core/media_card.dart';
import 'package:eventide/core/scene.dart';
import 'package:eventide/services/audio/audio_engine.dart';
import 'package:eventide/services/audio/audio_focus.dart';
import 'package:eventide/services/audio/event_scheduler.dart';
import 'package:eventide/services/audio/fake_audio_engine.dart';
import 'package:eventide/services/audio/media_card_controls.dart';
import 'package:eventide/services/audio/playback_handler.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

class _Host implements PlaybackHost {
  PlayRequest? next;
  final List<String?> requested = [];
  final List<(StopReason, Duration)> stops = [];
  final List<PlayRequest> started = [];
  final List<String> cardCommands = [];
  final ValueNotifier<MediaCardInfo?> card = ValueNotifier(null);

  @override
  Future<PlayRequest?> requestPlay({String? scheduleId}) async {
    requested.add(scheduleId);
    return next;
  }

  @override
  void onPlaybackStarted(PlayRequest request) => started.add(request);

  @override
  void onPlaybackStopped(StopReason reason, Duration listened) => stops.add((reason, listened));

  @override
  ValueListenable<MediaCardInfo?> get mediaCard => card;

  @override
  Future<void> skipLandscape(int direction) async => cardCommands.add('skip:$direction');

  @override
  Future<void> toggleFavoriteFromCard() async => cardCommands.add('favorite');

  @override
  Future<void> cycleTimerFromCard() async => cardCommands.add('timer');
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

/// The end-of-timer fade lasts until the test completes it.
class _SlowFadeEngine extends FakeAudioEngine {
  final Completer<void> fade = Completer<void>();

  @override
  Future<void> fadeOutAndStop(Duration duration) async {
    calls.add('fadeOut:${duration.inSeconds}');
    await fade.future;
    layers = const [];
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
      // The reminder is the notification's third line (the card's subtitle is the mix).
      expect(handler.mediaItem.value?.displayDescription, 'C’est l’heure d’aller dormir');
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
  group('media card (lock screen, notification shade)', () {
    const card = MediaCardInfo(
      landscapeId: 'cascade-foret',
      title: 'Cascade en forêt',
      artist: 'Eau vive · Oiseaux · Piano doux',
      nextId: 'sous-bois',
    );

    List<MediaAction> actions(PlaybackHandler handler) =>
        [for (final c in handler.playbackState.value.controls) c.action];

    test('media item: landscape, audible mix, album, timer length as duration', () {
      fakeAsync((async) {
        final handler = build(async, t0);
        host.card.value = card;
        handler.start(_request(timer: const TimerDuration(30)));
        async.flushMicrotasks();
        final item = handler.mediaItem.value!;
        expect(item.id, 'cascade-foret');
        expect(item.title, 'Cascade en forêt');
        expect(item.artist, 'Eau vive · Oiseaux · Piano doux');
        expect(item.album, 'Full Relax');
        expect(item.duration, const Duration(minutes: 30));
        expect(item.artUri, isNull);
        expect(item.displayDescription, isNull);
      });
    });

    test('« Toute la nuit »: duration = nuit_max_heures; « Sans minuteur »: no duration (no bar)', () {
      fakeAsync((async) {
        final handler = build(async, t0);
        host.card.value = card;
        handler.start(_request(timer: const TimerNight()));
        async.flushMicrotasks();
        expect(handler.mediaItem.value!.duration, const Duration(hours: 10));
        handler.setTimer(const TimerNone());
        expect(handler.mediaItem.value!.duration, isNull);
        expect(handler.playbackState.value.updatePosition, Duration.zero);
        expect(handler.playbackState.value.speed, 0);
        handler.setTimer(const TimerDuration(15));
        expect(handler.mediaItem.value!.duration, const Duration(minutes: 15));
      });
    });

    test('progress = time since the timer (re)started; frozen while paused; restarts at 0 on a change', () {
      fakeAsync((async) {
        final handler = build(async, t0);
        host.card.value = card;
        handler.start(_request(timer: const TimerDuration(60)));
        async.flushMicrotasks();
        var state = handler.playbackState.value;
        expect(state.updatePosition, Duration.zero);
        expect(state.speed, 1.0);
        expect(state.updateTime, t0);
        async.elapse(const Duration(minutes: 10));
        handler.pause();
        async.flushMicrotasks();
        state = handler.playbackState.value;
        expect(state.playing, isFalse);
        expect(state.updatePosition, const Duration(minutes: 10));
        expect(state.speed, 0);
        async.elapse(const Duration(hours: 2)); // paused: the timer does not count
        handler.play();
        async.flushMicrotasks();
        state = handler.playbackState.value;
        expect(state.playing, isTrue);
        expect(state.updatePosition, const Duration(minutes: 10));
        expect(state.speed, 1.0);
        expect(state.updateTime, t0.add(const Duration(hours: 2, minutes: 10)));
        async.elapse(const Duration(minutes: 5));
        handler.setTimer(const TimerDuration(30));
        state = handler.playbackState.value;
        expect(state.updatePosition, Duration.zero);
        expect(handler.mediaItem.value!.duration, const Duration(minutes: 30));
        // A mix change while counting keeps the position.
        async.elapse(const Duration(minutes: 7));
        handler.updateLayers(_request(timer: const TimerDuration(30)));
        async.flushMicrotasks();
        expect(handler.playbackState.value.updatePosition, const Duration(minutes: 7));
      });
    });

    test('a timer changed while paused restarts from 0 and waits for the resume', () {
      fakeAsync((async) {
        final handler = build(async, t0);
        handler.start(_request(timer: const TimerDuration(60)));
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 20));
        handler.pause();
        async.flushMicrotasks();
        handler.setTimer(const TimerDuration(120));
        expect(handler.playbackState.value.updatePosition, Duration.zero);
        expect(handler.playbackState.value.speed, 0);
        expect(handler.mediaItem.value!.duration, const Duration(hours: 2));
      });
    });

    test('end-of-timer fade: the bar stays full', () {
      fakeAsync((async) {
        final engine = _SlowFadeEngine();
        final handler = PlaybackHandler(engine: engine, focus: FakeFocus(), native: FakeNativeBridge(), now: () => t0.add(async.elapsed))
          ..attachHost(_Host());
        handler.start(_request(timer: const TimerDuration(15)));
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 15));
        expect(handler.status.value.playing, isTrue); // fading out
        expect(handler.playbackState.value.updatePosition, const Duration(minutes: 15));
        expect(handler.playbackState.value.speed, 0);
        engine.fade.complete();
        async.flushMicrotasks();
        expect(handler.status.value.playing, isFalse);
      });
    });

    test('no seek: no seek system action, and a seek request changes nothing', () {
      fakeAsync((async) {
        final handler = build(async, t0);
        host.card.value = card;
        handler.start(_request(timer: const TimerDuration(60)));
        async.flushMicrotasks();
        expect(handler.playbackState.value.systemActions, isEmpty);
        expect(actions(handler), isNot(contains(MediaAction.seek)));
        async.elapse(const Duration(minutes: 3));
        handler.seek(const Duration(minutes: 50));
        async.flushMicrotasks();
        expect(handler.status.value.timerEndsAt, t0.add(const Duration(minutes: 60)));
        expect(engine.calls, ['start']);
      });
    });

    test('buttons follow the card: neighbours, heart, timer; compact = play/pause + next', () {
      fakeAsync((async) {
        final handler = build(async, t0);
        host.card.value = card;
        handler.start(_request(timer: const TimerDuration(30)));
        async.flushMicrotasks();
        expect(actions(handler), [MediaAction.pause, MediaAction.skipToNext, MediaAction.custom, MediaAction.custom]);
        expect(handler.playbackState.value.androidCompactActionIndices, [0, 1]);
        final heart = handler.playbackState.value.controls[2];
        expect(heart.androidIcon, MediaCardIcons.favoriteBorder);
        expect(handler.playbackState.value.controls[3].androidIcon, MediaCardIcons.timer30);

        host.card.value = const MediaCardInfo(
          landscapeId: 'sous-bois',
          title: 'Sous-bois ensoleillé',
          artist: 'Vent',
          previousId: 'cascade-foret',
          favorite: true,
        );
        expect(actions(handler), [MediaAction.skipToPrevious, MediaAction.pause, MediaAction.custom, MediaAction.custom]);
        expect(handler.playbackState.value.androidCompactActionIndices, [1]);
        expect(handler.playbackState.value.controls[2].androidIcon, MediaCardIcons.favorite);
        expect(handler.playbackState.value.controls[2].label, 'Retirer des favoris');
        // The card shows the landscape the sound is about to follow.
        expect(handler.mediaItem.value!.title, 'Sous-bois ensoleillé');
        expect(handler.mediaItem.value!.id, 'sous-bois');

        handler.pause();
        async.flushMicrotasks();
        expect(actions(handler)[1], MediaAction.play);
      });
    });

    test('picture added later: the media item is sent again, unchanged items are not', () {
      fakeAsync((async) {
        final handler = build(async, t0);
        final items = <MediaItem?>[];
        final sub = handler.mediaItem.listen(items.add);
        host.card.value = card;
        handler.start(_request());
        async.flushMicrotasks();
        final before = items.length;
        expect(items.last!.artUri, isNull);
        handler.pause();
        handler.play();
        async.flushMicrotasks();
        expect(items, hasLength(before), reason: 'nothing changed in the media item');
        final art = Uri.file('/cache/media_art/cascade-foret-0123456789ab.jpg');
        host.card.value = card.withArt(art);
        async.flushMicrotasks();
        expect(items, hasLength(before + 1));
        expect(items.last!.artUri, art);
        expect(items.last!.title, 'Cascade en forêt');
        sub.cancel();
      });
    });

    test('loading (system start, nothing loaded yet): play/pause only, no heart or timer', () {
      fakeAsync((async) {
        final handler = build(async, t0);
        host.card.value = card;
        host.next = null;
        handler.markLoading('Full Relax');
        expect(actions(handler), [MediaAction.pause]);
        expect(handler.mediaItem.value!.title, 'Full Relax');
      });
    });

    test('card buttons go to the host: previous/next, heart, timer; headset next too', () {
      fakeAsync((async) {
        final handler = build(async, t0);
        host.card.value = card;
        handler.start(_request());
        async.flushMicrotasks();
        handler.skipToNext();
        handler.skipToPrevious();
        handler.customAction(MediaCardActions.favorite);
        handler.customAction(MediaCardActions.timer);
        handler.customAction('unknown');
        handler.click(MediaButton.next);
        async.flushMicrotasks();
        expect(host.cardCommands, ['skip:1', 'skip:-1', 'favorite', 'timer', 'skip:1']);
        // None of them touches the sound.
        expect(engine.calls, ['start']);
        expect(handler.status.value.playing, isTrue);
      });
    });

    test('without a loaded session the card buttons do nothing', () {
      fakeAsync((async) {
        final handler = build(async, t0);
        host.card.value = card;
        handler.skipToNext();
        handler.customAction(MediaCardActions.favorite);
        handler.click(MediaButton.previous);
        async.flushMicrotasks();
        expect(host.cardCommands, isEmpty);
      });
    });

    test('pause from the card changes the sound only; the paused card swiped away stops', () {
      fakeAsync((async) {
        final handler = build(async, t0);
        host.card.value = card;
        handler.start(_request());
        async.flushMicrotasks();
        handler.click(); // play/pause button of the card (or headset)
        async.flushMicrotasks();
        expect(engine.calls, ['start', 'pause']);
        expect(host.cardCommands, isEmpty);
        expect(handler.mediaItem.value!.id, 'cascade-foret');
        handler.onNotificationDeleted();
        async.flushMicrotasks();
        expect(host.stops.single.$1, StopReason.user);
        expect(handler.playbackState.value.processingState, AudioProcessingState.idle);
      });
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

  group('thunder (sounds played by events, contract § 11)', () {
    final thunder = EventLayer(
      key: 'son:tonnerre',
      variants: [
        for (var i = 1; i <= 10; i++)
          EventVariant('tonnerre-coup-$i', () async => AssetAudioSource('assets/audio/sons/tonnerre-coup-$i.ogg')),
      ],
      volume: 0.5,
    );

    PlayRequest storm({TimerSetting timer = const TimerDuration(60)}) => PlayRequest(
          landscapeId: 'pluie-ville',
          title: 'Pluie sur la ville',
          layers: _request().layers,
          timer: timer,
          events: [thunder],
        );

    test('events in the background service: after the first delay, with a flash before', () {
      fakeAsync((async) {
        final handler = build(async, t0);
        final strikes = <Duration>[];
        handler.lightningStrikes.listen((_) => strikes.add(async.elapsed));
        handler.start(storm());
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 44));
        expect(engine.events, isEmpty);
        async.elapse(const Duration(seconds: 77));
        expect(engine.events, hasLength(1));
        expect(strikes, hasLength(1));
        async.elapse(const Duration(minutes: 30));
        expect(engine.events.length, greaterThan(5));
        expect(strikes.length - engine.events.length, inInclusiveRange(0, 1));
      });
    });

    test('a pause stops them, a resume starts over with a first delay', () {
      fakeAsync((async) {
        final handler = build(async, t0);
        handler.start(storm());
        async.flushMicrotasks();
        handler.pause();
        async.flushMicrotasks();
        async.elapse(const Duration(hours: 1));
        expect(engine.events, isEmpty);
        handler.play();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 44));
        expect(engine.events, isEmpty);
        async.elapse(const Duration(seconds: 77));
        expect(engine.events, hasLength(1));
      });
    });

    test('none during the end-of-timer fade, nor after the stop', () {
      fakeAsync((async) {
        final engine = _SlowFadeEngine();
        final handler = PlaybackHandler(engine: engine, focus: FakeFocus(), native: FakeNativeBridge(), now: () => t0.add(async.elapsed))
          ..attachHost(_Host());
        handler.start(storm(timer: const TimerDuration(15)));
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 15));
        final before = engine.events.length;
        expect(handler.status.value.playing, isTrue, reason: 'fading out');
        async.elapse(const Duration(minutes: 10));
        expect(engine.events.length, before);
        engine.fade.complete();
        async.flushMicrotasks();
        async.elapse(const Duration(hours: 1));
        expect(engine.events.length, before);
      });
    });

    test('a mix change goes to the scheduler (level 0: the event sounding fades out)', () {
      fakeAsync((async) {
        final handler = build(async, t0);
        handler.start(storm());
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 3));
        expect(engine.events, isNotEmpty);
        final silent = EventLayer(key: thunder.key, variants: thunder.variants, volume: 0);
        handler.updateLayers(PlayRequest(
          landscapeId: 'pluie-ville',
          title: 'Pluie sur la ville',
          layers: _request().layers,
          timer: const TimerDuration(60),
          events: [silent],
        ));
        async.flushMicrotasks();
        expect(engine.calls, contains('eventVolume:son:tonnerre:0.00'));
        final count = engine.events.length;
        async.elapse(const Duration(hours: 1));
        expect(engine.events.length, count);
        handler.stop();
        async.flushMicrotasks();
      });
    });
  });


  test('storm sequences go on in the background service: strikes, aftershocks, the rain redoubling', () {
    fakeAsync((async) {
      final handler = build(async, t0);
      List<EventVariant> part(String name) => [
            for (var i = 1; i <= 3; i++)
              EventVariant('tonnerre-$name-0$i', () async => AssetAudioSource('assets/audio/sons/tonnerre-$name-0$i.ogg')),
          ];
      final parts = {
        StormPart.avant: part('avant'),
        StormPart.coup: part('coup'),
        StormPart.coupProche: part('proche'),
        StormPart.replique: part('replique'),
        StormPart.lointain: part('lointain'),
      };
      final storm = EventLayer(
        key: 'son:tonnerre',
        variants: [for (final l in parts.values) ...l],
        volume: 0.5,
        interval: const SecondsRange(70, 170),
        firstDelay: const SecondsRange(20, 60),
        storm: StormLayer(
          parts: parts,
          weights: const {StormKind.lointain: 25, StormKind.orage: 55, StormKind.proche: 20},
          averseKeys: const ['son:eau-vive'],
        ),
      );
      final strikes = <LightningStrike>[];
      handler.lightningStrikes.listen(strikes.add);
      handler.start(PlayRequest(
        landscapeId: 'pluie-ville',
        title: 'Pluie sur la ville',
        layers: _request().layers,
        timer: const TimerNone(),
        events: [storm],
      ));
      async.flushMicrotasks();
      async.elapse(const Duration(hours: 1));
      final ids = [for (final e in engine.events) (e.source as AssetAudioSource).assetKey];
      for (final name in ['avant', 'coup', 'proche', 'replique', 'lointain']) {
        expect(ids.where((id) => id.contains('tonnerre-$name-')), isNotEmpty, reason: name);
      }
      expect(strikes, isNotEmpty);
      expect(engine.swells, isNotEmpty);
      expect(engine.swells.every((w) => w.keys.single == 'son:eau-vive'), isTrue);
      handler.stop();
      async.flushMicrotasks();
      final count = engine.events.length;
      async.elapse(const Duration(hours: 1));
      expect(engine.events.length, count, reason: 'nothing after the stop');
    });
  });
}
