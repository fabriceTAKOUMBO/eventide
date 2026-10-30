// Closed catalog of landscapes, sounds, music, decor effects and limits.
//
// Source of truth: `assets/catalog.json` (shared with the API). The JSON keys
// are French (`nom`, `gratuit`, `alias`, `limites`...), the Dart API is English.

import 'dart:math' as math;

import 'lightning.dart';
import 'scene.dart';

/// The three kinds of layers a scene can hold.
///
/// [cible] is the value used by assistant operations (`son`, `musique`,
/// `decor`), [sceneKey] the key in the scene document (`sons`, `musique`,
/// `decor`) and [catalogKey] the list in `catalog.json` (`sons`, `musiques`,
/// `decors`).
enum LayerKind {
  son('son', 'sons', 'sons'),
  musique('musique', 'musique', 'musiques'),
  decor('decor', 'decor', 'decors');

  const LayerKind(this.cible, this.sceneKey, this.catalogKey);

  /// Value of the `cible` field in assistant operations.
  final String cible;

  /// Key of the layer list in the scene document.
  final String sceneKey;

  /// Key of the item list in `catalog.json`.
  final String catalogKey;

  /// Sounds and music are audio layers (they count toward `couches_max`).
  bool get isAudio => this != LayerKind.decor;

  /// French label of the tab in « Mon mix ».
  String get label => switch (this) {
    LayerKind.son => 'Sons',
    LayerKind.musique => 'Musique',
    LayerKind.decor => 'Décor',
  };

  /// Parses an operation `cible`; returns null when it is not a layer kind.
  static LayerKind? fromCible(Object? value) {
    for (final kind in LayerKind.values) {
      if (kind.cible == value) return kind;
    }
    return null;
  }
}

/// A `[min, max]` range of seconds of the catalog (`intervalle_s`, `premier_s`), `0 < min <= max`.
class SecondsRange {
  const SecondsRange(this.min, this.max);

  final double min;
  final double max;

  /// A duration drawn uniformly in the range.
  Duration draw(math.Random random) =>
      Duration(microseconds: ((min + (max - min) * random.nextDouble()) * 1e6).round());

  /// Parses `[min, max]`; null unless both are numbers with `0 < min <= max`.
  static SecondsRange? fromJson(Object? json) {
    if (json is! List || json.length != 2) return null;
    final [lo, hi] = json;
    if (lo is! num || hi is! num || lo <= 0 || lo > hi) return null;
    return SecondsRange(lo.toDouble(), hi.toDouble());
  }

  @override
  bool operator ==(Object other) => other is SecondsRange && other.min == min && other.max == max;

  @override
  int get hashCode => Object.hash(min, max);

  @override
  String toString() => '[$min, $max] s';
}

/// How a sound is played (`lecture`, contract § 11).
enum Playback {
  /// `boucle` (default): one seamless loop.
  loop,

  /// `evenements`: short sounds now and then ([EventSound]), never twice the same.
  events,
}

/// The event part of a sound played by events (contract § 11): its variant files
/// (`audio/sons/<variant>.ogg`), the random gap between two events and the delay of the first.
class EventSound {
  EventSound({
    required List<String> variants,
    this.interval = defaultInterval,
    this.firstDelay = defaultFirstDelay,
    this.storm,
  }) : variants = List.unmodifiable(variants);

  /// Every file of the sound (`variantes`), the parts of [storm] included.
  final List<String> variants;

  /// `orage`: each event is a storm sequence of these parts; null: each event is one variant.
  final StormSpec? storm;

  /// `intervalle_s`: gap drawn at random between two events.
  final SecondsRange interval;

  /// `premier_s`: delay of the first event after the start, a resume or the addition of the sound.
  final SecondsRange firstDelay;

  static const SecondsRange defaultInterval = SecondsRange(120, 300);
  static const SecondsRange defaultFirstDelay = SecondsRange(45, 120);
}

/// `orage` of a sound played by events (contract § 11): its parts by type, the weights of the
/// kinds of sequences, and the loops that swell after a strong strike.
class StormSpec {
  StormSpec({
    required Map<StormPart, List<String>> parts,
    required Map<StormKind, double> weights,
    List<String> averse = const [],
    List<String> rafale = const [],
  })  : parts = Map.unmodifiable({for (final e in parts.entries) e.key: List<String>.unmodifiable(e.value)}),
        weights = Map.unmodifiable(weights),
        averse = List.unmodifiable(averse),
        rafale = List.unmodifiable(rafale);

  /// `parties`: variant ids per type (only known types, ids of `variantes`, never empty).
  final Map<StormPart, List<String>> parts;

