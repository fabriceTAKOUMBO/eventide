// The catalog published from the dashboard (contract § 13): asked with `GET /catalog`, checked
// against the bundled base, kept on the phone (`<app support>/eventide/catalog-publie.json`) and
// used from the next launch on. Silent: an error never reaches the user, it only leaves a line in
// the problem report, and the catalog the app has is kept. Without a backend (`API_BASE_URL`
// empty) nothing here reads a file or the network: the bundled catalog is used as before.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/catalog.dart';
import '../core/landscape_media.dart';
import '../core/published_catalog.dart';
import 'api_client.dart';
import 'diagnostics.dart' show Breadcrumbs;
import 'storage.dart';

/// What the app shows: the catalog (without the landscapes this phone cannot show) and the
/// media on the content server.
class CatalogSnapshot {
  const CatalogSnapshot({required this.catalog, required this.remote, this.revision});

  final Catalog catalog;

  /// The published catalog's `distant`, or the bundled `remote.json`.
  final RemoteLandscapeMedia remote;

  /// Revision of the published catalog, or null for the bundled one.
  final int? revision;

  /// From a `GET /catalog` answer (received now or at an earlier launch).
  bool get published => revision != null;
}

class CatalogUpdates {
  CatalogUpdates({
    required this._api,
    required this._store,
    required this._base,
    required this._bundledRemote,
    required this._bundledAssets,
    DateTime Function()? now,
    void Function(String message)? log,
  })  : _now = now ?? DateTime.now,
        _log = log ?? Breadcrumbs.add;

  /// File of the last valid answer, in the app's store (`catalog-publie.json`).
  static const String storeName = 'catalog-publie';

  /// A return to the foreground asks again once the last answer is this old.
  static const Duration checkEvery = Duration(hours: 1);

  final ApiClient _api;
  final LocalStore _store;

  /// The bundled `assets/catalog.json`, whole (not reduced to what the phone can show).
  final Catalog _base;
  final RemoteLandscapeMedia _bundledRemote;
  final Future<Set<String>> Function() _bundledAssets;
  final DateTime Function() _now;
  final void Function(String message) _log;

  PublishedCatalog? _published;
  WithdrawnItems _withdrawn = WithdrawnItems.none;
  CatalogSnapshot? _current;
  DateTime? _answeredAt;
  Future<CatalogSnapshot?>? _checking;

  /// A backend is configured: otherwise this never runs.
  bool get enabled => _api.enabled;

  /// What the app shows now (null before [load]).
  CatalogSnapshot? get current => _current;

  /// Revision held (null: none received, the bundled catalog is used).
  int? get revision => _published?.revision;

  /// When the server last answered (200, 304 or an error status); null before.
  DateTime? get answeredAt => _answeredAt;

  /// A return to the foreground should ask again: no answer yet, or the last one is older than
  /// [checkEvery].
  bool get due {
    final at = _answeredAt;
    return at == null || !_now().isBefore(at.add(checkEvery));
  }

  /// At start: the last valid answer kept on the phone, or the bundled catalog. A file that
  /// cannot be read or is no longer valid (a newer app whose base it lacks) is deleted.
  Future<CatalogSnapshot> load() async {
    if (enabled) {
      try {
        final stored = await _store.read(storeName);
        if (stored is Map) {
          _published = PublishedCatalog.parse(stored['response'], _base);
          _withdrawn = WithdrawnItems.fromJson(stored['withdrawn']);
        } else {
          await _store.delete(storeName);
        }
      } catch (e) {
        _published = null;
        _withdrawn = WithdrawnItems.none;
        _log('catalogue publié : copie du téléphone ignorée (${e is CatalogRejected ? e.reason : e})');
        try {
          await _store.delete(storeName);
        } catch (_) {}
      }
    }
    return _current = await _snapshot();
  }

  /// Asks the server (`If-None-Match` with the revision held). Returns what the app should show
  /// now when a new valid catalog arrived (it is already kept on the phone), else null: same
  /// revision (`304`), refused answer, server error or no network. Never throws; one request
  /// at a time.
  Future<CatalogSnapshot?> check() => _checking ??= _check().whenComplete(() => _checking = null);

  Future<CatalogSnapshot?> _check() async {
    if (!enabled) return null;
    final held = _published;
    final CatalogFetch answer;
    try {
      answer = await _api.fetchCatalog(etag: held == null ? null : '"${held.revision}"');
    } on ApiException catch (e) {
      _answeredAt = _now();
      _log('catalogue publié : erreur du serveur (${e.status} ${e.code})');
      return null;
    } on ApiUnavailableException catch (e) {
      _log('catalogue publié : pas de réponse (${e.reason})');
      return null;
    } catch (e) {
      _log('catalogue publié : demande impossible ($e)');
      return null;
    }
    _answeredAt = _now();
    final PublishedCatalog next;
    switch (answer) {
      case CatalogNotModified():
        return null;
      case CatalogFetched(:final body):
        try {
          next = PublishedCatalog.parse(body, _base);
        } on CatalogRejected catch (e) {
          _log('catalogue publié : réponse ignorée (${e.reason})');
          return null;
        }
    }
    if (held != null && held.revision == next.revision) return null;
    final withdrawn = _withdrawn.after(held, next);
    await _store.write(storeName, {'response': next.json, 'withdrawn': withdrawn.toJson()});
    _published = next;
    _withdrawn = withdrawn;
    if (next.dropped.isNotEmpty) {
      _log('catalogue publié : ${next.dropped.length} élément(s) ignoré(s) : ${next.dropped.take(5).join(', ')}');
    }
    _log('catalogue publié : révision ${next.revision} reçue');
    try {
      return _current = await _snapshot();
    } catch (e) {
      debugPrint('CatalogUpdates: snapshot failed ($e)');
      return null;
    }
  }

  /// Forgets the kept answer (data deletion): the next launch starts from the bundled catalog,
  /// the next request asks for the whole catalog again. What the app shows now is unchanged.
  Future<void> clear() async {
    _published = null;
    _withdrawn = WithdrawnItems.none;
    await _store.delete(storeName);
  }

  Future<CatalogSnapshot> _snapshot() async {
    final published = _published;
    final remote = published?.distant ?? _bundledRemote;
    final catalog = published == null ? _base : _withdrawn.applyTo(published.catalog);
    Set<String> assets;
    try {
      assets = await _bundledAssets();
    } catch (_) {
      assets = const {};
    }
    return CatalogSnapshot(
      catalog: showableCatalog(catalog, bundledAssets: assets, remote: remote),
      remote: remote,
      revision: published?.revision,
    );
  }
}
