// Closed catalog of landscapes, sounds, music, decor effects and limits.
//
// Source of truth: `assets/catalog.json` (shared with the API). The JSON keys
// are French (`nom`, `gratuit`, `alias`, `limites`...), the Dart API is English.

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

/// A sound, a music or a decor effect of the catalog.
class CatalogItem {
  CatalogItem({
    required this.id,
    required this.name,
    required this.free,
    required List<String> aliases,
    required this.kind,
  }) : aliases = List.unmodifiable(aliases);

  final String id;

  /// French display name (`nom`).
  final String name;

  /// Available on the free plan (`gratuit`).
  final bool free;

  /// Spoken forms (`alias`), lowercase French.
  final List<String> aliases;

  final LayerKind kind;

  factory CatalogItem.fromJson(Map<String, dynamic> json, LayerKind kind) {
    return CatalogItem(
      id: _string(json, 'id'),
      name: _string(json, 'nom'),
      free: json['gratuit'] == true,
      aliases: _stringList(json['alias']),
      kind: kind,
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

/// A landscape: a photo, a theme and a default mix.
class Landscape {
  Landscape({
    required this.id,
    required this.themeId,
    required this.name,
    required this.free,
    required this.style,
    required List<String> aliases,
    required Map<LayerKind, List<Layer>> defaultMix,
  }) : aliases = List.unmodifiable(aliases),
       defaultMix = Map.unmodifiable({
         for (final kind in LayerKind.values)
           kind: List<Layer>.unmodifiable(defaultMix[kind] ?? const <Layer>[]),
       });

  final String id;
  final String themeId;
  final String name;
  final bool free;

  /// Visual style key used by the UI (`style`).
  final String style;
  final List<String> aliases;

  /// Default layers loaded with the landscape (`mix`), one list per kind.
  final Map<LayerKind, List<Layer>> defaultMix;

  factory Landscape.fromJson(Map<String, dynamic> json) {
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
    return Landscape(
      id: _string(json, 'id'),
      themeId: _string(json, 'theme'),
      name: _string(json, 'nom'),
      free: json['gratuit'] == true,
      style: json['style'] is String ? json['style'] as String : '',
      aliases: _stringList(json['alias']),
      defaultMix: parsed,
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
  }) : themes = List.unmodifiable(themes),
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
    return Catalog._(
      version: json['version'] is num ? (json['version'] as num).toInt() : 1,
      themes: list('themes').map(ThemeInfo.fromJson).toList(),
      landscapes: list('paysages').map(Landscape.fromJson).toList(),
      sounds: [
        for (final e in list(LayerKind.son.catalogKey))
          CatalogItem.fromJson(e, LayerKind.son),
      ],
      music: [
        for (final e in list(LayerKind.musique.catalogKey))
          CatalogItem.fromJson(e, LayerKind.musique),
      ],
      decors: [
        for (final e in list(LayerKind.decor.catalogKey))
          CatalogItem.fromJson(e, LayerKind.decor),
      ],
      limits: limits is Map
          ? Limits.fromJson(Map<String, dynamic>.from(limits))
          : const Limits(),
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

  Landscape? landscape(String id) => _landscapeById[id];

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
