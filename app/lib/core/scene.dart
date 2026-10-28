// The scene document (contract §1, annex A of the dossier): everything that
// is playing, stored locally, shared by link and edited by the assistant.

import 'catalog.dart';

/// Time of day of the landscape light.
enum Moment {
  aube,
  jour,
  soir,
  nuit;

  /// French label (« Aube », « Jour », « Soir », « Nuit »).
  String get label => switch (this) {
    Moment.aube => 'Aube',
    Moment.jour => 'Jour',
    Moment.soir => 'Soir',
    Moment.nuit => 'Nuit',
  };

  static Moment? fromName(Object? value) {
    for (final m in Moment.values) {
      if (m.name == value) return m;
    }
    return null;
  }
}

/// One active element: a sound, a music or a decor effect, with its level
/// (volume or intensity, 0–100).
class Layer {
  const Layer({required this.id, required this.level});

  final String id;
  final int level;

  Map<String, dynamic> toJson() => {'id': id, 'niveau': level};

  /// Throws [FormatException] when `id` is missing. A missing or invalid
  /// `niveau` defaults to 50; it is clamped to 0–100.
  factory Layer.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('layer: "id" must be a non-empty string');
    }
    final level = json['niveau'];
    return Layer(
      id: id,
      level: level is num && level.isFinite ? level.round().clamp(0, 100) : 50,
    );
  }

  Layer copyWith({String? id, int? level}) =>
      Layer(id: id ?? this.id, level: level ?? this.level);

  @override
  bool operator ==(Object other) =>
      other is Layer && other.id == id && other.level == level;

  @override
  int get hashCode => Object.hash(id, level);

  @override
  String toString() => 'Layer($id, $level)';
}

/// The listening timer (`minuteur`).
sealed class TimerSetting {
  const TimerSetting();

  /// Maximum duration of a `duree` timer, in minutes (contract §1).
  static const int maxMinutes = 600;

  Map<String, dynamic> toJson();

  /// Parses a timer object. Throws [FormatException] when invalid.
  factory TimerSetting.fromJson(Map<String, dynamic> json) {
    final parsed = tryParse(json);
    if (parsed == null) throw FormatException('invalid timer: $json');
    return parsed;
  }

  /// Parses a timer object; returns null when it does not follow the
  /// contract (`duree` needs an integer `minutes` in 1–600).
  static TimerSetting? tryParse(Object? json) {
    if (json is! Map) return null;
    switch (json['mode']) {
      case 'duree':
        final minutes = json['minutes'];
        final value = minutes is int
            ? minutes
            : (minutes is double && minutes == minutes.roundToDouble()
                  ? minutes.toInt()
                  : null);
        if (value == null || value < 1 || value > maxMinutes) return null;
        return TimerDuration(value);
      case 'nuit':
        return const TimerNight();
      case 'aucun':
        return const TimerNone();
    }
    return null;
  }
}

/// Stops after [minutes] (1–600).
final class TimerDuration extends TimerSetting {
  const TimerDuration(this.minutes);

  final int minutes;

  Duration get duration => Duration(minutes: minutes);

  @override
  Map<String, dynamic> toJson() => {'mode': 'duree', 'minutes': minutes};

  @override
  bool operator ==(Object other) =>
      other is TimerDuration && other.minutes == minutes;

  @override
  int get hashCode => Object.hash('duree', minutes);

  @override
  String toString() => 'TimerDuration($minutes)';
}

/// « Toute la nuit »: stops after `limites.nuit_max_heures`.
final class TimerNight extends TimerSetting {
  const TimerNight();

  @override
  Map<String, dynamic> toJson() => {'mode': 'nuit'};

  @override
  bool operator ==(Object other) => other is TimerNight;

  @override
  int get hashCode => 'nuit'.hashCode;

  @override
  String toString() => 'TimerNight()';
}

/// « Sans minuteur ».
final class TimerNone extends TimerSetting {
  const TimerNone();

