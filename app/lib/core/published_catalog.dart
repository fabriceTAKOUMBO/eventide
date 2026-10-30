// The catalog published from the dashboard (contract § 13): the answer of `GET /catalog`,
// checked against the bundled base and merged with it, the published items withdrawn since, and
// what this phone can show of the result. Pure rules: no Flutter, no plugin, no IO.

import 'catalog.dart';
import 'landscape_media.dart';

/// A `GET /catalog` answer the app ignores as a whole (the catalog it has is kept).
class CatalogRejected implements Exception {
  const CatalogRejected(this.reason);

  /// Short French reason, for the problem report.
  final String reason;

  @override
  String toString() => 'CatalogRejected($reason)';
}

/// A valid answer of `GET /catalog` (contract § 13).
class PublishedCatalog {
  const PublishedCatalog._({
    required this.revision,
    required this.catalog,
    required this.distant,
    required this.json,
    required this.dropped,
  });

  /// `revision`: grows by one at each publication, replacement or withdrawal (0: nothing
  /// published yet).
  final int revision;

  /// The bundled base plus the published items kept (before the withdrawn items,
  /// [WithdrawnItems], and before what the phone can show, [showableCatalog]).
  final Catalog catalog;

  /// `distant`: the media on the content server. It replaces `assets/landscapes/remote.json`.
  final RemoteLandscapeMedia distant;

  /// The answer as received (what is kept on the phone).
  final Map<String, dynamic> json;

  /// Published items left out, one French line each (`paysage x (raison)`).
  final List<String> dropped;

  /// Ids of the published items kept (not in the base), by list.
  Set<String> get landscapeIds => {
    for (final l in catalog.landscapes)
      if (l.isPublished) l.id,
  };

  Set<String> itemIds(LayerKind kind) => {
    for (final i in catalog.items(kind))
      if (i.isPublished) i.id,
  };

  /// Checks [json] (the body of `GET /catalog`) against [base], the bundled catalog, and merges
  /// the published items into it ([Catalog.withPublished]). Throws [CatalogRejected] when the
  /// whole answer must be ignored: not an object, `revision` not an integer >= 0, `catalog` or
  /// `distant` not an object, `catalog.version` not 1, `catalog` refused by the bundled
  /// catalog's own parser, or an id of the base missing (a withdrawal only concerns published
  /// items). A single published item that cannot be used is only left out ([dropped]).
  static PublishedCatalog parse(Object? json, Catalog base) {
    if (json is! Map) throw const CatalogRejected('réponse illisible');
    final revision = json['revision'];
    if (revision is! int || revision < 0) throw const CatalogRejected('révision invalide');
    final catalogJson = json['catalog'];
    if (catalogJson is! Map) throw const CatalogRejected('catalogue absent');
    final version = catalogJson['version'];
    if (version is! int || version != 1) throw CatalogRejected('version du catalogue $version');
    final distantJson = json['distant'];
    if (distantJson is! Map) throw const CatalogRejected('médias distants absents');
    final Catalog received;
    try {
      received = Catalog.fromJson(Map<String, dynamic>.from(catalogJson));
    } on FormatException catch (e) {
      throw CatalogRejected('catalogue invalide (${e.message})');
    } catch (e) {
      throw CatalogRejected('catalogue invalide ($e)');
    }
    final missing = received.missingFrom(base);
    if (missing.isNotEmpty) {
      final more = missing.length > 3 ? '…' : '';
      throw CatalogRejected('élément de la base absent : ${missing.take(3).join(', ')}$more');
    }
    final merged = base.withPublished(received);
    return PublishedCatalog._(
      revision: revision,
      catalog: merged.catalog,
      distant: RemoteLandscapeMedia.fromJson(distantJson),
      json: Map<String, dynamic>.from(json),
      dropped: merged.dropped,
    );
  }
}

/// The published items this phone saw and that are no longer published (contract § 13): a
/// favourite, a schedule, a link or the stored scene that names such a landscape opens on the
/// default one, and such a sound or music is removed from a mix. Ids are never reused by
/// another item; one published again leaves this list.
class WithdrawnItems {
  const WithdrawnItems({this.landscapes = const {}, this.sounds = const {}, this.music = const {}});

  static const WithdrawnItems none = WithdrawnItems();

  final Set<String> landscapes;
  final Set<String> sounds;
  final Set<String> music;

  bool get isEmpty => landscapes.isEmpty && sounds.isEmpty && music.isEmpty;

  /// The list after [previous] (the published catalog held until now, if any) was replaced by
  /// [next]: what [previous] published and [next] no longer does is added, what [next]
  /// publishes (again) is removed.
  WithdrawnItems after(PublishedCatalog? previous, PublishedCatalog next) {
    Set<String> update(Set<String> known, Set<String> before, Set<String> now) => {
      for (final id in {...known, ...before})
        if (!now.contains(id)) id,
    };
    return WithdrawnItems(
      landscapes: update(landscapes, previous?.landscapeIds ?? const {}, next.landscapeIds),
      sounds: update(sounds, previous?.itemIds(LayerKind.son) ?? const {}, next.itemIds(LayerKind.son)),
      music: update(music, previous?.itemIds(LayerKind.musique) ?? const {}, next.itemIds(LayerKind.musique)),
    );
  }

  /// [catalog] knowing these withdrawals ([Catalog.withdrawing]).
  Catalog applyTo(Catalog catalog) => isEmpty
      ? catalog
      : catalog.withdrawing(landscapes: landscapes, items: {LayerKind.son: sounds, LayerKind.musique: music});

  Map<String, dynamic> toJson() => {
    'paysages': [...landscapes],
    'sons': [...sounds],
    'musiques': [...music],
  };

  /// Lenient: anything unexpected is an empty list.
  factory WithdrawnItems.fromJson(Object? json) {
    if (json is! Map) return none;
    Set<String> ids(Object? list) => {
      if (list is List)
        for (final id in list)
          if (id is String) id,
    };
    return WithdrawnItems(
      landscapes: ids(json['paysages']),
      sounds: ids(json['sons']),
      music: ids(json['musiques']),
    );
  }
}

/// What this phone can show of [catalog] (contract § 12): a filmed landscape needs its video or
/// its poster, bundled ([bundledAssets]) or on the content server ([remote]); a 3D scene needs
/// the bundled runtime or its poster. A theme left empty is hidden ([Catalog.showing]).
Catalog showableCatalog(
  Catalog catalog, {
  required Set<String> bundledAssets,
  required RemoteLandscapeMedia remote,
}) {
  final runtime = bundledAssets.contains(LandscapeMediaKeys.sceneRuntime);
  return catalog.showing((l) {
    final media = bundledAssets.contains(LandscapeMediaKeys.bundledVideo(l.id)) ||
        bundledAssets.contains(LandscapeMediaKeys.bundledImage(l.id)) ||
        remote.videos.contains(l.id) ||
        remote.images.contains(l.id);
    return media || (l.is3d && runtime);
  });
}
