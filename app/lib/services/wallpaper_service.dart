// A landscape as the phone's wallpaper (docs/app/architecture.md « Fond d'écran vidéo »).
//
// Live wallpaper: the native LandscapeWallpaperService (own process, `:wallpaper`) plays the
// selected landscape's looping video, muted, centre-cropped, paused whenever it is not
// visible; it shows the still picture when the video is missing or the plan no longer allows
// the landscape. This side puts the files where that process can read them (a bundled video
// or poster is copied to the app's storage; a downloaded Premium file is used in place),
// records the selection and opens Android's live wallpaper preview: the user confirms there,
// Android never lets an app change the wallpaper silently.
//
// Gallery: some phones (One UI's lock screen) only take a video from the Gallery; the video
// is copied there with MediaStore (Android 10+, no permission).
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/landscape_media.dart';
import '../core/wallpaper.dart';
import 'diagnostics.dart' show MethodChannelDeviceDiagnostics;

/// Native side (channel be.cinaf.eventide/device).
abstract class WallpaperPlatform {
  Future<WallpaperSupport> support();

  /// Landscape of the recorded live wallpaper selection, or null.
  Future<String?> selectedLandscape();

  /// Records the selection for the wallpaper service and opens Android's preview of our live
  /// wallpaper. Returns [WallpaperResult.opened], [WallpaperResult.unsupported] or
  /// [WallpaperResult.failed].
  Future<WallpaperResult> setLiveWallpaper({
    required String landscapeId,
    required String name,
    String? videoPath,
    String? posterPath,
    required bool allowed,
  });

  /// The plan may (no longer) use the selected landscape: video, or still picture only.
  Future<void> setAllowed(bool allowed);

  Future<bool> saveVideoToGallery({required String path, required String title});

  /// Forgets the selection (data deletion): the wallpaper then shows a plain background.
  Future<void> clearSelection();
}

class MethodChannelWallpaperPlatform implements WallpaperPlatform {
  MethodChannelWallpaperPlatform({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(MethodChannelDeviceDiagnostics.deviceChannelName);

  final MethodChannel _channel;

  Future<T?> _invoke<T>(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      debugPrint('WallpaperPlatform.$method: ${e.code} ${e.message}');
      return null;
    }
  }

  @override
  Future<WallpaperSupport> support() async {
    final map = await _invoke<Map<Object?, Object?>>('wallpaperSupport');
    if (map == null) return WallpaperSupport.none;
    return WallpaperSupport(liveWallpaper: map['live'] == true, gallery: map['gallery'] == true);
  }

  @override
  Future<String?> selectedLandscape() => _invoke<String>('wallpaperSelection');

  @override
  Future<WallpaperResult> setLiveWallpaper({
    required String landscapeId,
    required String name,
    String? videoPath,
    String? posterPath,
    required bool allowed,
  }) async {
    final answer = await _invoke<String>('setLiveWallpaper', {
      'landscape_id': landscapeId,
      'name': name,
      'video': videoPath,
      'poster': posterPath,
      'allowed': allowed,
    });
    return switch (answer) {
      'opened' => WallpaperResult.opened,
      'unsupported' => WallpaperResult.unsupported,
      _ => WallpaperResult.failed,
    };
  }

  @override
  Future<void> setAllowed(bool allowed) => _invoke<bool>('setWallpaperAllowed', allowed);

  @override
  Future<bool> saveVideoToGallery({required String path, required String title}) async =>
      await _invoke<bool>('saveVideoToGallery', {'path': path, 'title': title}) ?? false;

  @override
  Future<void> clearSelection() => _invoke<bool>('clearWallpaper');
}

/// Files of the wallpaper (a real folder in the app, a temporary one in tests).
class LandscapeWallpaper {
  LandscapeWallpaper({
    required this.platform,
    required this.directory,
    required this._bundledAssets,
    required this._loadAsset,
  });

  final WallpaperPlatform platform;

  /// `<app support>/wallpaper`: the copies of bundled media (only the selected landscape's).
  final Directory directory;
  final Future<Set<String>> Function() _bundledAssets;
  final Future<Uint8List> Function(String asset) _loadAsset;

  WallpaperSupport _support = WallpaperSupport.none;
  String? _selected;
  bool? _allowedSent;

