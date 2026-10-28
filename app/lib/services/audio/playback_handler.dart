// Background playback: the audio_service handler owns the engine, the media notification,
// audio focus and the timer. The timer lives here, not in the UI, so it keeps running when the
// app is closed (dossier § 6). Scheduled starts enter through click()/play(), fired by the
// native alarm receiver (ScheduleAlarmReceiver.kt) with a MEDIA_PLAY key event.
import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';

import '../../core/scene.dart';
import '../native_bridge.dart';
import 'audio_engine.dart';
import 'audio_focus.dart';

/// What to play, prepared by the app (content already resolved).
class PlayRequest {
  const PlayRequest({
    required this.landscapeId,
    required this.title,
    required this.layers,
    required this.timer,
    this.subtitle,
    this.rampUp = Duration.zero,
    this.scheduleId,
  });

  final String landscapeId;

  /// Landscape name, shown in the media notification.
  final String title;

  /// Reminder text for a scheduled start (« C’est l’heure d’aller dormir »), or null.
  final String? subtitle;
  final List<EngineLayer> layers;
  final TimerSetting timer;

  /// Ramp from silence for scheduled starts (`montee_minutes`).
  final Duration rampUp;

  /// Set when this playback was started by a schedule.
  final String? scheduleId;
}

enum StopReason {
  /// Stop button (app or notification).
  user,

  /// End of a duration timer (after the 30 s fade).
  timer,

  /// « Toute la nuit » reached `nuit_max_heures`.
  nightLimit,

  /// Nothing could be played (content missing, free user offline at a scheduled start).
  failed,
}

/// Playback facts the app controller mirrors for the UI.
@immutable
class PlaybackStatus {
  const PlaybackStatus({
    this.playing = false,
    this.paused = false,
    this.loading = false,
    this.timerEndsAt,
    this.landscapeId,
    this.scheduleId,
  });

  final bool playing;

  /// Voices loaded but paused (resume possible).
  final bool paused;
  final bool loading;
  final DateTime? timerEndsAt;
  final String? landscapeId;
  final String? scheduleId;
}

/// Implemented by the app controller.
abstract class PlaybackHost {
  /// Playback requested by the system (notification, headset button, scheduled start) while
  /// nothing is loaded. Returns what to play, or null when nothing should play (the host has
  /// already told the user why, e.g. the « Pas de connexion » notification).
  Future<PlayRequest?> requestPlay({String? scheduleId});

  void onPlaybackStarted(PlayRequest request);

  /// [listened]: sound actually played since the start (pauses excluded).
  void onPlaybackStopped(StopReason reason, Duration listened);
}

/// Prefix of the scheduled-start log lines (same tag as the Kotlin receiver; read by the CI
/// emulator check, .github/workflows/app.yml).
const String scheduleLogTag = 'EventideSchedule';

class PlaybackHandler extends BaseAudioHandler {
  PlaybackHandler({
    required this._engine,
    required this._focus,
    required this._native,
    DateTime Function()? now,
    this._nightMaxHours = 10,
  }) : _now = now ?? DateTime.now {
    _focusSub = _focus.changes.listen(_onFocusChange);
    _noisySub = _focus.becomingNoisy.listen((_) {
      if (_status.playing) pause();
    });
    _publish(const PlaybackStatus());
  }

  final AudioEngine _engine;
  final AudioFocus _focus;
  final NativeBridge _native;
  final DateTime Function() _now;
  int _nightMaxHours;

  late final StreamSubscription<FocusChange> _focusSub;
  late final StreamSubscription<void> _noisySub;

  final Completer<PlaybackHost> _hostCompleter = Completer<PlaybackHost>();
  final ValueNotifier<PlaybackStatus> status = ValueNotifier(const PlaybackStatus());
  PlaybackStatus get _status => status.value;

