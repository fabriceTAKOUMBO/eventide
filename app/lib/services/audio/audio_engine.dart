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
///
/// A layer at volume 0 (its category is muted, `sourdine`) stays loaded but is parked: once
/// faded out it is paused, so it is no longer decoded; when its volume rises again it resumes
/// from where it stopped and fades back in (contract § 1).
class EngineLayer {
  const EngineLayer({
    required this.key,
    required this.source,
    required this.volume,
    this.fadeIn,
    this.resumeFade,
  });

  /// Stable identity of the layer in the mix, e.g. `son:eau-vive`.
  final String key;
  final AudioSourceRef source;
  final double volume;

  /// How long the layer takes to come in when it is not playing yet (start from silence,
  /// landscape change). Null: the engine's own fade (start fade, cross-fade, or
  /// [MixRules.newLayerFade] for a level change). Ignored for a layer already playing.
  final Duration? fadeIn;

  /// After a pause, the layer comes back from silence over this duration instead of following
  /// the short master fade ([MixRules.pauseFade]). Null: the master fade only.
  final Duration? resumeFade;

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

  /// Fade-in of an element added to a playing mix (slider, « Ajouter », assistant).
  static const Duration newLayerFade = Duration(seconds: 1);

  /// Fade of a whole category muted or unmuted (`sourdine`).
  static const Duration muteFade = Duration(seconds: 1);

  /// Progressive entry of the melodies when playback starts from silence or the landscape
  /// changes: the nature sounds come first, the music rises gently.
  static const Duration musicEntry = Duration(seconds: 20);

  /// The music comes back after a pause over this time (the sounds follow the master fade).
  static const Duration musicResume = Duration(seconds: 3);

  /// [EngineLayer.fadeIn] of a layer of [kind]: [musicEntry] for music when the mix starts
  /// from silence or changes landscape ([progressive]); otherwise the engine's own fade.
  static Duration? entryFade(LayerKind kind, {required bool progressive}) =>
      progressive && kind == LayerKind.musique ? musicEntry : null;

  /// [EngineLayer.resumeFade] of a layer of [kind].
  static Duration? resumeFadeOf(LayerKind kind) => kind == LayerKind.musique ? musicResume : null;

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
  /// offset (over their [EngineLayer.fadeIn] when set), kept ones fade to their new volume over
  /// [fade]. A layer going to volume 0 is parked after its fade (see [EngineLayer]).
  Future<void> update(List<EngineLayer> layers, {Duration fade});

  Future<void> pause();

  /// Resumes after [pause]: master fade of [MixRules.pauseFade]; layers with a
  /// [EngineLayer.resumeFade] (music) come back from silence over it. Parked layers stay parked.
  Future<void> resume();

  /// Fades the master volume to silence over [duration], then stops everything.
  Future<void> fadeOutAndStop(Duration duration);

  Future<void> stop();

  /// Lowers the output while another app needs it briefly.
  Future<void> setDucked(bool ducked);

  /// Plays [source] once, on top of the loops: one event of a sound played by events (a thunder,
  /// contract § 11), filed under its layer [key] (e.g. `son:tonnerre`). It sounds at
  /// [volume] × [gain] (the layer's volume, and the event's own random gain), at [speed] times
  /// its normal speed, at [pan] (−1 left to 1 right), and follows the master volume (ramp, duck,
  /// end-of-timer fade). A pause or a stop ends it. Returns how long it sounds (the file's
  /// length / [speed]), or null when nothing is playing (paused, stopped) or it cannot be played.
  Future<Duration?> playEvent(
    String key,
    AudioSourceRef source, {
    required double volume,
    double gain = 1.0,
    double speed = 1.0,
    double pan = 0.0,
  });

  /// Brings the events of [key] still sounding to the layer volume [volume] (each keeps its own
  /// gain) over [fade]; at 0 (sound removed or muted) they fade out, then stop.
  Future<void> setEventVolume(String key, double volume, {Duration fade = MixRules.levelFade});

  Future<void> dispose();
}
