// Picture of the media card (lock screen, notification shade): the current landscape, as a
// local file that audio_service can load (it accepts `file://` and `content://` URIs; a
// bundled asset has none, so it is copied to a file first).
//
// Order: bundled poster (`assets/landscapes/<id>.jpg`: free landscapes, and every landscape
// of the demo build) → poster downloaded for Premium (`images/paysages/<id>.jpg` in the
// content folder) → procedural picture of the landscape at its moment of the day, rendered
// once to a square PNG and kept in the app's cache folder. Never blocks playback: the
// controller publishes the card first and adds the picture when [MediaArtwork.resolve]
// answers.
import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../core/catalog.dart';
import '../../core/landscape_media.dart';
import '../../core/scene.dart';

/// Renders the procedural landscape [style] at [moment] to a [size] × [size] PNG
/// (lib/ui/landscape/landscape_artwork.dart in the app, a fake in tests).
typedef ArtworkRenderer =
    Future<Uint8List> Function({
      required String style,
      required Moment moment,
      required int size,
    });

/// Files of the artwork pipeline (real folder in the app, in memory in tests).
abstract class ArtworkFiles {
  /// Folder of the copied and rendered pictures (the app's cache: Android may empty it, the
  /// pictures are then made again).
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
    required this._render,
    this.size = 720,
    this.renderTimeout = const Duration(seconds: 10),
  });

  /// Bumped when the procedural pictures change (a new file name, never a stale picture).
  static const int renderVersion = 1;

  final ArtworkFiles _files;
  final Future<Set<String>> Function() _bundledAssets;
  final Future<Uint8List> Function(String asset) _loadAsset;
  final String Function(String landscapeId) _downloadedPoster;
  final ArtworkRenderer _render;

  /// Side of the rendered square picture, in pixels.
  final int size;

  /// A render that does not answer (no GPU in a headless engine) is given up.
  final Duration renderTimeout;

  Set<String>? _assets;
  final Map<String, Uri> _done = {};
  final Map<String, Future<Uri?>> _pending = {};
  final Map<String, String> _bundledCopies = {};

  static String _key(String landscapeId, Moment moment) => '$landscapeId|${moment.name}';

  /// The picture already made for this landscape and moment, or null (synchronous).
  Uri? peek(String landscapeId, Moment moment) => _done[_key(landscapeId, moment)];

  /// The picture of [landscape] at [moment], made if needed. Null when nothing could be made
  /// (never throws); a later call tries again.
  Future<Uri?> resolve(Landscape landscape, Moment moment) {
    final key = _key(landscape.id, moment);
    final done = _done[key];
    if (done != null) return Future.value(done);
    return _pending[key] ??= _resolve(landscape, moment).then((uri) {
      _pending.remove(key);
      if (uri != null) _done[key] = uri;
      return uri;
    });
  }

  Future<Uri?> _resolve(Landscape landscape, Moment moment) async {
    // 1. Bundled poster, copied once (named after its content: an app update never shows
    //    an old picture).
    try {
      final copy = await _bundledPoster(landscape.id);
      if (copy != null) return Uri.file(copy);
    } catch (e) {
      debugPrint('MediaArtwork: bundled poster of ${landscape.id} unavailable ($e)');
    }
    // 2. Poster downloaded for Premium.
    try {
      final downloaded = _downloadedPoster(landscape.id);
      if (await _files.exists(downloaded)) return Uri.file(downloaded);
    } catch (e) {
      debugPrint('MediaArtwork: downloaded poster of ${landscape.id} unavailable ($e)');
    }
    // 3. Procedural picture at the moment of the day.
    try {
      final path =
          '${_files.directory}/${landscape.id}-${moment.name}-v$renderVersion.png';
      if (!await _files.exists(path)) {
        final png = await _render(
          style: landscape.style,
          moment: moment,
          size: size,
        ).timeout(renderTimeout);
        await _files.write(path, png);
      }
      return Uri.file(path);
    } catch (e) {
      debugPrint('MediaArtwork: no picture for ${landscape.id} ($e)');
      return null;
    }
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