  PlayRequest? _current;
  Timer? _timer;
  Duration? _timerRemaining;
  bool _timerIsNightLimit = false;
  bool _pausedByInterruption = false;

  /// Set during the 30 s end-of-timer fade.
  Completer<void>? _ending;

  /// Incremented by stop(): a play() still preparing content must not start afterwards.
  int _generation = 0;

  DateTime? _listenStart;
  Duration _listened = Duration.zero;

  PlayRequest? get current => _current;

  void attachHost(PlaybackHost host) {
    if (!_hostCompleter.isCompleted) _hostCompleter.complete(host);
  }

  set nightMaxHours(int hours) => _nightMaxHours = hours;

  // ---- State publication

  void _publish(PlaybackStatus next) {
    status.value = next;
    final playing = next.playing || next.loading;
    playbackState.add(PlaybackState(
      controls: [
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.stop,
      ],
      androidCompactActionIndices: const [0, 1],
      systemActions: const {},
      processingState: next.loading
          ? AudioProcessingState.loading
          : (next.playing || next.paused)
              ? AudioProcessingState.ready
              : AudioProcessingState.idle,
      playing: playing,
    ));
  }

  void _publishMedia(PlayRequest request) {
    mediaItem.add(MediaItem(
      id: request.landscapeId,
      title: request.title,
      artist: request.subtitle,
      album: 'Eventide',
    ));
  }

  // ---- Listening time (sleep tracking)

  void _listenResume() => _listenStart ??= _now();

  void _listenPause() {
    final start = _listenStart;
    if (start != null) _listened += _now().difference(start);
    _listenStart = null;
  }

  // ---- Timer

  Duration? _timerDuration(TimerSetting timer) => switch (timer) {
        TimerDuration(:final minutes) => Duration(minutes: minutes),
        TimerNight() => Duration(hours: _nightMaxHours),
        TimerNone() => null,
      };

  void _armTimer(Duration? duration, {required bool nightLimit}) {
    _timer?.cancel();
    _timer = null;
    _timerRemaining = duration;
    _timerIsNightLimit = nightLimit;
    if (duration == null) return;
    _timer = Timer(duration, _onTimerEnd);
  }

  DateTime? _endsAt() {
    final remaining = _timerRemaining;
    if (remaining == null || _timer == null) return null;
    return _timerStartedAt?.add(remaining);
  }

  DateTime? _timerStartedAt;

  void _startTimer(TimerSetting setting) {
    _timerStartedAt = _now();
    _armTimer(_timerDuration(setting), nightLimit: setting is TimerNight);
  }

  void _freezeTimer() {
    final started = _timerStartedAt;
    final remaining = _timerRemaining;
    _timer?.cancel();
    _timer = null;
    if (started != null && remaining != null) {
      final left = remaining - _now().difference(started);
      _timerRemaining = left.isNegative ? Duration.zero : left;
    }
  }

  void _resumeTimer() {
    final remaining = _timerRemaining;
    if (remaining == null) return;
    _timerStartedAt = _now();
    _armTimer(remaining, nightLimit: _timerIsNightLimit);
  }

  Future<void> _onTimerEnd() async {
    _timer = null;
    if (_ending != null) return;
    final ending = _ending = Completer<void>();
    final reason = _timerIsNightLimit ? StopReason.nightLimit : StopReason.timer;
    try {
      // Fade of 30 s, then a full stop; the screen is not woken up (nothing to do here for that).
      await _engine.fadeOutAndStop(MixRules.timerFadeOut);
    } finally {
      await _finish(reason);
      _ending = null;
      ending.complete();
    }
  }

