// AudioEngine on flutter_soloud (miniaudio + SoLoud, Ogg Opus decoded on the phone).
//
// One looping voice per layer. Per-layer volume carries the mix; the global (master) volume
// carries the cap, the ramp-up of scheduled starts, ducking, pause fades and the end-of-timer
// fade. Files are streamed from disk (LoadMode.disk): a 3-minute loop decoded in memory would
// weigh ~60 MB per layer, far too much for an 8-hour night on an entry-level phone.
import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

import 'audio_engine.dart';

class _Voice {
  _Voice(this.layer, this.source, this.handle);

  EngineLayer layer;
  final AudioSource source;
  final SoundHandle handle;
}

class SoLoudAudioEngine implements AudioEngine {
  SoLoudAudioEngine({SoLoud? soloud, Random? random})
      : _soloud = soloud ?? SoLoud.instance,
        _random = random ?? Random();

  final SoLoud _soloud;
  final Random _random;

  final Map<String, _Voice> _voices = {};
  final Map<String, AudioSource> _sources = {};
  final Map<String, int> _sourceUsers = {};

  bool _paused = false;
  bool _ducked = false;

  // Master ramp: level goes linearly from _rampFrom to masterCap between _rampStart and _rampEnd.
  DateTime? _rampStart;
  DateTime? _rampEnd;
  double _rampFrom = 0;
  Timer? _rampResume;
  Timer? _drift;
  Timer? _stopTimer;
  Completer<void>? _fadeDone;

  /// Serializes engine operations (loading is asynchronous).
  Future<void> _queue = Future<void>.value();

