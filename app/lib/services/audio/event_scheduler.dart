// Sounds played by events (API contract § 11): instead of a loop, short sounds now and then,
// never twice the same. Owned by the PlaybackHandler, so it lives in the background audio
// service and keeps going with the screen off. Pure timing: the engine plays, the decor draws
// the flash announced on [EventSoundScheduler.strikes].
//
// Each event is a [StormPlan] (core/lightning.dart): with the catalog's `orage`, a storm
// sequence (a distant rumble alone; a soft pre-rumble, the flash, the strike and its roll;
// a close strike and its aftershock; the rain redoubling and a gust after a strike); without
// it, one variant after a flash. Rules applied (contract § 11):
//   * first event `premier_s` after the start of the listening, a resume after a pause, or the
//     addition of the sound (also its return from level 0 or from the mute); then a gap drawn in
//     `intervalle_s` from the start of one event to the start of the next;
//   * never two events at the same time: an event due while another one still sounds waits
//     until one second after the end of its last sound;
//   * every file of an event is found (or fetched) at its start; a flash is announced only once
//     the file of the sound it announces is ready (waiting up to [resolveTimeout]), so the crack
//     always follows its flash after the drawn delay; a file that cannot be had: that sound and
//     its flash are skipped, the rest of the event goes on;
//   * a swell (rain, wind) only after a strike that played;
//   * nothing during a pause, the end-of-timer fade or once stopped (the event in progress is
//     abandoned); level 0 or a muted sound category: no event, and the one sounding fades out.
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

/// The storm of an event sound in the mix (catalog `orage`), ready to play.
class StormLayer {
  const StormLayer({
    required this.parts,
    required this.weights,
    this.averseKeys = const [],
    this.rafaleKeys = const [],
  });

  /// Variants of each part type (published ones only).
  final Map<StormPart, List<EventVariant>> parts;

  /// `orage.sequences`.
  final Map<StormKind, double> weights;

  /// Engine keys of the audible loops of the mix that redouble after a strike (`orage.averse`)...
  final List<String> averseKeys;

  /// ...and of those that have a light gust (`orage.rafale`).
  final List<String> rafaleKeys;

  /// The kinds that can be drawn now. Empty: one variant per event.
  Map<StormKind, double> get drawable => StormRules.drawable(weights, {
        for (final e in parts.entries)
          if (e.value.isNotEmpty) e.key,
      });
}

/// A sound played by events in the mix, ready to play.
class EventLayer {
  const EventLayer({
    required this.key,
    required this.variants,
    required this.volume,
    this.interval = EventSound.defaultInterval,
    this.firstDelay = EventSound.defaultFirstDelay,
    this.storm,
  });

  /// Layer key, as for the loops (`son:tonnerre`).
  final String key;

  /// Every published variant (one is played per event without [storm]).
  final List<EventVariant> variants;

  /// 0..1: the level of the sound (0 when removed or muted: no event).
  final double volume;
  final SecondsRange interval;
  final SecondsRange firstDelay;

  /// Storm sequences (catalog `orage`), or null.
  final StormLayer? storm;

  @override
  String toString() => 'EventLayer($key, ${volume.toStringAsFixed(2)})';
}

/// A timer of the event in progress; cancelling it completes [done] with false.
class _Wait {
  _Wait(this.done);

  final Completer<bool> done;
  Timer? timer;

  void cancel() {
    timer?.cancel();
    if (!done.isCompleted) done.complete(false);
  }
}

class _State {
  _State(this.layer);

  EventLayer layer;

  /// When the next event starts (its first step: a flash or a sound).
  DateTime? due;
  Timer? next;

  /// Waits of the event in progress.
  final List<_Wait> waits = [];

  /// Variants played, oldest first (the last two are never replayed): single events...
  final List<String> recent = [];

  /// ...and per part type of the storm sequences.
  final Map<StormPart, List<String>> recentParts = {};

  /// Bumped whenever the schedule is redone: a stale callback or event does nothing.
  int generation = 0;

  void cancel() {
    next?.cancel();
    next = null;
    due = null;
    for (final w in waits.toList()) {
      w.cancel();
    }
    waits.clear();
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
  final StreamController<StormPlan> _sequences = StreamController<StormPlan>.broadcast();

  /// Listening (started and not paused, stopped or fading out).
  bool _running = false;

  /// End of the event sounding now (any layer): no other event before it.
  DateTime? _busyUntil;

  /// How long a flash waits for the file of its sound, and a sound for its file.
  static const Duration resolveTimeout = Duration(seconds: 5);

  /// An event starts at least this long after the end of the previous one.
  static const Duration eventGap = Duration(seconds: 1);

  /// A flash before each strike (contract § 11): the `eclairs` decor draws it.
  Stream<LightningStrike> get strikes => _strikes.stream;

  /// Each event as it starts (tests and logs).
  Stream<StormPlan> get sequences => _sequences.stream;

  bool get running => _running;

  /// When the next event of [key] starts (tests and logs).
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
    _sequences.close();
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
    s.cancel();
    if (s.layer.volume <= 0) return;
    _planNext(s, _now().add(s.layer.firstDelay.draw(_random)));
  }

  /// Plans the next event of [s] at [at] (not before the end of the one sounding).
  void _planNext(_State s, DateTime at) {
    s.next?.cancel();
    final busy = _busyUntil;
    if (busy != null && at.isBefore(busy)) at = busy.add(eventGap);
    s.due = at;
    final generation = s.generation;
    var wait = at.difference(_now());
    if (wait.isNegative) wait = Duration.zero;
    s.next = Timer(wait, () => _begin(s, generation));
  }