  /// Changes the timer of the current playback: a fresh countdown from now.
  void setTimer(TimerSetting setting) {
    final current = _current;
    if (current == null) return;
    _current = PlayRequest(
      landscapeId: current.landscapeId,
      title: current.title,
      subtitle: current.subtitle,
      layers: current.layers,
      timer: setting,
      rampUp: current.rampUp,
      scheduleId: current.scheduleId,
    );
    if (_status.playing) {
      _startTimer(setting);
    } else if (_status.paused) {
      _timerStartedAt = _now();
      _timerRemaining = _timerDuration(setting);
      _timerIsNightLimit = setting is TimerNight;
    }
    _publish(_copyStatus(timerEndsAt: _status.playing ? _endsAt() : null));
  }

  PlaybackStatus _copyStatus({
    bool? playing,
    bool? paused,
    bool? loading,
    DateTime? timerEndsAt,
  }) =>
      PlaybackStatus(
        playing: playing ?? _status.playing,
        paused: paused ?? _status.paused,
        loading: loading ?? _status.loading,
        timerEndsAt: timerEndsAt,
        landscapeId: _current?.landscapeId,
        scheduleId: _current?.scheduleId,
      );

  // ---- Commands from the app controller

  /// Starts [request] (or cross-fades to it when already playing). False if audio focus was
  /// refused (a call in progress) or nothing could be played.
  Future<bool> start(PlayRequest request) async {
    if (request.layers.isEmpty) return false;
    // Started again during the end-of-timer fade: let that session end first.
    final ending = _ending;
    if (ending != null) await ending.future;
    final wasPlaying = _status.playing;
    final newSession = _current == null;
    if (!wasPlaying && !await _focus.activate()) return false;
    _current = request;
    _publishMedia(request);
    _publish(_copyStatus(playing: true, paused: false, loading: false, timerEndsAt: _endsAt()));
    try {
      await _engine.start(request.layers, rampUp: request.rampUp);
    } catch (e) {
      // No audio device, broken file…: back to idle, the UI stays usable and says so.
      debugPrint('PlaybackHandler: start failed ($e)');
      await _finish(StopReason.failed);
      return false;
    }
    if (newSession) {
      _listened = Duration.zero;
      _listenStart = null;
    }
    if (!wasPlaying) {
      _listenResume();
      _startTimer(request.timer);
    }
    _publish(_copyStatus(playing: true, paused: false, loading: false, timerEndsAt: _endsAt()));
    if (newSession && _hostCompleter.isCompleted) {
      (await _hostCompleter.future).onPlaybackStarted(request);
    }
    return true;
  }

  /// Applies a mix change while loaded (playing or paused).
  Future<void> updateLayers(PlayRequest request, {bool crossFade = false}) async {
    if (_current == null) return;
    _current = PlayRequest(
      landscapeId: request.landscapeId,
      title: request.title,
      subtitle: _current?.subtitle,
      layers: request.layers,
      timer: _current!.timer,
      rampUp: _current!.rampUp,
      scheduleId: _current?.scheduleId,
    );
    _publishMedia(_current!);
    if (request.layers.isEmpty) {
      await stop();
      return;
    }
    await _engine.update(request.layers, fade: crossFade ? MixRules.crossFade : MixRules.levelFade);
    _publish(_copyStatus(timerEndsAt: _endsAt()));
  }

  /// Shows a loading state (the notification appears at once, which also satisfies Android's
  /// foreground-service deadline while content is being prepared).
  void markLoading(String title, {String? subtitle, String? landscapeId}) {
    mediaItem.add(MediaItem(id: landscapeId ?? 'eventide', title: title, artist: subtitle, album: 'Eventide'));
    _publish(_copyStatus(loading: true, timerEndsAt: _endsAt()));
  }

  // ---- audio_service callbacks (notification, headset, scheduled start)

  @override
  Future<void> click([MediaButton button = MediaButton.media]) async {
    if (button != MediaButton.media) return super.click(button);
    if (_status.playing || _status.loading) {
      // A scheduled start while already listening keeps the current sound.
      final pending = await _native.consumePendingStart();
      if (pending != null) {
        debugPrint('$scheduleLogTag: schedule $pending ignored, already listening');
        return;
      }
      return pause();
    }
    return play();
  }

