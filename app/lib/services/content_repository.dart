// Resolves where the audio of a layer, and the video and poster of a landscape, come from:
// bundled asset, cached file, or download (signed CloudFront URL from POST /content/urls, or the
// local dev server in debug). The files of an item published from the dashboard carry its
// revision in their key (contract § 13): a replaced file is a new key, hence a new download.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/catalog.dart';
import '../core/landscape_media.dart';
import 'api_client.dart';
import 'audio/audio_engine.dart';
import 'connectivity.dart';

/// The content cannot be played now.
class ContentUnavailableException implements Exception {
  const ContentUnavailableException(this.key, {this.offline = false});

  final String key;

  /// True when only a network access could have provided it.
  final bool offline;

  @override
  String toString() => 'ContentUnavailableException($key, offline: $offline)';
}

class ContentRepository {
  ContentRepository({
    required this._directory,
    required this._client,
    required this._api,
    required this._bundledAssets,
    required this._connectivity,
    String devBaseUrl = '',
    this._remoteMedia,
  }) : _devBaseUrl = devBaseUrl.endsWith('/') ? devBaseUrl.substring(0, devBaseUrl.length - 1) : devBaseUrl;

  final Directory _directory;
  final http.Client _client;
  final ApiClient _api;
  final Future<Set<String>> Function() _bundledAssets;
  final ConnectivityChecker _connectivity;
  final String _devBaseUrl;
  final Future<RemoteLandscapeMedia> Function()? _remoteMedia;

  Set<String>? _assets;
  RemoteLandscapeMedia? _remote;

  /// The catalog whose `media_rev` names the files of published items (null: base keys only).
  Catalog? _catalog;
  final Map<String, Future<File>> _downloads = {};
  bool _prefetching = false;

  /// Content key, as in the API contract § 8: `audio/sons/<id>.ogg`, `audio/musiques/<id>.ogg`;
  /// `audio/sons/<id>.v<rev>.ogg` for an item published from the dashboard ([rev] = its
  /// `media_rev`, contract § 13).
  static String contentKey(LayerKind kind, String id, {int? rev}) {
    assert(kind.isAudio, 'decor items have no audio');
    final folder = kind == LayerKind.son ? 'sons' : 'musiques';
    return 'audio/$folder/$id${LandscapeMediaKeys.revisionSuffix(rev)}.ogg';
  }

  /// Bundled copy of an item of the base (a published item is never bundled).
  static String assetKey(LayerKind kind, String id) => 'assets/${contentKey(kind, id)}';

  /// Uses [catalog] to name the files of published items (their `media_rev`, contract § 13),
  /// and [remote], when given, as the media on the content server (the published catalog's
  /// `distant`, which replaces `remote.json`). Files already resolved, being played or being
  /// downloaded are not touched.
  void useCatalog(Catalog catalog, {RemoteLandscapeMedia? remote}) {
    _catalog = catalog;
    if (remote != null) _remote = remote;
  }

  /// Content key of the audio file of [id] (a sound, a music, or a variant of a sound played by
  /// events), with the revision of a published item.
  String audioKey(LayerKind kind, String id) => contentKey(kind, id, rev: _catalog?.item(kind, id)?.mediaRev);

  /// Content key of the looping video of [landscapeId] (`videos/paysages/<id>[.v<rev>].mp4`).
  String videoKey(String landscapeId) =>
      LandscapeMediaKeys.video(landscapeId, rev: _catalog?.landscape(landscapeId)?.mediaRev);

  /// Content key of the poster of [landscapeId] (`images/paysages/<id>[.v<rev>].jpg`).
  String imageKey(String landscapeId) =>
      LandscapeMediaKeys.image(landscapeId, rev: _catalog?.landscape(landscapeId)?.mediaRev);

  File _cachedFile(String key) => File('${_directory.path}/$key');

  Future<Set<String>> _assetSet() async => _assets ??= await _bundledAssets();

