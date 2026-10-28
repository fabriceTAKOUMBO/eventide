// In-memory AudioEngine for tests and for running the UI without audio.
import 'audio_engine.dart';

class FakeAudioEngine implements AudioEngine {
  final List<String> calls = [];
  List<EngineLayer> layers = const [];
  bool _paused = false;
  bool ducked = false;
  Duration? lastRampUp;
  Duration? lastFade;

  /// Fade each layer came in with, decided like the real engine: the layer's own
  /// [EngineLayer.fadeIn], else the start fade, the cross-fade or [MixRules.newLayerFade].
  final Map<String, Duration> entryFades = {};

  /// Keys of the layers at volume 0 (muted category): loaded but parked.
  Set<String> get parkedKeys => {
        for (final l in layers)
          if (l.volume <= 0) l.key,
      };

  void _enter(List<EngineLayer> next, Duration Function(EngineLayer) fade) {
    final before = activeKeys;
    entryFades.removeWhere((key, _) => !next.any((l) => l.key == key));
    for (final l in next) {
      if (!before.contains(l.key)) entryFades[l.key] = l.fadeIn ?? fade(l);
    }
  }

  @override
  bool get isPlaying => layers.isNotEmpty && !_paused;

  @override
  bool get isPaused => layers.isNotEmpty && _paused;

  @override
  Set<String> get activeKeys => {for (final l in layers) l.key};

  double volumeOf(String key) {
    for (final l in layers) {
      if (l.key == key) return l.volume;
    }
    return 0;
  }

  @override
  Future<void> start(
    List<EngineLayer> layers, {
    Duration fadeIn = const Duration(seconds: 2),
    Duration rampUp = Duration.zero,
  }) async {
    final crossFade = this.layers.isNotEmpty && !_paused;
    calls.add(crossFade ? 'crossfade' : 'start');
    _enter(layers, (_) => crossFade ? MixRules.crossFade : fadeIn);
    this.layers = List.of(layers);
    _paused = false;
    lastRampUp = crossFade ? null : rampUp;
  }

  @override
  Future<void> update(List<EngineLayer> layers, {Duration fade = MixRules.levelFade}) async {
    calls.add('update');
    lastFade = fade;
    _enter(layers, (_) => fade < MixRules.crossFade ? MixRules.newLayerFade : fade);
    this.layers = List.of(layers);
  }

  @override
  Future<void> pause() async {
    if (layers.isEmpty) return;
    calls.add('pause');
    _paused = true;
  }

  @override
  Future<void> resume() async {
    if (layers.isEmpty) return;
    calls.add('resume');
    _paused = false;
  }

  @override
  Future<void> fadeOutAndStop(Duration duration) async {
    calls.add('fadeOut:${duration.inSeconds}');
    lastFade = duration;
    layers = const [];
    _paused = false;
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    layers = const [];
    _paused = false;
  }

  @override
  Future<void> setDucked(bool ducked) async {
    calls.add(ducked ? 'duck' : 'unduck');
    this.ducked = ducked;
  }

  @override
  Future<void> dispose() async {
    layers = const [];
  }
}
