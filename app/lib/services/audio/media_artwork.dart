// Picture of the media card (lock screen, notification shade): the current landscape's poster,
// as a local file that audio_service can load (it accepts `file://` and `content://` URIs; a
// bundled asset has none, so it is copied to a file first).
//
// Order: bundled poster (`assets/landscapes/<id>.jpg`: free landscapes and the free 3D scene,
// and every landscape of the demo build) → poster downloaded for Premium
// (`images/paysages/<id>.jpg` in the content folder) → no picture (the card shows its title and
// buttons only). Nothing is drawn by the app any more (the 2D procedural pictures are gone,
// contract § 12): a poster is a file copy, never GPU work. Never blocks playback: the controller
// publishes the card first and adds the picture when [MediaArtwork.resolve] answers.
import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../core/catalog.dart';
import '../../core/landscape_media.dart';

/// Files of the artwork pipeline (real folder in the app, in memory in tests).
abstract class ArtworkFiles {
  /// Folder of the copied pictures (the app's cache: Android may empty it, the copies are then
  /// made again).
  String get directory;

  Future<bool> exists(String path);

  /// Writes [bytes] atomically (temporary file, then rename): the system never reads half a
  /// picture.
  Future<void> write(String path, Uint8List bytes);
}

class IoArtworkFiles implements ArtworkFiles {
  IoArtworkFiles(this._folder);

  final Directory _folder;

  @override
  String get directory => _folder.path;

  @override
  Future<bool> exists(String path) => File(path).exists();

  @override
  Future<void> write(String path, Uint8List bytes) async {
    final target = File(path);
    await target.parent.create(recursive: true);
    final tmp = File('$path.part');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(target.path);
  }
}

class MediaArtwork {
  /// [downloadedPoster]: where the content folder keeps the downloaded poster of a landscape
  /// (it may not exist).
  MediaArtwork({
    required this._files,
    required this._bundledAssets,
    required this._loadAsset,
    required this._downloadedPoster,
  });

  final ArtworkFiles _files;
  final Future<Set<String>> Function() _bundledAssets;
  final Future<Uint8List> Function(String asset) _loadAsset;
  final String Function(String landscapeId) _downloadedPoster;

  Set<String>? _assets;
  final Map<String, Uri> _done = {};
  final Map<String, Future<Uri?>> _pending = {};
  final Map<String, String> _bundledCopies = {};

  /// The picture already found for this landscape, or null (synchronous).
  Uri? peek(String landscapeId) => _done[landscapeId];

  /// The picture of [landscape], copied if needed. Null when the phone has no poster of it
  /// (never throws); a later call tries again (a Premium poster may have been downloaded).
  Future<Uri?> resolve(Landscape landscape) {
    final id = landscape.id;
    final done = _done[id];
    if (done != null) return Future.value(done);
    return _pending[id] ??= _resolve(id).then((uri) {
      _pending.remove(id);
      if (uri != null) _done[id] = uri;
      return uri;
    });
  }

  Future<Uri?> _resolve(String landscapeId) async {
    // 1. Bundled poster, copied once (named after its content: an app update never shows
    //    an old picture).
    try {
      final copy = await _bundledPoster(landscapeId);
      if (copy != null) return Uri.file(copy);
    } catch (e) {
      debugPrint('MediaArtwork: bundled poster of $landscapeId unavailable ($e)');
    }
    // 2. Poster downloaded for Premium.
    try {
      final downloaded = _downloadedPoster(landscapeId);
      if (await _files.exists(downloaded)) return Uri.file(downloaded);
    } catch (e) {
      debugPrint('MediaArtwork: downloaded poster of $landscapeId unavailable ($e)');
    }
    return null;
  }

  Future<String?> _bundledPoster(String landscapeId) async {
    final known = _bundledCopies[landscapeId];
    if (known != null && await _files.exists(known)) return known;
    final asset = LandscapeMediaKeys.bundledImage(landscapeId);
    final assets = _assets ??= await _bundledAssets();
    if (!assets.contains(asset)) return null;
    final bytes = await _loadAsset(asset);
    final digest = sha1.convert(bytes).toString().substring(0, 12);
    final path = '${_files.directory}/$landscapeId-$digest.jpg';
    if (!await _files.exists(path)) await _files.write(path, bytes);
    return _bundledCopies[landscapeId] = path;
  }
}