  /// `sequences`: weight (> 0) of each kind.
  final Map<StormKind, double> weights;

  /// `averse`: sounds (loops) that redouble after a strike.
  final List<String> averse;

  /// `rafale`: sounds (loops) that have a light gust after a strike.
  final List<String> rafale;

  /// The kinds that can be drawn (their required part is there). Empty: one variant per event.
  Map<StormKind, double> get drawable => StormRules.drawable(weights, parts.keys.toSet());

  /// Parses `orage`; null unless it is an object. Unknown types and kinds, ids not in
  /// [variants] and weights that are not numbers above 0 are left out.
  static StormSpec? fromJson(Object? json, List<String> variants) {
    if (json is! Map) return null;
    final parts = <StormPart, List<String>>{};
    final rawParts = json['parties'];
    if (rawParts is Map) {
      for (final e in rawParts.entries) {
        final part = StormPart.fromKey(e.key);
        if (part == null) continue;
        final ids = <String>[];
        for (final id in _stringList(e.value)) {
          if (variants.contains(id) && !ids.contains(id)) ids.add(id);
        }
        if (ids.isNotEmpty) parts[part] = ids;
      }
    }
    final weights = <StormKind, double>{};
    final rawWeights = json['sequences'];
    if (rawWeights is Map) {
      for (final e in rawWeights.entries) {
        final kind = StormKind.fromKey(e.key);
        final w = e.value;
        if (kind != null && w is num && w > 0) weights[kind] = w.toDouble();
      }
    }
    return StormSpec(
      parts: parts,
      weights: weights,
      averse: _stringList(json['averse']),
      rafale: _stringList(json['rafale']),
    );
  }
}

/// A sound, a music or a decor effect of the catalog.
class CatalogItem {
  CatalogItem({
    required this.id,
    required this.name,
    required this.free,
    required List<String> aliases,
    required this.kind,
    this.landscapeId,
    this.events,
  }) : aliases = List.unmodifiable(aliases);

  final String id;

  /// French display name (`nom`).
  final String name;

  /// Available on the free plan (`gratuit`).
  final bool free;

  /// Spoken forms (`alias`), lowercase French.
  final List<String> aliases;

  final LayerKind kind;

  /// `paysage`: the landscape this sound belongs to (its ambiance, the sound of its video,
  /// contract § 11). « Mon mix » offers it only with that landscape. Null for every other item.
  final String? landscapeId;

  /// Played by events (`lecture: evenements`), or null for a loop.
  final EventSound? events;

  Playback get playback => events == null ? Playback.loop : Playback.events;

  /// The ambiance of a landscape (see [landscapeId]).
  bool get isAmbiance => landscapeId != null;

  /// « Mon mix » lists this item next to [landscape]: everything except the ambiance of
  /// another landscape.
  bool offeredWith(String landscape) => landscapeId == null || landscapeId == landscape;

  factory CatalogItem.fromJson(Map<String, dynamic> json, LayerKind kind) {
    final id = _string(json, 'id');
    final landscape = json['paysage'];
    EventSound? events;
    if (kind == LayerKind.son && json['lecture'] == 'evenements') {
      final variants = _stringList(json['variantes']);
      events = EventSound(
        // A sound by events without variants plays its own file.
        variants: variants.isEmpty ? [id] : variants,
        interval: SecondsRange.fromJson(json['intervalle_s']) ?? EventSound.defaultInterval,
        firstDelay: SecondsRange.fromJson(json['premier_s']) ?? EventSound.defaultFirstDelay,
        storm: StormSpec.fromJson(json['orage'], variants),
      );
    }
    return CatalogItem(
      id: id,
      name: _string(json, 'nom'),
      free: json['gratuit'] == true,
      aliases: _stringList(json['alias']),
      kind: kind,
      landscapeId: landscape is String && landscape.isNotEmpty ? landscape : null,
      events: events,
    );
  }

  @override
  String toString() => 'CatalogItem(${kind.cible}:$id)';
}

/// A theme (column of landscapes on the home screen).
class ThemeInfo {
  const ThemeInfo({required this.id, required this.name});

  final String id;
  final String name;

  factory ThemeInfo.fromJson(Map<String, dynamic> json) =>
      ThemeInfo(id: _string(json, 'id'), name: _string(json, 'nom'));

  @override
  String toString() => 'ThemeInfo($id)';
}

/// How a landscape is shown (`rendu`, contract § 12).
enum LandscapeRendering {
  /// `video` (default): a real filmed landscape with its own sound. Its decor cannot be changed.
  video,