  Future<RemoteLandscapeMedia> _remoteSet() async {
    final cached = _remote;
    if (cached != null) return cached;
    var remote = RemoteLandscapeMedia.none;
    try {
      remote = await _remoteMedia?.call() ?? RemoteLandscapeMedia.none;
    } catch (_) {
      // No manifest: nothing is asked from the server.
    }
    // A catalog received meanwhile wins (useCatalog).
    return _remote ??= remote;
  }

  /// Playable without network (bundled or already downloaded).
  Future<bool> isAvailableOffline(LayerKind kind, String id) async {
    if ((await _assetSet()).contains(assetKey(kind, id))) return true;
    return _cachedFile(audioKey(kind, id)).exists();
  }

  /// The file of [id] can be had: bundled, already downloaded, or on the content server
  /// (`remote.json` lists it, or has no list for that folder). False for a test-only ambiance
  /// in the production build: it is then never requested (contract § 8 and § 11).
  Future<bool> isPublished(LayerKind kind, String id) async {
    if (await isAvailableOffline(kind, id)) return true;
    final remote = await _remoteSet();
    final listed = kind == LayerKind.son ? remote.sounds : remote.music;
    return listed == null || listed.contains(id);
  }

  /// Resolves a layer (or a variant of an event sound: its file is `audio/sons/<variant>.ogg`).
  /// [allowNetwork] false: only bundled or cached content.
  Future<AudioSourceRef> resolve(LayerKind kind, String id, {required bool allowNetwork}) async {
    final asset = assetKey(kind, id);
    if ((await _assetSet()).contains(asset)) return AssetAudioSource(asset);
    final key = audioKey(kind, id);
    final cached = _cachedFile(key);
    if (await cached.exists()) return FileAudioSource(cached.path);
    if (!allowNetwork) throw ContentUnavailableException(key, offline: true);
    // Never a request for a file the server does not have.
    if (!await isPublished(kind, id)) throw ContentUnavailableException(key);
    final file = await _download(key);
    return FileAudioSource(file.path);
  }

  Future<File> _download(String key) {
    // The callback must not return the removed future: whenComplete would wait for itself.
    return _downloads[key] ??= _doDownload(key).whenComplete(() {
      _downloads.remove(key);
    });
  }

  Future<Uri> _urlFor(String key) async {
    if (_devBaseUrl.isNotEmpty) return Uri.parse('$_devBaseUrl/$key');
    if (!_api.enabled) throw ContentUnavailableException(key);
    try {
      final urls = await _api.contentUrls([key]);
      final url = urls[key];
      if (url == null) throw ContentUnavailableException(key);
      return Uri.parse(url);
    } on ApiUnavailableException {
      throw ContentUnavailableException(key, offline: true);
    } on ApiException {
      // 403 premium_required (entitlement expired) or unknown key.
      throw ContentUnavailableException(key);
    }
  }