  @override
  Map<String, dynamic> toJson() => {'mode': 'aucun'};

  @override
  bool operator ==(Object other) => other is TimerNone;

  @override
  int get hashCode => 'aucun'.hashCode;

  @override
  String toString() => 'TimerNone()';
}

/// The scene document. Immutable: every change returns a new scene, so the
/// caller can keep the previous one for « Annuler ».
class Scene {
  Scene({
    this.version = currentVersion,
    required this.landscapeId,
    this.moment = Moment.jour,
    List<Layer> sounds = const [],
    List<Layer> music = const [],
    List<Layer> decor = const [],
    this.timer = defaultTimer,
    this.sleepTracking = false,
  }) : sounds = List.unmodifiable(sounds),
       music = List.unmodifiable(music),
       decor = List.unmodifiable(decor);

  static const int currentVersion = 1;

  /// Default of `limites.couches_max` when no catalog is at hand.
  static const int defaultMaxAudioLayers = 6;

  /// The default timer is 1 h (dossier, section 6).
  static const TimerSetting defaultTimer = TimerDuration(60);

  /// Level given to an element added without an explicit level.
  static const int defaultLevel = 50;

  final int version;
  final String landscapeId;
  final Moment moment;
  final List<Layer> sounds;
  final List<Layer> music;
  final List<Layer> decor;
  final TimerSetting timer;

  /// `sommeil.suivi`.
  final bool sleepTracking;

  /// A scene showing [landscape] with its default mix.
  factory Scene.fromLandscape(
    Landscape landscape, {
    Moment moment = Moment.jour,
    TimerSetting timer = defaultTimer,
    bool sleepTracking = false,
  }) {
    return Scene(
      landscapeId: landscape.id,
      moment: moment,
      sounds: landscape.defaultMix[LayerKind.son] ?? const [],
      music: landscape.defaultMix[LayerKind.musique] ?? const [],
      decor: landscape.defaultMix[LayerKind.decor] ?? const [],
      timer: timer,
      sleepTracking: sleepTracking,
    );
  }

  /// Switches to [landscape] and loads its default mix, keeping the moment,
  /// the timer and the sleep tracking.
  Scene withLandscape(Landscape landscape) => Scene.fromLandscape(
    landscape,
    moment: moment,
    timer: timer,
    sleepTracking: sleepTracking,
  );

  List<Layer> layers(LayerKind kind) => switch (kind) {
    LayerKind.son => sounds,
    LayerKind.musique => music,
    LayerKind.decor => decor,
  };

  /// Number of sounds + music (bounded by `couches_max`).
  int get audioLayerCount => sounds.length + music.length;

  bool hasLayer(LayerKind kind, String id) =>
      layers(kind).any((l) => l.id == id);

  /// Level of an active element, or null when it is not in the scene.
  int? levelOf(LayerKind kind, String id) {
    for (final l in layers(kind)) {
      if (l.id == id) return l.level;
    }
    return null;
  }

  /// Sets the level of an element, adding it when absent.
  ///
  /// The level is clamped to 0–100 and 0 removes the element. Adding a new
  /// sound or music when [audioLayerCount] already reached [maxAudioLayers]
  /// is refused: the same scene instance is returned.
  Scene withLevel(
    LayerKind kind,
    String id,
    int level, {
    int maxAudioLayers = defaultMaxAudioLayers,
  }) {
    final clamped = level.clamp(0, 100);
    if (clamped == 0) return withoutLayer(kind, id);
    final current = layers(kind);
    final index = current.indexWhere((l) => l.id == id);
    if (index >= 0) {
      if (current[index].level == clamped) return this;
      final updated = [...current];
      updated[index] = Layer(id: id, level: clamped);
      return _withLayers(kind, updated);
    }
    if (kind.isAudio && audioLayerCount >= maxAudioLayers) return this;
    return _withLayers(kind, [...current, Layer(id: id, level: clamped)]);
  }