  Future<T> _serial<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        completer.complete(await action());
      } catch (e, s) {
        completer.completeError(e, s);
      }
    });
    return completer.future;
  }

  @override
  bool get isPlaying => _voices.isNotEmpty && !_paused;

  @override
  bool get isPaused => _voices.isNotEmpty && _paused;

  @override
  Set<String> get activeKeys => Set.unmodifiable(_voices.keys);

  Future<void> _ensureInit() async {
    if (_soloud.isInitialized) return;
    // Larger buffer and no low-latency mode: nothing here is interactive, battery matters.
    await _soloud.init(bufferSize: 4096, lowLatency: false);
  }

  // ---- Master volume

  double _rampLevelAt(DateTime t) {
    final start = _rampStart;
    final end = _rampEnd;
    if (start == null || end == null || !t.isBefore(end)) return MixRules.masterCap;
    if (t.isBefore(start)) return _rampFrom;
    final total = end.difference(start).inMilliseconds;
    if (total <= 0) return MixRules.masterCap;
    final progress = t.difference(start).inMilliseconds / total;
    return _rampFrom + (MixRules.masterCap - _rampFrom) * progress;
  }

  double _targetMasterAt(DateTime t) => _rampLevelAt(t) * (_ducked ? MixRules.duckFactor : 1.0);

  /// Fades the master to where it should be after [fade], then continues an unfinished ramp.
  void _applyMaster(Duration fade) {
    _rampResume?.cancel();
    final now = DateTime.now();
    final at = now.add(fade);
    _safe(() => _soloud.fadeGlobalVolume(_targetMasterAt(at), fade));
    final end = _rampEnd;
    if (end != null && at.isBefore(end)) {
      _rampResume = Timer(fade, () {
        if (_paused || _voices.isEmpty) return;
        final remaining = end.difference(DateTime.now());
        if (remaining > Duration.zero) {
          _safe(() => _soloud.fadeGlobalVolume(MixRules.masterCap * (_ducked ? MixRules.duckFactor : 1.0), remaining));
        }
      });
    }
  }

  void _safe(void Function() action) {
    try {
      action();
    } catch (e) {
      debugPrint('SoLoudAudioEngine: $e');
    }
  }

  // ---- Sources

  Future<AudioSource> _acquire(AudioSourceRef ref) async {
    final key = ref.cacheKey;
    final existing = _sources[key];
    if (existing != null) {
      _sourceUsers[key] = (_sourceUsers[key] ?? 0) + 1;
      return existing;
    }
    final source = switch (ref) {
      AssetAudioSource(:final assetKey) => await _soloud.loadAsset(assetKey, mode: LoadMode.disk),
      FileAudioSource(:final path) => await _soloud.loadFile(path, mode: LoadMode.disk),
    };
    _sources[key] = source;
    _sourceUsers[key] = 1;
    return source;
  }

  Future<void> _release(AudioSourceRef ref) async {
    final key = ref.cacheKey;
    final users = (_sourceUsers[key] ?? 1) - 1;
    if (users > 0) {
      _sourceUsers[key] = users;
      return;
    }
    _sourceUsers.remove(key);
    final source = _sources.remove(key);
    if (source != null) {
      try {
        await _soloud.disposeSource(source);
      } catch (e) {
        debugPrint('SoLoudAudioEngine: dispose failed ($e)');
      }
    }
  }

  // ---- Voices

  Future<void> _startVoice(EngineLayer layer, Duration fadeIn) async {
    try {
      final source = await _acquire(layer.source);
      final handle = _soloud.play(source, volume: 0, looping: true, paused: true);
      // Random start offset: two layers never line up the same way twice (no audible repetition).
      final length = _soloud.getLength(source);
      if (length > const Duration(seconds: 4)) {
        final offset = Duration(milliseconds: _random.nextInt((length.inMilliseconds * 0.9).floor()));
        _safe(() => _soloud.seek(handle, offset));
      }
      _safe(() => _soloud.setProtectVoice(handle, true));
      if (!_paused) _safe(() => _soloud.setPause(handle, false));
      _safe(() => _soloud.fadeVolume(handle, layer.volume, fadeIn));
      _voices[layer.key] = _Voice(layer, source, handle);
    } catch (e) {
      // A missing or broken file never stops the other layers.
      debugPrint('SoLoudAudioEngine: cannot start ${layer.key} ($e)');
    }
  }

  void _fadeOutVoice(_Voice voice, Duration fade) {
    _safe(() => _soloud.fadeVolume(voice.handle, 0, fade));
    // The voice is already out of _voices: a layer with the same key may start meanwhile with
    // its own handle; this one only finishes its fade, then stops and releases its source.
    Timer(fade + const Duration(milliseconds: 50), () {
      _serial(() async {
        try {
          await _soloud.stop(voice.handle);
        } catch (_) {}
        await _release(voice.layer.source);
      });
    });
  }

  Future<void> _applyLayers(List<EngineLayer> layers, Duration fade) async {
    final wanted = {for (final l in layers) l.key: l};
    for (final key in _voices.keys.toList()) {
      final voice = _voices[key]!;
      final next = wanted[key];
      if (next == null || next.source != voice.layer.source) {
        _voices.remove(key);
        _fadeOutVoice(voice, fade);
      }
    }
    for (final layer in layers) {
      final voice = _voices[layer.key];
      if (voice == null) {
        await _startVoice(layer, fade < MixRules.crossFade ? const Duration(seconds: 1) : fade);
      } else if ((voice.layer.volume - layer.volume).abs() > 0.001) {
        voice.layer = layer;
        _safe(() => _soloud.fadeVolume(voice.handle, layer.volume, fade));
      }
    }
  }

  /// Slight slow random volume variations (dossier § 8), around each layer's own volume.
  void _startDrift() {
    _drift?.cancel();
    _drift = Timer.periodic(const Duration(seconds: 25), (_) {
      if (_paused) return;
      for (final voice in _voices.values) {
        final factor = 0.93 + _random.nextDouble() * 0.07;
        _safe(() => _soloud.fadeVolume(voice.handle, voice.layer.volume * factor, const Duration(seconds: 20)));
      }
    });
  }

  // ---- AudioEngine

  @override
  Future<void> start(
    List<EngineLayer> layers, {
    Duration fadeIn = const Duration(seconds: 2),
    Duration rampUp = Duration.zero,
  }) {
    return _serial(() async {
      await _ensureInit();
      if (_voices.isNotEmpty && !_paused) {
        await _applyLayers(layers, MixRules.crossFade);
        return;
      }
      if (_paused) {
        _paused = false;
        for (final v in _voices.values) {
          _safe(() => _soloud.setPause(v.handle, false));
        }
      }
      final now = DateTime.now();
      if (rampUp > Duration.zero) {
        _rampFrom = 0;
        _rampStart = now;
        _rampEnd = now.add(rampUp);
      } else {
        _rampStart = null;
        _rampEnd = null;
      }
      _safe(() => _soloud.setGlobalVolume(0));
      await _applyLayers(layers, fadeIn);
      _applyMaster(rampUp > Duration.zero ? rampUp : fadeIn);
      _startDrift();
    });
  }

  @override
  Future<void> update(List<EngineLayer> layers, {Duration fade = MixRules.levelFade}) {
    return _serial(() async {
      if (!_soloud.isInitialized) return;
      await _applyLayers(layers, fade);
    });
  }

  @override
  Future<void> pause() {
    return _serial(() async {
      if (_voices.isEmpty || _paused) return;
      _paused = true;
      _rampResume?.cancel();
      _safe(() => _soloud.fadeGlobalVolume(0, MixRules.pauseFade));
      await Future<void>.delayed(MixRules.pauseFade);
      if (!_paused) return;
      for (final v in _voices.values) {
        _safe(() => _soloud.setPause(v.handle, true));
      }
    });
  }

  @override
  Future<void> resume() {
    return _serial(() async {
      if (_voices.isEmpty || !_paused) return;
      _paused = false;
      for (final v in _voices.values) {
        _safe(() => _soloud.setPause(v.handle, false));
      }
      _applyMaster(MixRules.pauseFade);
    });
  }

  @override
  Future<void> fadeOutAndStop(Duration duration) {
    return _serial(() async {
      if (_voices.isEmpty) return;
      _rampResume?.cancel();
      _rampStart = null;
      _rampEnd = null;
      _safe(() => _soloud.fadeGlobalVolume(0, duration));
      final done = _fadeDone = Completer<void>();
      _stopTimer?.cancel();
      _stopTimer = Timer(duration, () {
        if (!done.isCompleted) done.complete();
      });
      await done.future;
      _fadeDone = null;
      await _stopAll();
    });
  }

  @override
  Future<void> stop() {
    // Ends a running fade-out at once (its queued stop then runs immediately).
    _stopTimer?.cancel();
    final fade = _fadeDone;
    if (fade != null && !fade.isCompleted) fade.complete();
    return _serial(_stopAll);
  }

  Future<void> _stopAll() async {
    _drift?.cancel();
    _rampResume?.cancel();
    _rampStart = null;
    _rampEnd = null;
    final voices = _voices.values.toList();
    _voices.clear();
    _paused = false;
    for (final v in voices) {
      try {
        await _soloud.stop(v.handle);
      } catch (_) {}
      await _release(v.layer.source);
    }
  }

  @override
  Future<void> setDucked(bool ducked) async {
    if (_ducked == ducked) return;
    _ducked = ducked;
    if (_voices.isNotEmpty && !_paused && _soloud.isInitialized) {
      _applyMaster(const Duration(milliseconds: 500));
    }
  }

  @override
  Future<void> dispose() async {
    await stop();
    for (final source in _sources.values.toList()) {
      try {
        await _soloud.disposeSource(source);
      } catch (_) {}
    }
    _sources.clear();
    _sourceUsers.clear();
  }
}
