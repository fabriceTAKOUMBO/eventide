// Audio engine contract: one looping voice per audio layer, mixed on the phone.
// Implementations: SoLoudAudioEngine (flutter_soloud) and FakeAudioEngine (tests).
import '../../core/catalog.dart';

/// Where the audio of a layer comes from (resolved by ContentRepository).
sealed class AudioSourceRef {
  const AudioSourceRef();

  /// Identifies the underlying file, so two layers never load the same file twice.
  String get cacheKey;
}

/// Bundled with the app (`assets/audio/<sons|musiques>/<id>.ogg`).
class AssetAudioSource extends AudioSourceRef {
  const AssetAudioSource(this.assetKey);

  final String assetKey;

  @override
  String get cacheKey => 'asset:$assetKey';

  @override
  bool operator ==(Object other) => other is AssetAudioSource && other.assetKey == assetKey;

  @override
  int get hashCode => assetKey.hashCode;

  @override
  String toString() => 'AssetAudioSource($assetKey)';
}

/// Downloaded file (cache, or Premium offline content).
class FileAudioSource extends AudioSourceRef {
  const FileAudioSource(this.path);

  final String path;

  @override
  String get cacheKey => 'file:$path';

  @override
  bool operator ==(Object other) => other is FileAudioSource && other.path == path;

  @override
  int get hashCode => path.hashCode;

  @override
  String toString() => 'FileAudioSource($path)';
}

/// A layer ready to play: [volume] is the final per-layer gain in 0..1.
class EngineLayer {
  const EngineLayer({required this.key, required this.source, required this.volume});

  /// Stable identity of the layer in the mix, e.g. `son:eau-vive`.
  final String key;
  final AudioSourceRef source;
  final double volume;

  @override
  String toString() => 'EngineLayer($key, ${volume.toStringAsFixed(2)})';
}

/// Mixing rules (dossier § 8: levels normalised at production, per-layer volume, capped master).
abstract final class MixRules {
  /// Global output never goes above this, whatever the layer levels.
  static const double masterCap = 0.85;

  /// Music sits under nature sounds by default.
  static double categoryGain(LayerKind kind) => switch (kind) {
        LayerKind.son => 1.0,
        LayerKind.musique => 0.8,
        LayerKind.decor => 0.0,
      };

  /// Level 0..100 of the scene → engine volume 0..1.
  static double layerVolume(LayerKind kind, int level) => (level.clamp(0, 100) / 100.0) * categoryGain(kind);

  static String layerKey(LayerKind kind, String id) => '${kind.cible}:$id';

  /// Volume while ducked (another app speaks briefly: navigation, notification).
  static const double duckFactor = 0.3;

  /// Cross-fade when the landscape changes.
  static const Duration crossFade = Duration(seconds: 2);

  /// Fade for a slider or button change in « Mon mix ».
  static const Duration levelFade = Duration(milliseconds: 400);

  /// Fade at the end of the timer, then full stop (dossier, screen 2).
  static const Duration timerFadeOut = Duration(seconds: 30);

  /// Short fades around pause and resume, so nothing clicks.
  static const Duration pauseFade = Duration(milliseconds: 400);
}

abstract class AudioEngine {
  /// Voices exist and are not paused.
  bool get isPlaying;

  /// Voices exist but are paused.
  bool get isPaused;

  /// Keys of the layers currently loaded.
  Set<String> get activeKeys;

  /// Starts [layers] from silence: fade in over [fadeIn], or ramp up the master volume over
  /// [rampUp] (scheduled starts). When already playing, behaves like [update] with a cross-fade.
  Future<void> start(List<EngineLayer> layers, {Duration fadeIn, Duration rampUp});

  /// Brings the playing mix to [layers]: removed layers fade out, new ones fade in from a random
  /// offset, kept ones fade to their new volume over [fade].
  Future<void> update(List<EngineLayer> layers, {Duration fade});

  Future<void> pause();
  Future<void> resume();

  /// Fades the master volume to silence over [duration], then stops everything.
  Future<void> fadeOutAndStop(Duration duration);

  Future<void> stop();

  /// Lowers the output while another app needs it briefly.
  Future<void> setDucked(bool ducked);

  Future<void> dispose();
}