  @override
  Future<void> play() async {
    if (_status.playing || _status.loading) return;
    if (_status.paused && _engine.isPaused) {
      if (!await _focus.activate()) return;
      await _engine.resume();
      if (_current == null) return; // stopped meanwhile
      _pausedByInterruption = false;
      _listenResume();
      _resumeTimer();
      _publish(_copyStatus(playing: true, paused: false, timerEndsAt: _endsAt()));
      return;
    }
    // Nothing loaded: ask the app what to play. The loading state is published first so that
    // the foreground notification exists within Android's deadline (headless engine start).
    markLoading('Eventide');
    final scheduleId = await _native.consumePendingStart();
    if (scheduleId != null) debugPrint('$scheduleLogTag: play requested for schedule $scheduleId');
    await _playFromHost(scheduleId);
  }

  /// Runs a scheduled start found by the app (fallback « Lancer » tapped).
  Future<void> playScheduled(String scheduleId) async {
    if (_status.playing || _status.loading) return;
    markLoading('Eventide');
    await _playFromHost(scheduleId);
  }

  Future<void> _playFromHost(String? scheduleId) async {
    final generation = _generation;
    final host = await _hostCompleter.future;
    PlayRequest? request;
    try {
      request = await host.requestPlay(scheduleId: scheduleId);
    } catch (e) {
      debugPrint('PlaybackHandler: requestPlay failed ($e)');
    }
    if (generation != _generation) return; // stopped meanwhile
    if (request == null || !await start(request)) {
      if (scheduleId != null) debugPrint('$scheduleLogTag: nothing played for schedule $scheduleId');
      await _finish(StopReason.failed);
      return;
    }
    if (scheduleId != null) {
      debugPrint('$scheduleLogTag: playback started for schedule $scheduleId (${request.landscapeId})');
    }
  }

  @override
  Future<void> pause() async {
    if (!_status.playing) return;
    await _engine.pause();
    if (_current == null) return; // ended meanwhile (end-of-timer fade)
    _listenPause();
    _freezeTimer();
    _publish(_copyStatus(playing: false, paused: true, loading: false));
  }

  @override
  Future<void> stop() async {
    _generation++;
    _timer?.cancel();
    _timer = null;
    if (_current != null || _status.loading) {
      await _engine.stop();
      await _finish(StopReason.user);
    } else {
      _publish(const PlaybackStatus());
    }
  }

  @override
  Future<void> onTaskRemoved() async {
    // Swiping the app away keeps the sound (and its timer) playing; a paused session is closed.
    if (!_status.playing) await stop();
  }

  Future<void> _finish(StopReason reason) async {
    _timer?.cancel();
    _timer = null;
    _timerRemaining = null;
    _listenPause();
    final listened = _listened;
    final hadSession = _current != null;
    _current = null;
    _pausedByInterruption = false;
    _publish(const PlaybackStatus());
    await _focus.deactivate();
    if (hadSession && _hostCompleter.isCompleted) {
      (await _hostCompleter.future).onPlaybackStopped(reason, listened);
    }
  }

  // ---- Audio focus

  Future<void> _onFocusChange(FocusChange change) async {
    switch (change) {
      case FocusChange.duckBegin:
        await _engine.setDucked(true);
      case FocusChange.duckEnd:
        await _engine.setDucked(false);
      case FocusChange.pauseBegin:
        if (_status.playing) {
          _pausedByInterruption = true;
          await pause();
        }
      case FocusChange.pauseEnd:
        if (_pausedByInterruption && _status.paused) {
          _pausedByInterruption = false;
          await play();
        }
      case FocusChange.lost:
        _pausedByInterruption = false;
        if (_status.playing) await pause();
    }
  }

  Future<void> dispose() async {
    await _focusSub.cancel();
    await _noisySub.cancel();
    _timer?.cancel();
    await _engine.dispose();
  }
}
