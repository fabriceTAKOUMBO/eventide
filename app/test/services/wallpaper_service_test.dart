// Landscape as wallpaper: which files the wallpaper process gets, the selection, the Gallery
// copy, and the native channel's contract.
import 'dart:io';

import 'package:eventide/core/landscape_media.dart';
import 'package:eventide/core/wallpaper.dart';
import 'package:eventide/services/wallpaper_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'device_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late FakeWallpaperPlatform platform;
  late LandscapeWallpaper wallpaper;
  late List<String> loads;
  final assets = <String, Uint8List>{
    'assets/landscapes/cascade-foret.mp4': Uint8List.fromList(List.filled(64, 1)),
    'assets/landscapes/cascade-foret.jpg': Uint8List.fromList(List.filled(16, 2)),
    'assets/landscapes/sous-bois.mp4': Uint8List.fromList(List.filled(32, 3)),
  };

  setUp(() async {
    root = await Directory.systemTemp.createTemp('eventide-wallpaper');
    platform = FakeWallpaperPlatform();
    loads = [];
    wallpaper = LandscapeWallpaper(
      platform: platform,
      directory: Directory('${root.path}/wallpaper'),
      bundledAssets: () async => assets.keys.toSet(),
      loadAsset: (asset) async {
        loads.add(asset);
        final bytes = assets[asset];
        if (bytes == null) throw StateError('no asset $asset');
        return bytes;
      },
    );
    await wallpaper.init();
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('bundled video and poster are copied for the wallpaper process, then Android\'s preview opens', () async {
    final result = await wallpaper.apply(
      landscapeId: 'cascade-foret',
      name: 'Cascade en forêt',
      video: const AssetLandscapeVideo('assets/landscapes/cascade-foret.mp4'),
    );
    expect(result, WallpaperResult.opened);
    final sent = platform.set.single;
    expect(sent['id'], 'cascade-foret');
    expect(sent['allowed'], isTrue);
    expect(File(sent['video']! as String).readAsBytesSync(), assets['assets/landscapes/cascade-foret.mp4']);
    expect(File(sent['poster']! as String).readAsBytesSync(), assets['assets/landscapes/cascade-foret.jpg']);
    expect(wallpaper.selected, 'cascade-foret');
    // Again: same files, nothing rewritten.
    final before = File(sent['video']! as String).lastModifiedSync();
    await wallpaper.apply(
      landscapeId: 'cascade-foret',
      name: 'Cascade en forêt',
      video: const AssetLandscapeVideo('assets/landscapes/cascade-foret.mp4'),
    );
    expect(File(sent['video']! as String).lastModifiedSync(), before);
  });

  test('a downloaded Premium video and poster are used in place; copies of other landscapes go', () async {
    await wallpaper.apply(
      landscapeId: 'cascade-foret',
      name: 'Cascade en forêt',
      video: const AssetLandscapeVideo('assets/landscapes/cascade-foret.mp4'),
    );
    final content = Directory('${root.path}/content')..createSync();
    final video = File('${content.path}/pluie-ville.mp4')..writeAsBytesSync([1, 2, 3]);
    final poster = File('${content.path}/pluie-ville.jpg')..writeAsBytesSync([4, 5]);
    final result = await wallpaper.apply(
      landscapeId: 'pluie-ville',
      name: 'Pluie sur la ville',
      video: FileLandscapeVideo(video.path),
      downloadedPoster: poster.path,
    );
    expect(result, WallpaperResult.opened);
    expect(platform.set.last['video'], video.path);
    expect(platform.set.last['poster'], poster.path);
    expect(Directory('${root.path}/wallpaper').listSync(), isEmpty, reason: 'cascade-foret copies removed');
  });

  test('still picture only when there is no video; nothing at all: unavailable', () async {
    final still = await wallpaper.apply(landscapeId: 'cascade-foret', name: 'Cascade', video: null);
    expect(still, WallpaperResult.opened);
    expect(platform.set.single['video'], isNull);
    expect(platform.set.single['poster'], isNotNull);
    final none = await wallpaper.apply(
      landscapeId: 'lune-lac',
      name: 'Lune sur le lac',
      video: FileLandscapeVideo('${root.path}/missing.mp4'),
      downloadedPoster: '${root.path}/missing.jpg',
    );
    expect(none, WallpaperResult.unavailable);
    expect(platform.set, hasLength(1));
  });

  test('no live wallpaper on this phone: unsupported, nothing recorded', () async {
    platform.supported = const WallpaperSupport(gallery: true);
    await wallpaper.init();
    final result = await wallpaper.apply(
      landscapeId: 'cascade-foret',
      name: 'Cascade',
      video: const AssetLandscapeVideo('assets/landscapes/cascade-foret.mp4'),
    );
    expect(result, WallpaperResult.unsupported);
    expect(platform.set, isEmpty);
    expect(loads, isEmpty);
  });

  test('preview refused by Android: the selection is not taken as set', () async {
    platform.answer = WallpaperResult.failed;
    final result = await wallpaper.apply(landscapeId: 'cascade-foret', name: 'Cascade', video: null);
    expect(result, WallpaperResult.failed);
    expect(wallpaper.selected, isNull);
  });

  test('the plan follows: allowed or not is sent once per change, only with a selection', () async {
    await wallpaper.syncAllowed((_) => false);
    expect(platform.allowed, isEmpty, reason: 'no wallpaper selected');
    platform.selection = 'pluie-ville';
    await wallpaper.init();
    var premium = true;
    await wallpaper.syncAllowed((id) => premium);
    await wallpaper.syncAllowed((id) => premium);
    premium = false;
    await wallpaper.syncAllowed((id) => premium);
    await wallpaper.syncAllowed((id) => premium);
    expect(platform.allowed, [true, false]);
  });

  test('Gallery: the video is copied there; a copy made only for it is not kept', () async {
    final ok = await wallpaper.saveToGallery(
      landscapeId: 'sous-bois',
      name: 'Sous-bois ensoleillé',
      video: const AssetLandscapeVideo('assets/landscapes/sous-bois.mp4'),
    );
    expect(ok, isTrue);
    expect(platform.gallery.single.$2, 'Eventide - Sous-bois ensoleillé');
    expect(File(platform.gallery.single.$1).existsSync(), isFalse);
    // No video, or no Gallery on this phone (Android 9 and older): nothing saved.
    expect(await wallpaper.saveToGallery(landscapeId: 'lune-lac', name: 'Lune', video: null), isFalse);
    platform.supported = const WallpaperSupport(liveWallpaper: true);
    await wallpaper.init();
    expect(
      await wallpaper.saveToGallery(
        landscapeId: 'sous-bois',
        name: 'Sous-bois',
        video: const AssetLandscapeVideo('assets/landscapes/sous-bois.mp4'),
      ),
      isFalse,
    );
    expect(platform.gallery, hasLength(1));
  });

  test('data deletion: selection and copies forgotten', () async {
    await wallpaper.apply(landscapeId: 'cascade-foret', name: 'Cascade', video: null);
    await wallpaper.clear();
    expect(platform.clears, 1);
    expect(wallpaper.selected, isNull);
    expect(Directory('${root.path}/wallpaper').existsSync(), isFalse);
  });

  group('native channel', () {
    const channel = MethodChannel('be.cinaf.eventide/device');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('arguments and answers', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'wallpaperSupport' => {'live': true, 'gallery': false},
          'wallpaperSelection' => 'cascade-foret',
          'setLiveWallpaper' => 'opened',
          'saveVideoToGallery' => true,
          _ => true,
        };
      });
      final native = MethodChannelWallpaperPlatform();
      expect(await native.support(), const WallpaperSupport(liveWallpaper: true));
      expect(await native.selectedLandscape(), 'cascade-foret');
      expect(
        await native.setLiveWallpaper(
          landscapeId: 'cascade-foret',
          name: 'Cascade en forêt',
          videoPath: '/data/v.mp4',
          posterPath: null,
          allowed: true,
        ),
        WallpaperResult.opened,
      );
      expect(calls[2].arguments, {
        'landscape_id': 'cascade-foret',
        'name': 'Cascade en forêt',
        'video': '/data/v.mp4',
        'poster': null,
        'allowed': true,
      });
      await native.setAllowed(false);
      expect(calls[3].method, 'setWallpaperAllowed');
      expect(calls[3].arguments, false);
      expect(await native.saveVideoToGallery(path: '/data/v.mp4', title: 'Eventide - Cascade'), isTrue);
      await native.clearSelection();
      expect(calls.last.method, 'clearWallpaper');
    });

    test('unknown or missing answers', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => call.method == 'setLiveWallpaper' ? 'unsupported' : null);
      final native = MethodChannelWallpaperPlatform();
      expect(await native.support(), WallpaperSupport.none);
      expect(
        await native.setLiveWallpaper(landscapeId: 'a', name: 'A', allowed: true),
        WallpaperResult.unsupported,
      );
      messenger.setMockMethodCallHandler(channel, null);
      expect(await native.setLiveWallpaper(landscapeId: 'a', name: 'A', allowed: true), WallpaperResult.failed);
      expect(await native.saveVideoToGallery(path: 'p', title: 't'), isFalse);
    });
  });
}