  Future<File> _doDownload(String key) async {
    final uri = await _urlFor(key);
    final target = _cachedFile(key);
    final tmp = File('${target.path}.part');
    try {
      await target.parent.create(recursive: true);
      final response = await _client.send(http.Request('GET', uri)).timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        throw ContentUnavailableException(key);
      }
      final sink = tmp.openWrite();
      try {
        await response.stream.timeout(const Duration(seconds: 30)).pipe(sink);
      } finally {
        await sink.close().catchError((_) {});
      }
      await tmp.rename(target.path);
      return target;
    } on ContentUnavailableException {
      rethrow;
    } catch (e) {
      debugPrint('ContentRepository: download $key failed ($e)');
      if (await tmp.exists()) await tmp.delete().catchError((_) => tmp);
      throw ContentUnavailableException(key, offline: true);
    }
  }

  // ---- Landscape media (looping videos and posters)

  /// Local path of a downloaded file for [key], or null.
  String cachedPath(String key) => _cachedFile(key).path;

  /// Video of a landscape: bundled (`assets/landscapes/<id>.mp4`), already downloaded, or
  /// downloaded now when [allowDownload] and the network policy allow it. Null when none can
  /// be had now; never throws (the still picture is shown instead).
  Future<LandscapeVideoSource?> landscapeVideo(
    String id, {
    required bool allowDownload,
    required bool wifiOnly,
  }) async {
    final asset = LandscapeMediaKeys.bundledVideo(id);
    if ((await _assetSet()).contains(asset)) return AssetLandscapeVideo(asset);
    final path = await _landscapeFile(
      videoKey(id),
      listed: (await _remoteSet()).videos.contains(id),
      allowDownload: allowDownload,
      wifiOnly: wifiOnly,
    );
    return path == null ? null : FileLandscapeVideo(path);
  }

  /// Downloaded poster of a landscape (local path), same rules as [landscapeVideo]. Null for a
  /// bundled poster (`assets/landscapes/<id>.jpg`, found by the UI itself) or when unavailable.
  Future<String?> landscapeImage(
    String id, {
    required bool allowDownload,
    required bool wifiOnly,
  }) async {
    if ((await _assetSet()).contains(LandscapeMediaKeys.bundledImage(id))) return null;
    return _landscapeFile(
      imageKey(id),
      listed: (await _remoteSet()).images.contains(id),
      allowDownload: allowDownload,
      wifiOnly: wifiOnly,
    );
  }

  /// Ids of the landscapes whose current poster is already downloaded (for a published
  /// landscape, the poster of its current revision).
  Future<Set<String>> downloadedLandscapeImages() async {
    final folder = Directory('${_directory.path}/images/paysages');
    try {
      if (!await folder.exists()) return {};
      final ids = <String>{};
      await for (final entity in folder.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        final match = _posterFile.firstMatch(name);
        if (match == null) continue;
        final id = match.group(1)!;
        if ('images/paysages/$name' == imageKey(id)) ids.add(id);
      }
      return ids;
    } catch (_) {
      return {};
    }
  }

  /// A downloaded poster: `<id>.jpg`, or `<id>.v<rev>.jpg` for a published landscape.
  static final RegExp _posterFile = RegExp(r'^([a-z0-9-]+)(?:\.v\d+)?\.jpg$');

  Future<String?> _landscapeFile(
    String key, {
    required bool listed,
    required bool allowDownload,
    required bool wifiOnly,
  }) async {
    final cached = _cachedFile(key);
    if (await cached.exists()) return cached.path;
    // Only keys the server has (remote.json): never a request for a missing video.
    if (!listed || !allowDownload) return null;
    // Pictures are decoration: with « Wi-Fi seulement », never on mobile data.
    if (wifiOnly && !await _connectivity.isUnmetered()) return null;
    try {
      return (await _download(key)).path;
    } on ContentUnavailableException {
      return null;
    }
  }

  /// Premium offline: downloads every audio item in the background (the variants of the event
  /// sounds included), one at a time, then the landscape posters (small; videos are fetched
  /// when their landscape is shown).
  /// With « Téléchargements en Wi-Fi seulement », runs only on Wi-Fi/Ethernet.
  Future<int> prefetchForOffline(Catalog catalog, {required bool wifiOnly}) async {
    if (_prefetching) return 0;
    _prefetching = true;
    var downloaded = 0;
    try {
      if (wifiOnly && !await _connectivity.isUnmetered()) return 0;
      for (final kind in [LayerKind.son, LayerKind.musique]) {
        for (final item in catalog.items(kind)) {
          // A sound played by events is its variants' files (contract § 11).
          for (final id in item.events?.variants ?? [item.id]) {
            if (await isAvailableOffline(kind, id)) continue;
            if (!await isPublished(kind, id)) continue;
            if (wifiOnly && !await _connectivity.isUnmetered()) return downloaded;
            try {
              await _download(audioKey(kind, id));
              downloaded++;
            } on ContentUnavailableException catch (e) {
              if (e.offline) return downloaded;
            }
          }
        }
      }
      downloaded += await _downloadPosters((await _remoteSet()).images, wifiOnly: wifiOnly);
    } finally {
      _prefetching = false;
    }
    return downloaded;
  }

  /// Downloads in the background the posters of [landscapeIds] that are on the content server
  /// and not yet on the phone, one at a time (« Wi-Fi seulement » respected). Used for the
  /// landscapes published free from the dashboard (contract § 13): every plan can use them and
  /// their poster is never bundled. Returns the number of files downloaded.
  Future<int> prefetchPosters(Iterable<String> landscapeIds, {required bool wifiOnly}) async {
    if (wifiOnly && !await _connectivity.isUnmetered()) return 0;
    final remote = (await _remoteSet()).images;
    return _downloadPosters([
      for (final id in landscapeIds)
        if (remote.contains(id)) id,
    ], wifiOnly: wifiOnly);
  }

  /// Downloads the posters of [ids] not bundled nor downloaded yet; stops when the network is
  /// gone or no longer allowed.
  Future<int> _downloadPosters(Iterable<String> ids, {required bool wifiOnly}) async {
    var downloaded = 0;
    final assets = await _assetSet();
    for (final id in ids) {
      if (assets.contains(LandscapeMediaKeys.bundledImage(id))) continue;
      // Only landscapes of the catalog: their key names the current revision of the poster.
      final catalog = _catalog;
      if (catalog != null && catalog.landscape(id) == null) continue;
      final key = imageKey(id);
      if (await _cachedFile(key).exists()) continue;
      if (wifiOnly && !await _connectivity.isUnmetered()) return downloaded;
      try {
        await _download(key);
        downloaded++;
      } on ContentUnavailableException catch (e) {
        if (e.offline) return downloaded;
      }
    }
    return downloaded;
  }

  /// Removes the downloaded files of published items that are no longer current (contract
  /// § 13): a file of an older revision, or of an item no longer in the catalog. Only files
  /// named with a revision (`<id>.v<rev>.<ext>`) can go: files of base items are kept, and
  /// bundled assets are never in this folder. The video and poster of [keepLandscapes] (the
  /// live wallpaper plays them from here) are kept, and so is a file being downloaded. Meant
  /// for the start of the app, before a file of an older revision can be in use. Never throws.
  Future<int> removeStaleFiles({Set<String> keepLandscapes = const {}}) async {
    if (_catalog == null) return 0;
    var removed = 0;
    final folders = <({String folder, String extension, String Function(String id) key, bool landscape})>[
      (folder: 'audio/sons', extension: 'ogg', key: (id) => audioKey(LayerKind.son, id), landscape: false),
      (folder: 'audio/musiques', extension: 'ogg', key: (id) => audioKey(LayerKind.musique, id), landscape: false),
      (folder: 'videos/paysages', extension: 'mp4', key: videoKey, landscape: true),
      (folder: 'images/paysages', extension: 'jpg', key: imageKey, landscape: true),
    ];
    for (final f in folders) {
      final dir = Directory('${_directory.path}/${f.folder}');
      final pattern = RegExp('^([a-z0-9-]+)\\.v\\d+\\.${f.extension}\$');
      try {
        if (!await dir.exists()) continue;
        final stale = <File>[];
        await for (final entity in dir.list()) {
          if (entity is! File) continue;
          final name = entity.uri.pathSegments.last;
          final match = pattern.firstMatch(name);
          if (match == null) continue;
          final id = match.group(1)!;
          final key = '${f.folder}/$name';
          if (f.landscape && keepLandscapes.contains(id)) continue;
          if (key == f.key(id) || _downloads.containsKey(key)) continue;
          stale.add(entity);
        }
        for (final file in stale) {
          try {
            await file.delete();
            removed++;
          } catch (_) {}
        }
      } catch (e) {
        debugPrint('ContentRepository: cleanup of ${f.folder} failed ($e)');
      }
    }
    return removed;
  }

  /// Removes every downloaded file (data deletion).
  Future<void> clear() async {
    if (await _directory.exists()) await _directory.delete(recursive: true);
  }
}