  void _begin(_State s, int generation) {
    if (!_alive(s, generation)) return;
    s.next = null;
    final now = _now();
    final busy = _busyUntil;
    if (busy != null && now.isBefore(busy)) {
      // Another event still sounds: this one waits for its end.
      _planNext(s, busy.add(eventGap));
      return;
    }
    final plan = _draw(s);
    if (plan == null) return;
    // No other event before the last step of this one (each sound pushes it to its own end).
    _extendBusy(now.add(plan.lastStepAt));
    _planNext(s, now.add(s.layer.interval.draw(_random)));
    if (!_sequences.isClosed) _sequences.add(plan);
    unawaited(_run(s, generation, plan, now));
  }

  /// The next event of [s]: a storm sequence when the catalog has `orage` and a kind can be
  /// drawn, else a single variant.
  StormPlan? _draw(_State s) {
    final storm = s.layer.storm;
    if (storm != null) {
      final kinds = storm.drawable;
      if (kinds.isNotEmpty) {
        final parts = {
          for (final e in storm.parts.entries)
            if (e.value.isNotEmpty) e.key: [for (final v in e.value) v.id],
        };
        return StormRules.plan(StormRules.drawKind(kinds, _random), parts, s.recentParts, _random);
      }
    }
    if (s.layer.variants.isEmpty) return null;
    return StormRules.singlePlan([for (final v in s.layer.variants) v.id], s.recent, _random);
  }

  EventVariant? _variantOf(EventLayer layer, StormSound sound) {
    final pool = sound.part == null ? layer.variants : (layer.storm?.parts[sound.part] ?? const <EventVariant>[]);
    for (final v in pool) {
      if (v.id == sound.variant) return v;
    }
    return null;
  }

  Future<void> _run(_State s, int generation, StormPlan plan, DateTime start) async {
    // Every file of the event is found (or fetched) now.
    final sources = <StormSound, Future<AudioSourceRef>>{};
    for (final sound in plan.sounds) {
      final variant = _variantOf(s.layer, sound);
      if (variant == null) continue;
      final source = variant.resolve();
      source.ignore();
      sources[sound] = source;
    }
    var shift = Duration.zero;
    final skipped = <StormSound>{};
    var struck = false;
    for (var i = 0; i < plan.steps.length; i++) {
      final step = plan.steps[i];
      if (!await _until(s, generation, start.add(step.at + shift))) return;
      switch (step) {
        case StormFlash():
          final announced = plan.announcedBy(i);
          if (announced != null) {
            // The flash waits for the file of its sound: the crack then comes on time.
            final before = _now();
            final ready = await _ready(sources[announced]);
            if (!_alive(s, generation)) return;
            if (!ready) {
              skipped.add(announced);
              continue;
            }
            shift += _now().difference(before);
          }
          if (!_strikes.isClosed) {
            _strikes.add(LightningStrike(at: _now(), thunderDelay: step.delay, intensity: step.intensity));
          }
        case StormSound():
          if (skipped.contains(step)) continue;
          final played = await _play(s, generation, step, sources[step]);
          if (!_alive(s, generation)) return;
          if (played && (step.part?.isStrike ?? false)) struck = true;
        case StormSwell():
          if (!struck) continue;
          final storm = s.layer.storm;
          final keys = step.target == SwellTarget.averse ? storm?.averseKeys : storm?.rafaleKeys;
          if (keys == null || keys.isEmpty) continue;
          unawaited(_engine
              .swell(keys, gainDb: step.gainDb, rise: step.rise, hold: step.hold, fall: step.fall)
              .catchError((Object e) => debugPrint('EventSoundScheduler: swell skipped ($e)')));
      }
    }
  }

  /// Waits until [at]; false if the event was abandoned meanwhile.
  Future<bool> _until(_State s, int generation, DateTime at) {
    if (!_alive(s, generation)) return Future<bool>.value(false);
    final wait = at.difference(_now());
    if (wait <= Duration.zero) return Future<bool>.value(true);
    final w = _Wait(Completer<bool>());
    w.timer = Timer(wait, () {
      s.waits.remove(w);
      if (!w.done.isCompleted) w.done.complete(_alive(s, generation));
    });
    s.waits.add(w);
    return w.done.future;
  }

  Future<bool> _ready(Future<AudioSourceRef>? source) async {
    if (source == null) return false;
    try {
      await source.timeout(resolveTimeout);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _play(_State s, int generation, StormSound sound, Future<AudioSourceRef>? source) async {
    try {
      if (source == null) throw StateError('unknown variant');
      final ref = await source.timeout(resolveTimeout);
      if (!_alive(s, generation)) return false;
      final length = await _engine.playEvent(
        s.layer.key,
        ref,
        volume: s.layer.volume,
        gain: sound.gain,
        speed: sound.speed,
        pan: sound.pan,
      );
      if (length == null) return false;
      final part = sound.part;
      final recent = part == null ? s.recent : (s.recentParts[part] ??= <String>[]);
      recent.add(sound.variant);
      if (recent.length > StormRules.noRepeat) recent.removeAt(0);
      _extendBusy(_now().add(length));
      return true;
    } catch (e) {
      // Not downloaded, offline, broken file: this sound is skipped, the event goes on.
      debugPrint('EventSoundScheduler: ${s.layer.key} ${sound.variant} skipped ($e)');
      return false;
    }
  }

  void _extendBusy(DateTime end) {
    final busy = _busyUntil;
    if (busy == null || end.isAfter(busy)) _busyUntil = end;
  }

  bool _alive(_State s, int generation) =>
      _running && s.generation == generation && identical(_states[s.layer.key], s) && s.layer.volume > 0;
}