  /// `3d`: an imaginary scene drawn live (`assets/imaginaire/`), whose decor the user edits.
  scene3d;

  static LandscapeRendering fromJson(Object? value) => value == '3d' ? scene3d : video;
}

/// A landscape: a filmed video or a 3D scene, a theme and a default mix.
class Landscape {
  Landscape({
    required this.id,
    required this.themeId,
    required this.name,
    required this.free,
    required List<String> aliases,
    required Map<LayerKind, List<Layer>> defaultMix,
    this.rendering = LandscapeRendering.video,
    List<String> decorIds = const [],
    this.lightning = false,
    this.periodSeconds,
  }) : aliases = List.unmodifiable(aliases),
       decorIds = List.unmodifiable(rendering == LandscapeRendering.scene3d ? decorIds : const <String>[]),
       defaultMix = Map.unmodifiable({
         for (final kind in LayerKind.values)
           kind: List<Layer>.unmodifiable([
             for (final layer in defaultMix[kind] ?? const <Layer>[])
               // The decor of the default mix follows the rule of the scene's decor.
               if (kind != LayerKind.decor || (rendering == LandscapeRendering.scene3d && decorIds.contains(layer.id)))
                 layer,
           ]),
       });

  final String id;
  final String themeId;
  final String name;
  final bool free;
  final List<String> aliases;

  /// `rendu`: a filmed video, or a live 3D scene.
  final LandscapeRendering rendering;

  /// `decors` (3D scenes only): the decor ids the scene can show, in the catalog's order of the
  /// scene. Empty for a filmed landscape: its decor is never editable.
  final List<String> decorIds;

  /// `eclairs`: a filmed storm; a lightning flash is drawn with each thunder (contract § 11).
  final bool lightning;

  /// `periode_s` (3D scenes): the scene repeats exactly after this many seconds.
  final int? periodSeconds;

  /// Default layers loaded with the landscape (`mix`), one list per kind.
  final Map<LayerKind, List<Layer>> defaultMix;

  bool get is3d => rendering == LandscapeRendering.scene3d;

  /// The decor element [decorId] applies here (contract § 12): a 3D scene that can show it.
  bool allowsDecor(String decorId) => decorIds.contains(decorId);

  /// [knownDecors]: the decor ids of the catalog; a `decors` entry outside it is ignored.
  factory Landscape.fromJson(Map<String, dynamic> json, {Set<String>? knownDecors}) {
    final mix = json['mix'];
    final parsed = <LayerKind, List<Layer>>{};
    if (mix is Map) {
      for (final kind in LayerKind.values) {
        final list = mix[kind.sceneKey];
        parsed[kind] = [
          if (list is List)
            for (final entry in list)
              if (entry is Map)
                Layer.fromJson(Map<String, dynamic>.from(entry)),
        ];
      }
    }
    final period = json['periode_s'];
    return Landscape(
      id: _string(json, 'id'),
      themeId: _string(json, 'theme'),
      name: _string(json, 'nom'),
      free: json['gratuit'] == true,
      aliases: _stringList(json['alias']),
      defaultMix: parsed,
      rendering: LandscapeRendering.fromJson(json['rendu']),
      decorIds: <String>{
        for (final id in _stringList(json['decors']))
          if (knownDecors == null || knownDecors.contains(id)) id,
      }.toList(),
      lightning: json['eclairs'] == true,
      periodSeconds: period is num && period > 0 ? period.round() : null,
    );
  }

  @override
  String toString() => 'Landscape($id)';
}

/// The `limites` block of the catalog.
class Limits {
  const Limits({
    this.layersMax = 6,
    this.freeFavorites = 3,
    this.freeSchedules = 1,
    this.freeAssistantTrials = 3,
    this.rampMinutesMin = 15,
    this.rampMinutesMax = 60,
    this.nightMaxHours = 10,
  });

  /// `couches_max`: sounds + music playing together.
  final int layersMax;

  /// `favoris_gratuits`.
  final int freeFavorites;

  /// `programmations_gratuites`.
  final int freeSchedules;

  /// `essais_assistant_gratuits`.
  final int freeAssistantTrials;

  /// `montee_minutes_min`: lower bound of the custom ramp (5 and 10 are
  /// always allowed besides the custom range).
  final int rampMinutesMin;

  /// `montee_minutes_max`.
  final int rampMinutesMax;

  /// `nuit_max_heures`: the « Toute la nuit » timer stops after this.
  final int nightMaxHours;

