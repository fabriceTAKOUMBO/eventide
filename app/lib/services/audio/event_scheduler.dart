// Sounds played by events (API contract § 11): instead of a loop, short sounds now and then,
// never twice the same (a thunder every 2 to 5 minutes, each one different). Owned by the
// PlaybackHandler, so it lives in the background audio service and keeps going with the screen
// off. Pure timing: the engine plays, the decor draws the flash announced on [strikes].
//
// Rules applied (contract § 11):
//   * first event `premier_s` after the start of the listening, a resume after a pause, or the
//     addition of the sound (also its return from level 0 or from the mute); then a gap drawn in
//     `intervalle_s` from one event to the next;
//   * each event: a variant at random, never one of the two last played; gain −6 to 0 dB, speed
//     0.92 to 1.08, stereo position −0.4 to 0.4; never two events at the same time (an event due
//     while another one sounds waits for its end);
//   * nothing during a pause, the end-of-timer fade or once stopped; level 0 or a muted sound
//     category: no event, and the one sounding fades out;
//   * a flash first ([LightningStrike]), the thunder 0.4 to 3.5 s later (the closer, the brighter).
import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../core/catalog.dart';
import '../../core/lightning.dart';
import 'audio_engine.dart';

/// A variant file of an event sound. [resolve] finds or downloads it when an event needs it.
class EventVariant {
  const EventVariant(this.id, this.resolve);

  final String id;
  final Future<AudioSourceRef> Function() resolve;
}

/// A sound played by events in the mix, ready to play.
class EventLayer {
  const EventLayer({
    required this.key,
    required this.variants,
    required this.volume,
    this.interval = EventSound.defaultInterval,
    this.firstDelay = EventSound.defaultFirstDelay,
  });

  /// Layer key, as for the loops (`son:tonnerre`).
  final String key;
  final List<EventVariant> variants;

  /// 0..1: the level of the sound (0 when removed or muted: no event).
  final double volume;
  final SecondsRange interval;
  final SecondsRange firstDelay;

  @override
  String toString() => 'EventLayer($key, ${volume.toStringAsFixed(2)})';
}

class _State {
  _State(this.layer);

  EventLayer layer;

  /// When the next event sounds (its flash comes [delay] earlier).
  DateTime? due;
  Duration delay = Duration.zero;
  Timer? timer;

  /// Variants played, oldest first (the last two are never replayed).
  final List<String> recent = [];

  /// Bumped whenever the schedule is redone: a stale callback does nothing.
  int generation = 0;

  void cancel() {
    timer?.cancel();
    timer = null;
    due = null;
    generation++;
  }
}

class EventSoundScheduler {
  EventSoundScheduler({required this._engine, Random? random, DateTime Function()? now})
      : _random = random ?? Random(),
        _now = now ?? DateTime.now;

  final AudioEngine _engine;
  final Random _random;
  final DateTime Function() _now;

  final Map<String, _State> _states = {};
  final StreamController<LightningStrike> _strikes = StreamController<LightningStrike>.broadcast();

  /// Listening (started and not paused, stopped or fading out).
  bool _running = false;

  /// End of the event sounding now (any layer): no other event before it.
  DateTime? _busyUntil;

  /// A flash just before each thunder (contract § 11): the `eclairs` decor draws it.
  Stream<LightningStrike> get strikes => _strikes.stream;

  bool get running => _running;

  /// When the next event of [key] sounds (tests and logs).
  @visibleForTesting
  DateTime? nextEventOf(String key) => _states[key]?.due;

  /// Listening starts from silence: every audible event sound gets its first delay.
  void start(List<EventLayer> layers) {
    _running = true;
    _busyUntil = null;
    _apply(layers, fresh: true);
  }

  /// The mix changed while loaded (playing or paused): a new sound (or one back from level 0 or
  /// the mute) gets its first delay; a removed or silenced one stops; a level change applies to
  /// the event sounding now.
  void update(List<EventLayer> layers) => _apply(layers, fresh: false);

  void pause() {
    if (!_running) return;
    _running = false;
    _busyUntil = null; // the engine ends the event sounding at the pause
    for (final s in _states.values) {
      s.cancel();
    }
  }

  /// A resume after a pause draws a new first delay for every sound.
  void resume() {
    if (_running) return;
    _running = true;
    for (final s in _states.values) {
      _scheduleFirst(s);
    }
  }

