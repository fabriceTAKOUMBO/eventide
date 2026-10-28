import 'dart:convert';
import 'dart:io';

import 'package:eventide/core/catalog.dart';
import 'package:eventide/core/landscape_media.dart';
import 'package:eventide/services/api_client.dart';
import 'package:eventide/services/audio/audio_engine.dart';
import 'package:eventide/services/connectivity.dart';
import 'package:eventide/services/content_repository.dart';
import 'package:eventide/services/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fakes.dart';

void main() {
  late Directory dir;
  late List<Uri> fetched;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('eventide_content_');
    fetched = [];
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  ContentRepository build({
    Set<String> bundled = const {},
    String devBaseUrl = '',
    bool backend = false,
    bool offline = false,
    ConnectivityChecker? connectivity,
    RemoteLandscapeMedia remote = RemoteLandscapeMedia.none,
  }) {
    final client = MockClient((request) async {
      fetched.add(request.url);
      if (offline) throw http.ClientException('offline');
      if (request.url.path == '/v1/content/urls') {
        final keys = (jsonDecode(request.body) as Map)['keys'] as List;
        return http.Response(jsonEncode({
          'urls': {for (final k in keys) k: 'https://cdn.test/$k?sig=1'},
        }), 200);
      }
      if (request.url.path == '/v1/installations') {
        return http.Response(jsonEncode({'installation_id': 'i', 'token': 't'}), 201);
      }
      return http.Response('OGGDATA', 200);
    });
    final store = MemoryStore();
    return ContentRepository(
      directory: Directory('${dir.path}/content'),
      client: client,
      api: ApiClient(
        baseUrl: backend ? 'https://api.test/v1' : '',
        client: client,
        store: store..files[StoreKeys.installation] = jsonEncode({'version': 1, 'data': {'token': 't'}}),
        native: FakeNativeBridge(),
        appVersion: '1',
        deviceSalt: 's',
      ),
      bundledAssets: () async => bundled,
      connectivity: connectivity ?? FakeConnectivity(),
      devBaseUrl: devBaseUrl,
      remoteMedia: () async => remote,
    );
  }

  test('a bundled asset wins', () async {
    final repo = build(bundled: {'assets/audio/sons/eau-vive.ogg'});
    final source = await repo.resolve(LayerKind.son, 'eau-vive', allowNetwork: false);
    expect(source, const AssetAudioSource('assets/audio/sons/eau-vive.ogg'));
    expect(fetched, isEmpty);
  });

  test('debug: downloads unsigned from the local content server, then serves the cache', () async {
    final repo = build(devBaseUrl: 'http://10.0.2.2:8080/');
    final source = await repo.resolve(LayerKind.son, 'vagues', allowNetwork: true);
    expect(fetched.single.toString(), 'http://10.0.2.2:8080/audio/sons/vagues.ogg');
    expect(source, isA<FileAudioSource>());
    expect(File((source as FileAudioSource).path).readAsStringSync(), 'OGGDATA');
    expect(File('${source.path}.part').existsSync(), isFalse);
    final again = await repo.resolve(LayerKind.son, 'vagues', allowNetwork: false);
    expect(again, source);
    expect(fetched, hasLength(1));
    expect(await repo.isAvailableOffline(LayerKind.son, 'vagues'), isTrue);
  });

  test('release path: signed URL from POST /content/urls', () async {
    final repo = build(backend: true);
    await repo.resolve(LayerKind.musique, 'harpe', allowNetwork: true);
    expect(fetched.map((u) => u.toString()), [
      'https://api.test/v1/content/urls',
      'https://cdn.test/audio/musiques/harpe.ogg?sig=1',
    ]);
  });

  test('not available without network', () async {
    final repo = build(devBaseUrl: 'http://dev', offline: true);
    await expectLater(
      repo.resolve(LayerKind.son, 'vagues', allowNetwork: true),
      throwsA(isA<ContentUnavailableException>().having((e) => e.offline, 'offline', isTrue)),
    );
    await expectLater(
      repo.resolve(LayerKind.son, 'vagues', allowNetwork: false),
      throwsA(isA<ContentUnavailableException>()),
    );
  });

  test('no backend and no dev server: only bundled content', () async {
    final repo = build();
    await expectLater(
      repo.resolve(LayerKind.son, 'vagues', allowNetwork: true),
      throwsA(isA<ContentUnavailableException>().having((e) => e.offline, 'offline', isFalse)),
    );
  });

  test('Premium offline download respects « Wi-Fi seulement »', () async {
    final catalog = loadTestCatalog();
    final connectivity = FakeConnectivity(unmetered: false);
    final repo = build(devBaseUrl: 'http://dev', connectivity: connectivity);
    expect(await repo.prefetchForOffline(catalog, wifiOnly: true), 0);
    expect(fetched, isEmpty);
    connectivity.unmetered = true;
    final count = await repo.prefetchForOffline(catalog, wifiOnly: true);
    expect(count, catalog.sounds.length + catalog.music.length);
    expect(await repo.prefetchForOffline(catalog, wifiOnly: true), 0);
    await repo.clear();
    expect(await repo.isAvailableOffline(LayerKind.son, 'vagues'), isFalse);
  });

  group('landscape videos and posters', () {
    const pluie = RemoteLandscapeMedia(videos: {'pluie-ville'}, images: {'pluie-ville'});

    test('a bundled video wins, without any request (free landscapes, demo build)', () async {
      final repo = build(backend: true, remote: pluie, bundled: {
        'assets/landscapes/cascade-foret.mp4',
        'assets/landscapes/cascade-foret.jpg',
        'assets/landscapes/pluie-ville.mp4',
      });
      expect(
        await repo.landscapeVideo('cascade-foret', allowDownload: true, wifiOnly: false),
        const AssetLandscapeVideo('assets/landscapes/cascade-foret.mp4'),
      );
      expect(
        await repo.landscapeVideo('pluie-ville', allowDownload: false, wifiOnly: true),
        const AssetLandscapeVideo('assets/landscapes/pluie-ville.mp4'),
      );
      expect(await repo.landscapeImage('cascade-foret', allowDownload: true, wifiOnly: false), isNull,
          reason: 'bundled posters are found by the UI');
      expect(fetched, isEmpty);
    });

    test('Premium: poster and video by signed URL (videos/paysages/<id>.mp4), then the cache', () async {
      final repo = build(backend: true, remote: pluie);
      final poster = await repo.landscapeImage('pluie-ville', allowDownload: true, wifiOnly: false);
      final video = await repo.landscapeVideo('pluie-ville', allowDownload: true, wifiOnly: false);
      expect(fetched.map((u) => u.toString()), [
        'https://api.test/v1/content/urls',
        'https://cdn.test/images/paysages/pluie-ville.jpg?sig=1',
        'https://api.test/v1/content/urls',
        'https://cdn.test/videos/paysages/pluie-ville.mp4?sig=1',
      ]);
      expect(poster, endsWith('/images/paysages/pluie-ville.jpg'));
      expect(video, FileLandscapeVideo(repo.cachedPath('videos/paysages/pluie-ville.mp4')));
      expect(await repo.downloadedLandscapeImages(), {'pluie-ville'});
      fetched.clear();
      expect(await repo.landscapeVideo('pluie-ville', allowDownload: false, wifiOnly: true), video);
      expect(fetched, isEmpty);
    });

    test('never asks for a key the server does not have, nor when downloads are not allowed', () async {
      final repo = build(backend: true, remote: pluie);
      expect(await repo.landscapeVideo('lune-lac', allowDownload: true, wifiOnly: false), isNull);
      expect(await repo.landscapeVideo('pluie-ville', allowDownload: false, wifiOnly: false), isNull);
      expect(await repo.landscapeImage('pluie-ville', allowDownload: false, wifiOnly: false), isNull);
      expect(fetched, isEmpty);
    });

    test('« Wi-Fi seulement »: nothing on mobile data', () async {
      final connectivity = FakeConnectivity(unmetered: false);
      final repo = build(backend: true, remote: pluie, connectivity: connectivity);
      expect(await repo.landscapeVideo('pluie-ville', allowDownload: true, wifiOnly: true), isNull);
      expect(await repo.landscapeImage('pluie-ville', allowDownload: true, wifiOnly: true), isNull);
      expect(fetched, isEmpty);
      connectivity.unmetered = true;
      expect(await repo.landscapeVideo('pluie-ville', allowDownload: true, wifiOnly: true), isA<FileLandscapeVideo>());
    });

    test('a failed download gives no video (still picture), never an exception', () async {
      final repo = build(backend: true, remote: pluie, offline: true);
      expect(await repo.landscapeVideo('pluie-ville', allowDownload: true, wifiOnly: false), isNull);
    });

    test('Premium offline prefetch also brings the posters, not the videos', () async {
      final catalog = loadTestCatalog();
      final repo = build(devBaseUrl: 'http://dev', remote: pluie);
      final count = await repo.prefetchForOffline(catalog, wifiOnly: false);
      expect(count, catalog.sounds.length + catalog.music.length + 1);
      expect(fetched.map((u) => u.path), contains('/images/paysages/pluie-ville.jpg'));
      expect(fetched.map((u) => u.path), isNot(contains('/videos/paysages/pluie-ville.mp4')));
    });
  });
}