  factory Limits.fromJson(Map<String, dynamic> json) {
    int read(String key, int fallback) {
      final v = json[key];
      return v is num ? v.toInt() : fallback;
    }

    return Limits(
      layersMax: read('couches_max', 6),
      freeFavorites: read('favoris_gratuits', 3),
      freeSchedules: read('programmations_gratuites', 1),
      freeAssistantTrials: read('essais_assistant_gratuits', 3),
      rampMinutesMin: read('montee_minutes_min', 15),
      rampMinutesMax: read('montee_minutes_max', 60),
      nightMaxHours: read('nuit_max_heures', 10),
    );
  }

  Map<String, dynamic> toJson() => {
    'couches_max': layersMax,
    'favoris_gratuits': freeFavorites,
    'programmations_gratuites': freeSchedules,
    'essais_assistant_gratuits': freeAssistantTrials,
    'montee_minutes_min': rampMinutesMin,
    'montee_minutes_max': rampMinutesMax,
    'nuit_max_heures': nightMaxHours,
  };
}

/// The closed catalog, read from `assets/catalog.json`.
class Catalog {
  Catalog._({
    required this.version,
    required List<ThemeInfo> themes,
    required List<Landscape> landscapes,
    required List<CatalogItem> sounds,
    required List<CatalogItem> music,
    required List<CatalogItem> decors,
    required this.limits,
    Set<String> hiddenLandscapeIds = const {},
  }) : _hiddenLandscapeIds = Set.unmodifiable(hiddenLandscapeIds),
       themes = List.unmodifiable(themes),
       landscapes = List.unmodifiable(landscapes),
       sounds = List.unmodifiable(sounds),
       music = List.unmodifiable(music),
       decors = List.unmodifiable(decors),
       _landscapeById = {for (final l in landscapes) l.id: l},
       _itemById = {
         LayerKind.son: {for (final i in sounds) i.id: i},
         LayerKind.musique: {for (final i in music) i.id: i},
         LayerKind.decor: {for (final i in decors) i.id: i},
       };

  /// Parses the catalog. Throws [FormatException] when a required field is
  /// missing or has the wrong type.
  factory Catalog.fromJson(Map<String, dynamic> json) {
    List<Map<String, dynamic>> list(String key) {
      final value = json[key];
      if (value is! List) {
        throw FormatException('catalog: "$key" must be a list');
      }
      return [
        for (final entry in value)
          if (entry is Map)
            Map<String, dynamic>.from(entry)
          else
            throw FormatException('catalog: "$key" entries must be objects'),
      ];
    }

    final limits = json['limites'];
    final decors = [
      for (final e in list(LayerKind.decor.catalogKey))
        CatalogItem.fromJson(e, LayerKind.decor),
    ];
    final decorIds = {for (final d in decors) d.id};
    return Catalog._(
      version: json['version'] is num ? (json['version'] as num).toInt() : 1,
      themes: list('themes').map(ThemeInfo.fromJson).toList(),
      landscapes: [
        for (final e in list('paysages')) Landscape.fromJson(e, knownDecors: decorIds),
      ],
      sounds: [
        for (final e in list(LayerKind.son.catalogKey))
          CatalogItem.fromJson(e, LayerKind.son),
      ],
      music: [
        for (final e in list(LayerKind.musique.catalogKey))
          CatalogItem.fromJson(e, LayerKind.musique),
      ],
      decors: decors,
      limits: limits is Map
          ? Limits.fromJson(Map<String, dynamic>.from(limits))
          : const Limits(),
    );
  }

  /// The 2D landscapes drawn by the app until 29 October 2026, replaced by the 3D scenes of
  /// « Imaginaire » (contract § 12). A favourite, a schedule, a link or the saved scene that
  /// names one opens on [defaultLandscape], sounds, music and timer kept.
  static const Set<String> retiredLandscapeIds = {
    'sous-bois',
    'berge-mousseuse',
    'torrent-montagne',
    'pierres-eau',
    'lisiere-verte',
    'cafe-nuit',
    'aurore-boreale',
    'lune-lac',
  };

  /// This catalog without the landscapes the app cannot show ([showable] false: a filmed
  /// landscape with neither its video nor its still picture on the phone or on the content
  /// server). A theme left without landscape is hidden (contract § 12); a stored scene naming a
  /// hidden landscape opens on [defaultLandscape], like a retired one. The default landscape is
  /// always kept.
  Catalog showing(bool Function(Landscape landscape) showable) {
    final kept = [
      for (final l in landscapes)
        if (l.id == defaultLandscape.id || showable(l)) l,
    ];
    if (kept.length == landscapes.length) return this;
    final themeIds = {for (final l in kept) l.themeId};
    return Catalog._(
      version: version,
      themes: [
        for (final t in themes)
          if (themeIds.contains(t.id)) t,
      ],
      landscapes: kept,
      sounds: sounds,
      music: music,
      decors: decors,
      limits: limits,
      hiddenLandscapeIds: {
        ..._hiddenLandscapeIds,
        for (final l in landscapes)
          if (!kept.contains(l)) l.id,
      },
    );
  }