  WallpaperSupport get support => _support;

  /// Landscape of the live wallpaper selection (null: none recorded).
  String? get selected => _selected;

  Future<void> init() async {
    try {
      _support = await platform.support();
      _selected = await platform.selectedLandscape();
    } catch (e) {
      debugPrint('LandscapeWallpaper: unavailable ($e)');
    }
  }

  /// A file the native side can read for [video]: the downloaded file itself, or a copy of the
  /// bundled asset (written once, again only if its size changed).
  Future<String?> videoFile(String landscapeId, LandscapeVideoSource? video) async {
    switch (video) {
      case null:
        return null;
      case FileLandscapeVideo(:final path):
        return await File(path).exists() ? path : null;
      case AssetLandscapeVideo(:final asset):
        return _copyAsset(asset, '$landscapeId.mp4');
    }
  }

  /// The still picture: bundled poster (copied), else the downloaded one, else null.
  Future<String?> posterFile(String landscapeId, {String? downloaded}) async {
    final asset = LandscapeMediaKeys.bundledImage(landscapeId);
    try {
      if ((await _bundledAssets()).contains(asset)) return await _copyAsset(asset, '$landscapeId.jpg');
    } catch (_) {}
    if (downloaded != null && await File(downloaded).exists()) return downloaded;
    return null;
  }

  Future<String?> _copyAsset(String asset, String name) async {
    try {
      final bytes = await _loadAsset(asset);
      final target = File('${directory.path}/$name');
      if (await target.exists() && await target.length() == bytes.length) return target.path;
      await directory.create(recursive: true);
      final tmp = File('${target.path}.part');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(target.path);
      return target.path;
    } catch (e) {
      debugPrint('LandscapeWallpaper: cannot copy $asset ($e)');
      return null;
    }
  }

  /// Copies of other landscapes are removed: only the selected wallpaper stays on disk.
  Future<void> _removeOthers(String landscapeId) async {
    try {
      if (!await directory.exists()) return;
      await for (final entity in directory.list()) {
        final name = entity.uri.pathSegments.isEmpty ? '' : entity.uri.pathSegments.last;
        if (entity is File && !name.startsWith('$landscapeId.')) await entity.delete();
      }
    } catch (_) {}
  }

  /// Records the landscape and opens Android's live wallpaper preview.
  Future<WallpaperResult> apply({
    required String landscapeId,
    required String name,
    required LandscapeVideoSource? video,
    String? downloadedPoster,
  }) async {
    if (!_support.liveWallpaper) return WallpaperResult.unsupported;
    final videoPath = await videoFile(landscapeId, video);
    final posterPath = await posterFile(landscapeId, downloaded: downloadedPoster);
    if (videoPath == null && posterPath == null) return WallpaperResult.unavailable;
    final result = await platform.setLiveWallpaper(
      landscapeId: landscapeId,
      name: name,
      videoPath: videoPath,
      posterPath: posterPath,
      allowed: true,
    );
    if (result == WallpaperResult.opened) {
      _selected = landscapeId;
      _allowedSent = true;
      await _removeOthers(landscapeId);
    }
    return result;
  }

  /// Saves the landscape's video to the Gallery (`Movies/Eventide`).
  Future<bool> saveToGallery({
    required String landscapeId,
    required String name,
    required LandscapeVideoSource? video,
  }) async {
    if (!_support.gallery) return false;
    final path = await videoFile(landscapeId, video);
    if (path == null) return false;
    final saved = await platform.saveVideoToGallery(path: path, title: 'Eventide - $name');
    // A copy made only for the Gallery is not kept (the wallpaper's own files stay).
    if (video is AssetLandscapeVideo && landscapeId != _selected) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
    return saved;
  }

  /// Tells the wallpaper whether the plan still allows its landscape (sent when it changes).
  Future<void> syncAllowed(bool Function(String landscapeId) allowed) async {
    final id = _selected;
    if (id == null) return;
    final now = allowed(id);
    if (now == _allowedSent) return;
    _allowedSent = now;
    await platform.setAllowed(now);
  }

  /// Data deletion.
  Future<void> clear() async {
    _selected = null;
    _allowedSent = null;
    await platform.clearSelection();
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
    } catch (_) {}
  }
}