  /// Removes an element; `'*'` removes every element of [kind].
  Scene withoutLayer(LayerKind kind, String id) {
    final current = layers(kind);
    if (id == '*') return current.isEmpty ? this : _withLayers(kind, const []);
    if (!current.any((l) => l.id == id)) return this;
    return _withLayers(kind, [
      for (final l in current)
        if (l.id != id) l,
    ]);
  }

  Scene _withLayers(LayerKind kind, List<Layer> list) => switch (kind) {
    LayerKind.son => copyWith(sounds: list),
    LayerKind.musique => copyWith(music: list),
    LayerKind.decor => copyWith(decor: list),
  };

  Scene copyWith({
    int? version,
    String? landscapeId,
    Moment? moment,
    List<Layer>? sounds,
    List<Layer>? music,
    List<Layer>? decor,
    TimerSetting? timer,
    bool? sleepTracking,
  }) {
    return Scene(
      version: version ?? this.version,
      landscapeId: landscapeId ?? this.landscapeId,
      moment: moment ?? this.moment,
      sounds: sounds ?? this.sounds,
      music: music ?? this.music,
      decor: decor ?? this.decor,
      timer: timer ?? this.timer,
      sleepTracking: sleepTracking ?? this.sleepTracking,
    );
  }

  Map<String, dynamic> toJson() => {
    'version': version,
    'paysage': landscapeId,
    'moment': moment.name,
    'sons': [for (final l in sounds) l.toJson()],
    'musique': [for (final l in music) l.toJson()],
    'decor': [for (final l in decor) l.toJson()],
    'minuteur': timer.toJson(),
    'sommeil': {'suivi': sleepTracking},
  };

  /// Parses a stored scene document. Throws [FormatException] when
  /// `paysage` is missing; other fields fall back to their defaults, invalid
  /// layers are skipped and duplicate ids keep their first occurrence.
  /// Catalog membership is not checked here (see `decodeSceneFromLink`).
  factory Scene.fromJson(Map<String, dynamic> json) {
    final landscapeId = json['paysage'];
    if (landscapeId is! String || landscapeId.isEmpty) {
      throw const FormatException('scene: "paysage" must be a string');
    }
    List<Layer> parseLayers(LayerKind kind) {
      final list = json[kind.sceneKey];
      if (list is! List) return const [];
      final seen = <String>{};
      final out = <Layer>[];
      for (final entry in list) {
        if (entry is! Map) continue;
        final Layer layer;
        try {
          layer = Layer.fromJson(Map<String, dynamic>.from(entry));
        } on FormatException {
          continue;
        }
        if (layer.level > 0 && seen.add(layer.id)) out.add(layer);
      }
      return out;
    }

    final version = json['version'];
    final sleep = json['sommeil'];
    return Scene(
      version: version is int ? version : currentVersion,
      landscapeId: landscapeId,
      moment: Moment.fromName(json['moment']) ?? Moment.jour,
      sounds: parseLayers(LayerKind.son),
      music: parseLayers(LayerKind.musique),
      decor: parseLayers(LayerKind.decor),
      timer: TimerSetting.tryParse(json['minuteur']) ?? defaultTimer,
      sleepTracking: sleep is Map && sleep['suivi'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Scene &&
      other.version == version &&
      other.landscapeId == landscapeId &&
      other.moment == moment &&
      _listEquals(other.sounds, sounds) &&
      _listEquals(other.music, music) &&
      _listEquals(other.decor, decor) &&
      other.timer == timer &&
      other.sleepTracking == sleepTracking;

  @override
  int get hashCode => Object.hash(
    version,
    landscapeId,
    moment,
    Object.hashAll(sounds),
    Object.hashAll(music),
    Object.hashAll(decor),
    timer,
    sleepTracking,
  );

  @override
  String toString() => 'Scene(${toJson()})';
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
