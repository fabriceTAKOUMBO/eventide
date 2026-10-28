// Resolves where the audio of a layer comes from: bundled asset, cached file, or download
// (signed CloudFront URL from POST /content/urls, or the local dev server in debug).
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/catalog.dart';
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
  }) : _devBaseUrl = devBaseUrl.endsWith('/') ? devBaseUrl.substring(0, devBaseUrl.length - 1) : devBaseUrl;

  final Directory _directory;
  final http.Client _client;
  final ApiClient _api;
  final Future<Set<String>> Function() _bundledAssets;
  final ConnectivityChecker _connectivity;
  final String _devBaseUrl;

  Set<String>? _assets;
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

  /// Playable without network (bundled or already downloaded).
  Future<bool> isAvailableOffline(LayerKind kind, String id) async {
    if ((await _assetSet()).contains(assetKey(kind, id))) return true;
    return _cachedFile(contentKey(kind, id)).exists();
  }

  /// Resolves a layer. [allowNetwork] false: only bundled or cached content.
  Future<AudioSourceRef> resolve(LayerKind kind, String id, {required bool allowNetwork}) async {
    final asset = assetKey(kind, id);
    if ((await _assetSet()).contains(asset)) return AssetAudioSource(asset);
    final key = contentKey(kind, id);
    final cached = _cachedFile(key);
    if (await cached.exists()) return FileAudioSource(cached.path);
    if (!allowNetwork) throw ContentUnavailableException(key, offline: true);
    final file = await _download(key);
    return FileAudioSource(file.path);
  }

  Future<File> _download(String key) {
    return _downloads[key] ??= _doDownload(key).whenComplete(() => _downloads.remove(key));
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

  /// Premium offline: downloads every audio item in the background, one at a time.
  /// With « Téléchargements en Wi-Fi seulement », runs only on Wi-Fi/Ethernet.
  Future<int> prefetchForOffline(Catalog catalog, {required bool wifiOnly}) async {
    if (_prefetching) return 0;
    _prefetching = true;
    var downloaded = 0;
    try {
      if (wifiOnly && !await _connectivity.isUnmetered()) return 0;
      for (final kind in [LayerKind.son, LayerKind.musique]) {
        for (final item in catalog.items(kind)) {
          if (await isAvailableOffline(kind, item.id)) continue;
          if (wifiOnly && !await _connectivity.isUnmetered()) return downloaded;
          try {
            await _download(contentKey(kind, item.id));
            downloaded++;
          } on ContentUnavailableException catch (e) {
            if (e.offline) return downloaded;
          }
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