  /// End of the listening, or start of the end-of-timer fade: no more events.
  void stop() {
    _running = false;
    _busyUntil = null;
    for (final s in _states.values) {
      s.cancel();
    }
    _states.clear();
  }

  void dispose() {
    stop();
    _strikes.close();
  }

  void _apply(List<EventLayer> layers, {required bool fresh}) {
    final wanted = {for (final l in layers) l.key: l};
    for (final key in _states.keys.toList()) {
      if (!wanted.containsKey(key)) {
        _states.remove(key)!.cancel();
        unawaited(_engine.setEventVolume(key, 0));
      }
    }
    for (final layer in layers) {
      final old = _states[layer.key];
      final state = old ?? (_states[layer.key] = _State(layer));
      final before = old?.layer.volume ?? 0;
      final wasAudible = before > 0;
      state.layer = layer;
      if (layer.volume <= 0) {
        state.cancel();
        if (wasAudible) unawaited(_engine.setEventVolume(layer.key, 0, fade: MixRules.muteFade));
        continue;
      }
      if (wasAudible && (before - layer.volume).abs() > 0.001) {
        unawaited(_engine.setEventVolume(layer.key, layer.volume));
      }
      if (!_running) continue;
      if (fresh || !wasAudible || state.due == null) _scheduleFirst(state);
    }
  }

  void _scheduleFirst(_State s) {
    if (s.layer.volume <= 0) return;
    _schedule(s, _now().add(s.layer.firstDelay.draw(_random)));
  }

  /// Plans the event of [s] at [at] (not before the end of the one sounding), its flash before.
  void _schedule(_State s, DateTime at) {
    s.cancel();
    final busy = _busyUntil;
    if (busy != null && at.isBefore(busy)) at = busy.add(const Duration(seconds: 1));
    s.due = at;
    s.delay = StormRules.thunderDelay(_random);
    final generation = s.generation;
    var wait = at.subtract(s.delay).difference(_now());
    if (wait.isNegative) wait = Duration.zero;
    s.timer = Timer(wait, () => _flash(s, generation));
  }

  void _flash(_State s, int generation) {
    if (!_alive(s, generation)) return;
    final due = s.due!;
    final busy = _busyUntil;
    if (busy != null && due.isBefore(busy)) {
      // Another event still sounds: this one waits for its end.
      _schedule(s, busy.add(const Duration(seconds: 1)));
      return;
    }
    final draw = StormRules.draw([for (final v in s.layer.variants) v.id], s.recent, _random);
    final variant = s.layer.variants.firstWhere((v) => v.id == draw.variant);
    // The file is found (or fetched) during the delay before the thunder.
    final source = variant.resolve();
    source.ignore();
    _strikes.add(LightningStrike(
      at: _now(),
      thunderDelay: s.delay,
      intensity: StormRules.intensityFor(s.delay),
    ));
    var wait = due.difference(_now());
    if (wait.isNegative) wait = Duration.zero;
    s.timer = Timer(wait, () => _thunder(s, generation, draw, source));
  }

  Future<void> _thunder(_State s, int generation, EventDraw draw, Future<AudioSourceRef> source) async {
    if (!_alive(s, generation)) return;
    final start = _now();
    Duration? length;
    try {
      final ref = await source.timeout(const Duration(seconds: 5));
      if (!_alive(s, generation)) return;
      length = await _engine.playEvent(
        s.layer.key,
        ref,
        volume: s.layer.volume,
        gain: draw.gain,
        speed: draw.speed,
        pan: draw.pan,
      );
    } catch (e) {
      // Not downloaded, offline, broken file: this event is skipped, the next one is planned.
      debugPrint('EventSoundScheduler: ${s.layer.key} ${draw.variant} skipped ($e)');
    }
    if (!_alive(s, generation)) return;
    if (length != null) {
      s.recent.add(draw.variant);
      if (s.recent.length > StormRules.noRepeat) s.recent.removeAt(0);
      final end = _now().add(length);
      if (_busyUntil == null || end.isAfter(_busyUntil!)) _busyUntil = end;
    }
    _schedule(s, start.add(s.layer.interval.draw(_random)));
  }

  bool _alive(_State s, int generation) =>
      _running && s.generation == generation && identical(_states[s.layer.key], s) && s.layer.volume > 0;
}
