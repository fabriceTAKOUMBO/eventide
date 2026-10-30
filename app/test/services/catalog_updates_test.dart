// Published catalog on the phone (contract § 13): GET /catalog with the revision held, 304,
// errors kept silent, the last valid answer kept atomically and used at the next launch.
import 'dart:io';

import 'package:eventide/core/catalog.dart';
import 'package:eventide/core/landscape_media.dart';
import 'package:eventide/services/api_client.dart';
import 'package:eventide/services/catalog_updates.dart';
import 'package:eventide/services/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fakes.dart';
import 'published_fixtures.dart';

void main() {
  late Directory dir;
  late LocalStore store;
  late List<http.Request> requests;
  late List<String> log;
  late DateTime now;
  late http.Response Function(http.Request request) server;
  final base = loadTestCatalog();
  final bundledRemote = RemoteLandscapeMedia.fromJson(bundledRemoteJson());

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('eventide_catalog_');
    store = LocalStore(Directory('${dir.path}/eventide'));
    await store.write(StoreKeys.installation, {'token': 'tok'});
    requests = [];
    log = [];
    now = DateTime(2026, 10, 30, 12);
    server = (_) => jsonResponse(catalogResponse(), 200);
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  CatalogUpdates build({bool backend = true}) {
    final client = MockClient((request) async {
      requests.add(request);
      return server(request);
    });
    return CatalogUpdates(
      api: ApiClient(
        baseUrl: backend ? 'https://api.test/v1' : '',
        client: client,
        store: store,
        native: FakeNativeBridge(),
        appVersion: '1.0.0',
        deviceSalt: 'salt',
      ),
      store: store,
      base: base,
      bundledRemote: bundledRemote,
      bundledAssets: () async => {'assets/landscapes/cascade-foret.jpg', 'assets/landscapes/cascade-foret.mp4'},
      now: () => now,
      log: log.add,
    );
  }

  File stored() => File('${dir.path}/eventide/${CatalogUpdates.storeName}.json');

  test('no backend: no file read, no request, the bundled catalog', () async {
    // Even a kept answer is not used: without API_BASE_URL the app behaves as before.
    await build().check();
    expect(stored().existsSync(), isTrue);
    requests.clear();
    final updates = build(backend: false);
    final shown = await updates.load();
    expect(shown.published, isFalse);
    expect(shown.catalog.landscape('lac-brume'), isNull);
    expect(shown.remote.videos, bundledRemote.videos);
    expect(await updates.check(), isNull);
    expect(updates.enabled, isFalse);
    expect(requests, isEmpty);
  });

  test('first launch: bundled catalog; the answer is applied, kept, then asked with its revision', () async {
    final updates = build();
    final first = await updates.load();
    expect(first.published, isFalse);
    expect(first.catalog.landscape('lac-brume'), isNull);
    expect(updates.due, isTrue);

    final next = await updates.check();
    expect(next, isNotNull);
    expect(next!.revision, 7);
    expect(next.catalog.landscape('lac-brume')!.name, 'Lac de brume');
    expect(next.remote.videos, contains('lac-brume'));
    expect(updates.current, same(next));
    expect(requests.single.url.toString(), 'https://api.test/v1/catalog');
    expect(requests.single.headers.containsKey('If-None-Match'), isFalse);
    expect(requests.single.headers['Authorization'], 'Bearer tok');
    // Kept atomically in <app support>/eventide/catalog-publie.json.
    expect(stored().existsSync(), isTrue);
    expect(File('${stored().path}.tmp').existsSync(), isFalse);
    expect(log.last, contains('révision 7'));

    // 304: nothing new.
    server = (_) => http.Response('', 304);
    expect(await updates.check(), isNull);
    expect(requests.last.headers['If-None-Match'], '"7"');
    expect(updates.current!.revision, 7);
  });

  test('kept answer: used at the next launch, before any request', () async {
    await build().check();
    requests.clear();
    final again = build();
    final shown = await again.load();
    expect(shown.published, isTrue);
    expect(shown.revision, 7);
    expect(shown.catalog.landscapesOfTheme('nature').last.id, 'lac-brume');
    expect(shown.catalog.item(LayerKind.son, 'ambiance-lac-brume')!.mediaRev, 2);
    // Its distant replaces remote.json.
    expect(shown.remote.images, contains('lac-brume'));
    expect(requests, isEmpty);
    expect(again.revision, 7);
  });

  test('a corrupted file is ignored and deleted', () async {
    stored().parent.createSync(recursive: true);
    stored().writeAsStringSync('{"version": 1, "data": {"response": {"revis');
    final updates = build();
    final shown = await updates.load();
    expect(shown.published, isFalse);
    expect(stored().existsSync(), isFalse);
    // Valid JSON, but not a valid answer (a newer app whose base it lacks): deleted too.
    final json = catalogResponse();
    ((json['catalog'] as Map<String, dynamic>)['sons'] as List).removeWhere((s) => (s as Map)['id'] == 'vent');
    await store.write(CatalogUpdates.storeName, {'response': json, 'withdrawn': {}});
    final shown2 = await build().load();
    expect(shown2.published, isFalse);
    expect(stored().existsSync(), isFalse);
    expect(log.last, contains('sons:vent'));
  });

  test('errors keep what the app has, silently (a line in the problem report)', () async {
    final updates = build();
    await updates.load();
    await updates.check();
    final held = updates.current;

    server = (_) => jsonResponse({'error': 'server_error'}, 500);
    expect(await updates.check(), isNull);
    expect(log.last, contains('500'));
    server = (_) => throw const SocketException('offline');
    expect(await updates.check(), isNull);
    expect(log.last, contains('pas de réponse'));
    server = (_) => http.Response('not json', 200);
    expect(await updates.check(), isNull);
    server = (_) {
      final json = catalogResponse(revision: 9);
      (json['catalog'] as Map<String, dynamic>)['version'] = 2;
      return jsonResponse(json, 200);
    };
    expect(await updates.check(), isNull);
    expect(log.last, contains('réponse ignorée'));
    expect(updates.current, same(held));
    expect(updates.revision, 7);
    // The kept answer is still the valid one.
    expect((await build().load()).revision, 7);
  });

  test('same revision again: nothing new', () async {
    final updates = build();
    await updates.check();
    expect(await updates.check(), isNull);
  });

  test('withdrawn items are remembered with the answer', () async {
    final updates = build();
    await updates.check();
    server = (_) => jsonResponse(catalogResponse(revision: 8, landscapes: [], sounds: [], music: []), 200);
    final next = await updates.check();
    expect(next!.catalog.landscape('lac-brume'), isNull);
    expect(next.catalog.landscapeFor('lac-brume')!.id, 'cascade-foret');
    final reloaded = await build().load();
    expect(reloaded.revision, 8);
    expect(reloaded.catalog.landscapeFor('lac-brume')!.id, 'cascade-foret');
  });

  test('asked again on return to the foreground once the last answer is an hour old', () async {
    final updates = build();
    expect(updates.due, isTrue);
    server = (_) => throw const SocketException('offline');
    await updates.check();
    expect(updates.due, isTrue, reason: 'no answer: asked again at the next return');
    server = (_) => http.Response('', 304);
    await updates.check();
    expect(updates.due, isFalse);
    now = now.add(const Duration(minutes: 59));
    expect(updates.due, isFalse);
    now = now.add(const Duration(minutes: 1));
    expect(updates.due, isTrue);
  });

  test('data deletion forgets the kept answer', () async {
    final updates = build();
    await updates.check();
    await updates.clear();
    expect(stored().existsSync(), isFalse);
    expect(updates.revision, isNull);
    expect((await build().load()).published, isFalse);
  });
}
