// Resolves where the audio of a layer, and the video and poster of a landscape, come from:
// bundled asset, cached file, or download (signed CloudFront URL from POST /content/urls, or the
// local dev server in debug).
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
  final Map<String, Future<File>> _downloads = {};
  bool _prefetching = false;

  /// Content key, as in the API contract § 8: `audio/sons/<id>.ogg`, `audio/musiques/<id>.ogg`.
  static String contentKey(LayerKind kind, String id) {
    assert(kind.isAudio, 'decor items have no audio');
    return 'audio/${kind == LayerKind.son ? 'sons' : 'musiques'}/$id.ogg';
  }

  static String assetKey(LayerKind kind, String id) => 'assets/${contentKey(kind, id)}';

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
    return _remote = remote;
  }

  /// Playable without network (bundled or already downloaded).
  Future<bool> isAvailableOffline(LayerKind kind, String id) async {
    if ((await _assetSet()).contains(assetKey(kind, id))) return true;
    return _cachedFile(contentKey(kind, id)).exists();
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
    final key = contentKey(kind, id);
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
      LandscapeMediaKeys.video(id),
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
      LandscapeMediaKeys.image(id),
      listed: (await _remoteSet()).images.contains(id),
      allowDownload: allowDownload,
      wifiOnly: wifiOnly,
    );
  }

  /// Ids of the landscapes whose poster is already downloaded.
  Future<Set<String>> downloadedLandscapeImages() async {
    final folder = Directory('${_directory.path}/images/paysages');
    try {
      if (!await folder.exists()) return {};
      return {
        await for (final entity in folder.list())
          if (entity is File && entity.path.endsWith('.jpg'))
            entity.uri.pathSegments.last.replaceFirst(RegExp(r'\.jpg$'), ''),
      };
    } catch (_) {
      return {};
    }
  }

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
              await _download(contentKey(kind, id));
              downloaded++;
            } on ContentUnavailableException catch (e) {
              if (e.offline) return downloaded;
            }
          }
        }
      }
      final assets = await _assetSet();
      for (final id in (await _remoteSet()).images) {
        if (assets.contains(LandscapeMediaKeys.bundledImage(id))) continue;
        final key = LandscapeMediaKeys.image(id);
        if (await _cachedFile(key).exists()) continue;
        if (wifiOnly && !await _connectivity.isUnmetered()) return downloaded;
        try {
          await _download(key);
          downloaded++;
        } on ContentUnavailableException catch (e) {
          if (e.offline) return downloaded;
        }
      }
    } finally {
      _prefetching = false;
    }
    return downloaded;
  }

  /// Removes every downloaded file (data deletion).
  Future<void> clear() async {
    if (await _directory.exists()) await _directory.delete(recursive: true);
  }
}