  final int version;
  final List<ThemeInfo> themes;

  /// All landscapes, in catalog order (which is the swipe order).
  final List<Landscape> landscapes;
  final List<CatalogItem> sounds;
  final List<CatalogItem> music;
  final List<CatalogItem> decors;
  final Limits limits;

  final Map<String, Landscape> _landscapeById;
  final Map<LayerKind, Map<String, CatalogItem>> _itemById;

  /// Landscapes of the full catalog left out by [showing].
  final Set<String> _hiddenLandscapeIds;

  Landscape? landscape(String id) => _landscapeById[id];

  /// The landscape a stored or shared landscape id opens on (contract § 12): itself, or
  /// [defaultLandscape] for a retired landscape (or one this phone cannot show). Null for any
  /// other unknown id.
  Landscape? landscapeFor(String id) {
    final known = _landscapeById[id];
    if (known != null) return known;
    if (retiredLandscapeIds.contains(id) || _hiddenLandscapeIds.contains(id)) return defaultLandscape;
    return null;
  }

  /// The decor element [decorId] applies to [landscapeId] (contract § 12): a 3D scene that
  /// lists it in its `decors`. Never on a filmed landscape.
  bool decorApplies(String landscapeId, String decorId) =>
      _landscapeById[landscapeId]?.allowsDecor(decorId) ?? false;

  /// The decor items « Mon mix » offers with [landscapeId], in the scene's order (none for a
  /// filmed landscape).
  List<CatalogItem> decorsOf(String landscapeId) => [
    for (final id in _landscapeById[landscapeId]?.decorIds ?? const <String>[])
      if (item(LayerKind.decor, id) case final CatalogItem decor) decor,
  ];

  /// [scene] in line with the catalog (contract § 12), or null when its landscape is unknown:
  /// a retired landscape is replaced by [defaultLandscape] (sounds, music, timer, moment and
  /// mutes kept), and the decor keeps only the elements that apply to the landscape. Returns
  /// the same instance when nothing changes.
  Scene? sanitize(Scene scene) {
    final landscape = landscapeFor(scene.landscapeId);
    if (landscape == null) return null;
    final decor = [
      for (final layer in scene.decor)
        if (landscape.allowsDecor(layer.id)) layer,
    ];
    if (landscape.id == scene.landscapeId && decor.length == scene.decor.length) return scene;
    return scene.copyWith(landscapeId: landscape.id, decor: decor);
  }

  /// Number of landscapes of the free plan (« 2 en gratuit »).
  int get freeLandscapeCount => landscapes.where((l) => l.free).length;

  CatalogItem? item(LayerKind kind, String id) => _itemById[kind]![id];

  List<CatalogItem> items(LayerKind kind) => switch (kind) {
    LayerKind.son => sounds,
    LayerKind.musique => music,
    LayerKind.decor => decors,
  };

  /// Landscapes of a theme, in swipe order.
  List<Landscape> landscapesOfTheme(String themeId) =>
      List.unmodifiable(landscapes.where((l) => l.themeId == themeId));

  ThemeInfo? theme(String id) {
    for (final t in themes) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// The landscape opened on first launch: the first free one.
  Landscape get defaultLandscape =>
      landscapes.firstWhere((l) => l.free, orElse: () => landscapes.first);

  /// The ambiance of [landscapeId] (contract § 11), or null.
  CatalogItem? ambianceOf(String landscapeId) {
    for (final s in sounds) {
      if (s.landscapeId == landscapeId) return s;
    }
    return null;
  }

  /// [scene] holds a sound played by events (thunder) above level 0: the lightning of a filmed
  /// storm (`eclairs`) then follows its strikes instead of flashing on its own (contract § 11).
  bool hasEventSound(Scene scene) => scene
      .layers(LayerKind.son)
      .any((l) => l.level > 0 && item(LayerKind.son, l.id)?.events != null);
}

String _string(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String) {
    throw FormatException('catalog: "$key" must be a string');
  }
  return value;
}

List<String> _stringList(Object? value) => value is List
    ? [
        for (final v in value)
          if (v is String) v,
      ]
    : const [];
