// RealAppModel and the published catalog (contract § 13): asked after the first screen and on
// returns to the foreground, applied without a restart, never interrupting the scene being
// played; withdrawn items fall back like retired ones; nothing at all without a backend.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:eventide/app/app_controller.dart';
import 'package:eventide/app/app_model.dart';
import 'package:eventide/core/catalog.dart';
import 'package:eventide/core/landscape_media.dart';
import 'package:eventide/core/plan.dart';
import 'package:eventide/core/scene.dart';
import 'package:eventide/core/schedule.dart';
import 'package:eventide/core/share_codec.dart';
import 'package:eventide/services/api_client.dart';
import 'package:eventide/services/audio/audio_engine.dart';
import 'package:eventide/services/audio/fake_audio_engine.dart';
import 'package:eventide/services/audio/playback_handler.dart';
import 'package:eventide/services/catalog_updates.dart';
import 'package:eventide/services/content_repository.dart';
import 'package:eventide/services/storage.dart';
import 'package:eventide/services/wallpaper_service.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../services/device_fakes.dart';
import '../services/fakes.dart';
import '../services/published_fixtures.dart';

/// Every file of assets/landscapes (posters and videos of the bundled landscapes).
Set<String> _bundledLandscapeMedia() => {
  for (final entity in Directory('assets/landscapes').listSync())
    if (entity is File) 'assets/landscapes/${entity.uri.pathSegments.last}',
};

class _Live {
  _Live(this.root);

  final Directory root;
  final base = loadTestCatalog();
  final store = MemoryStore();
  final engine = FakeAudioEngine();
  final native = FakeNativeBridge();
  final connectivity = FakeConnectivity();
  final wallpaperPlatform = FakeWallpaperPlatform();
  final links = FakeLinks();
  final events = <AppEvent>[];

  /// Every request sent (API and content server).
  final requests = <http.Request>[];

  /// Answer of GET /catalog.
  http.Response Function(http.Request request) catalog = (_) => jsonResponse(catalogResponse());
  DateTime now = DateTime(2026, 10, 30, 21);
  late PlaybackHandler handler;
  late CatalogUpdates updates;
  late RealAppModel model;

  List<http.Request> get catalogRequests => [
    for (final r in requests)
      if (r.url.path == '/v1/catalog') r,
  ];

  List<String> get contentFetched => [
    for (final r in requests)
      if (r.url.host == 'cdn.test') r.url.path,
  ];

  Future<RealAppModel> start({Plan? plan, bool backend = true}) async {
    store.files[StoreKeys.installation] = jsonEncode({'version': 1, 'data': {'token': 't'}});
    handler = PlaybackHandler(engine: engine, focus: FakeFocus(), native: native, now: () => now);
    final client = MockClient((request) async {
      requests.add(request);
      if (request.url.host == 'cdn.test') return http.Response('DATA', 200);
      switch (request.url.path) {
        case '/v1/catalog':
          return catalog(request);
        case '/v1/entitlements':
          return jsonResponse({'plan': 'free', 'premium': false});
        case '/v1/content/urls':
          final keys = (jsonDecode(request.body) as Map)['keys'] as List;
          return jsonResponse({
            'urls': {for (final k in keys) k: 'https://cdn.test/$k'},
            'expires_at': '2026-10-30T22:00:00Z',
          });
      }
      return jsonResponse({'error': 'not_found'}, 404);
    });
    final api = ApiClient(
      baseUrl: backend ? 'https://api.test/v1' : '',
      client: client,
      store: store,
      native: native,
      appVersion: '1.0.0',
      deviceSalt: 'salt',
    );
    final assets = {...allBundledAudio(base), ..._bundledLandscapeMedia()};
    updates = CatalogUpdates(
      api: api,
      store: store,
      base: base,
      bundledRemote: RemoteLandscapeMedia.fromJson(bundledRemoteJson()),
      bundledAssets: () async => assets,
      now: () => now,
      log: (_) {},
    );
    final shown = await updates.load();
    final content = ContentRepository(
      directory: Directory('${root.path}/content'),
      client: client,
      api: api,
      bundledAssets: () async => assets,
      connectivity: connectivity,
      remoteMedia: () async => shown.remote,
    );
    model = RealAppModel(
      catalog: shown.catalog,
      store: store,
      handler: handler,
      content: content,
      native: native,
      api: api,
      connectivity: connectivity,
      billing: FakeBilling(),
      ads: FakeAds(),
      account: FakeAccount(),
      links: links,
      share: FakeShare(),
      permissions: FakePermissions(),
      urls: FakeUrlOpener(),
      config: AppConfig(forcedPlan: plan, browseDebounce: const Duration(milliseconds: 60)),
      wallpaper: LandscapeWallpaper(
        platform: wallpaperPlatform,
        directory: Directory('${root.path}/wallpaper'),
        bundledAssets: () async => assets,
        loadAsset: (asset) async => Uint8List.fromList(asset.codeUnits),
      ),
      catalogUpdates: updates,
      now: () => now,
      random: Random(7),
    );
    model.events.listen(events.add);
    await model.init();
    await settle();
    return model;
  }

  /// The published catalog without any published item (everything withdrawn).
  void withdrawAll({int revision = 8}) =>
      catalog = (_) => jsonResponse(catalogResponse(revision: revision, landscapes: [], sounds: [], music: []));
}

void main() {
  late Directory root;
  late _Live h;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('eventide_live_');
    h = _Live(root);
  });

  tearDown(() async {
    h.model.dispose();
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('asked once the first screen is drawn, never during the start', () async {
    final model = await h.start(plan: Plan.annual);
    model.handleLifecycle(AppLifecycleState.resumed);
    await settle();
    expect(h.catalogRequests, isEmpty, reason: 'the start does not wait for it');
    expect(model.catalog.landscape('lac-brume'), isNull);
    var notified = 0;
    model.addListener(() => notified++);
    await model.startCatalogUpdates();
    expect(h.catalogRequests, hasLength(1));
    expect(model.catalog.landscape('lac-brume')!.name, 'Lac de brume');
    expect(model.remoteLandscapeVideos, contains('lac-brume'));
    expect(notified, greaterThan(0));
    // Started once only.
    await model.startCatalogUpdates();
    expect(h.catalogRequests, hasLength(1));
  });

  test('a newer catalog shows new landscapes, sounds and music without interrupting playback', () async {
    final model = await h.start(plan: Plan.annual);
    await model.play();
    expect(model.playing, isTrue);
    final keys = {...h.engine.activeKeys};
    final calls = [...h.engine.calls];
    final scene = model.scene;

    expect(await model.checkPublishedCatalog(), isTrue);

    // The lists: theme page, « Ajouter un son » (the ambiance with its landscape only), melodies.
    expect(model.catalog.landscapesOfTheme('nature').map((l) => l.id), contains('lac-brume'));
    final ambiance = model.catalog.item(LayerKind.son, 'ambiance-lac-brume')!;
    expect(model.catalog.items(LayerKind.son), contains(ambiance));
    expect(ambiance.offeredWith('lac-brume'), isTrue);
    expect(ambiance.offeredWith(model.scene.landscapeId), isFalse);
    expect(model.catalog.items(LayerKind.musique).map((m) => m.id), contains('harpe-celeste'));
    // Nothing of the playback changed.
    expect(model.playing, isTrue);
    expect(model.scene, scene);
    expect(h.engine.activeKeys, keys);
    expect(h.engine.calls, calls);
    // Premium: the new sounds and posters come in the background, under their revision.
    await settle(50);
    expect(h.contentFetched, containsAll(['/audio/sons/ambiance-lac-brume.v2.ogg', '/images/paysages/lac-brume.v2.jpg']));
    expect(model.landscapePosterFile('lac-brume'), endsWith('/images/paysages/lac-brume.v2.jpg'));

    // The new landscape plays with its ambiance and melody (downloaded files).
    model.selectLandscape('lac-brume');
    await settle(50);
    expect(h.engine.activeKeys, containsAll(['son:ambiance-lac-brume', 'son:vent', 'musique:harpe-celeste']));
    expect(model.mediaCard.value!.title, 'Lac de brume');
  });

  test('withdrawn while being played: the scene goes on, then gives way to cascade-foret', () async {
    final model = await h.start(plan: Plan.annual);
    await model.startCatalogUpdates();
    model.selectLandscape('lac-brume');
    await model.play();
    await settle(50);
    expect(h.engine.activeKeys, containsAll(['son:ambiance-lac-brume', 'musique:harpe-celeste']));
    final calls = [...h.engine.calls];

    h.withdrawAll();
    expect(await model.checkPublishedCatalog(), isTrue);
    // Out of the lists...
    expect(model.catalog.landscapesOfTheme('nature').map((l) => l.id), isNot(contains('lac-brume')));
    expect(model.catalog.items(LayerKind.son).map((s) => s.id), isNot(contains('ambiance-lac-brume')));
    // ...but the scene being played is untouched: sound, landscape, lock screen card.
    expect(model.scene.landscapeId, 'lac-brume');
    expect(model.browsedLandscapeId, 'lac-brume');
    expect(model.playing, isTrue);
    expect(h.engine.calls, calls);
    expect(model.mediaCard.value!.title, 'Lac de brume');
    expect(model.mediaCard.value!.artist, contains('Ambiance du lac'));
    // A level change keeps the withdrawn layers playing (same files).
    model.setLayerLevel(LayerKind.son, 'vent', 50);
    await settle(50);
    expect(h.engine.activeKeys, containsAll(['son:ambiance-lac-brume', 'son:vent', 'musique:harpe-celeste']));
    expect(h.engine.calls, isNot(contains('stop')));

    // Once it stops: cascade-foret, the withdrawn sound and melody leave the mix.
    await h.handler.stop();
    await settle();
    expect(model.scene.landscapeId, 'cascade-foret');
    expect(model.scene.sounds.map((l) => l.id), ['vent']);
    expect(model.scene.music, isEmpty);
    expect(model.catalog.landscape('lac-brume'), isNull);
    expect(model.browsedLandscapeId, 'cascade-foret');
  });

  test('a favourite, a schedule or a link naming a withdrawn landscape opens on cascade-foret', () async {
    final model = await h.start(plan: Plan.annual);
    await model.startCatalogUpdates();
    model.selectLandscape('lac-brume');
    await model.toggleFavorite();
    final link = shareLinkFor(model.scene, 'eventide.app');
    final schedule = model.newScheduleDraft();
    expect(schedule.landscapeId, 'lac-brume');
    expect(await model.saveSchedule(schedule), isTrue);
    expect(h.native.lastPayload['schedules'].single['paysage_nom'], 'Lac de brume');

    h.withdrawAll();
    expect(await model.checkPublishedCatalog(), isTrue);
    await settle();
    // Nothing was playing: the scene follows at once (sounds kept, withdrawn ones removed).
    expect(model.scene.landscapeId, 'cascade-foret');
    expect(model.scene.sounds.map((l) => l.id), ['vent']);
    final favourite = model.favorites.single;
    expect(favourite.landscapeId, 'cascade-foret');
    expect(favourite.scene.sounds.map((l) => l.id), ['vent']);
    expect(model.schedules.single.landscapeId, 'cascade-foret');
    expect(h.native.lastPayload['schedules'].single['paysage'], 'cascade-foret');

    model.selectLandscape('pluie-ville');
    model.applyFavorite(favourite);
    expect(model.scene.landscapeId, 'cascade-foret');
    model.selectLandscape('pluie-ville');
    await model.openLink(link);
    expect(model.scene.landscapeId, 'cascade-foret');
    expect(model.scene.sounds.map((l) => l.id), ['vent']);
    // Kept across launches: a link opened later still falls back.
    final stored = await h.store.readMap(CatalogUpdates.storeName);
    expect((stored!['withdrawn'] as Map)['paysages'], ['lac-brume']);
  });

  test('a link naming a landscape published since the last answer asks for the catalog once', () async {
    final model = await h.start(plan: Plan.annual);
    final shared = Scene(landscapeId: 'lac-brume', sounds: const [Layer(id: 'vent', level: 40)]);
    await model.openLink(shareLinkFor(shared, 'eventide.app'));
    expect(h.catalogRequests, hasLength(1));
    expect(model.scene.landscapeId, 'lac-brume');
    // An unknown landscape that is not published: asked at most once every 2 minutes.
    final unknown = Scene(landscapeId: 'jamais-publie', sounds: const [Layer(id: 'vent', level: 40)]);
    await model.openLink(shareLinkFor(unknown, 'eventide.app'));
    await model.openLink(shareLinkFor(unknown, 'eventide.app').replace(fragment: '${encodeSceneForLink(unknown)}x'));
    expect(h.catalogRequests, hasLength(1));
    expect(model.scene.landscapeId, 'lac-brume');
  });

  test('the catalog kept from an earlier launch is shown at once, without a request', () async {
    await h.store.write(CatalogUpdates.storeName, {'response': catalogResponse(), 'withdrawn': <String, dynamic>{}});
    final model = await h.start(plan: Plan.annual);
    expect(model.catalog.landscape('lac-brume'), isNotNull);
    expect(model.remoteLandscapeVideos, contains('lac-brume'));
    expect(h.catalogRequests, isEmpty);
    await model.startCatalogUpdates();
    expect(h.catalogRequests.single.headers['If-None-Match'], '"7"');
  });

  test('asked again on return to the foreground once the last answer is an hour old', () async {
    final model = await h.start(plan: Plan.annual);
    model.handleLifecycle(AppLifecycleState.resumed);
    await settle();
    await model.startCatalogUpdates();
    expect(h.catalogRequests, hasLength(1));
    h.catalog = (_) => http.Response('', 304);
    model.handleLifecycle(AppLifecycleState.paused);
    model.handleLifecycle(AppLifecycleState.resumed);
    await settle();
    expect(h.catalogRequests, hasLength(1), reason: 'answered less than an hour ago');
    h.now = h.now.add(const Duration(minutes: 61));
    model.handleLifecycle(AppLifecycleState.paused);
    model.handleLifecycle(AppLifecycleState.resumed);
    await settle();
    expect(h.catalogRequests, hasLength(2));
    expect(h.catalogRequests.last.headers['If-None-Match'], '"7"');
    expect(model.catalog.landscape('lac-brume'), isNotNull, reason: '304: kept');
  });

  test('without a backend (API_BASE_URL empty), nothing of this runs: no file, no network', () async {
    await h.store.write(CatalogUpdates.storeName, {'response': catalogResponse(), 'withdrawn': <String, dynamic>{}});
    final model = await h.start(plan: Plan.annual, backend: false);
    expect(model.catalog.landscape('lac-brume'), isNull);
    expect(model.remoteLandscapeVideos, isNull);
    model.handleLifecycle(AppLifecycleState.resumed);
    await model.startCatalogUpdates();
    expect(await model.checkPublishedCatalog(), isFalse);
    h.now = h.now.add(const Duration(hours: 2));
    model.handleLifecycle(AppLifecycleState.paused);
    model.handleLifecycle(AppLifecycleState.resumed);
    final shared = Scene(landscapeId: 'lac-brume', sounds: const [Layer(id: 'vent', level: 40)]);
    await model.openLink(shareLinkFor(shared, 'eventide.app'));
    await settle();
    expect(h.requests, isEmpty);
    expect(h.store.files.containsKey(CatalogUpdates.storeName), isTrue, reason: 'not even deleted');
  });

  test('a free published landscape: poster and video are downloaded for a free user', () async {
    h.catalog = (_) => jsonResponse(catalogResponse(
      landscapes: [lacBrume(free: true), lacBrume(free: false)..['id'] = 'lac-premium'],
      sounds: [ambianceLacBrume(free: true)],
    ));
    final model = await h.start(plan: Plan.free);
    await model.startCatalogUpdates();
    await settle(50);
    // Posters of the published landscapes the plan can use come in the background.
    expect(h.contentFetched, contains('/images/paysages/lac-brume.v2.jpg'));
    expect(h.contentFetched, isNot(contains('/images/paysages/lac-premium.v2.jpg')));
    expect(model.landscapePosterFile('lac-brume'), endsWith('/images/paysages/lac-brume.v2.jpg'));
    final video = await model.landscapeVideo('lac-brume');
    expect(video, isA<FileLandscapeVideo>().having((v) => v.path, 'path', endsWith('/videos/paysages/lac-brume.v2.mp4')));
    // A Premium one stays locked: nothing asked for it.
    expect(await model.landscapeVideo('lac-premium'), isNull);
    expect(h.contentFetched.where((p) => p.contains('lac-premium')), isEmpty);
    // Its ambiance plays for the free user (free key signed for everyone).
    model.selectLandscape('lac-brume');
    await model.play();
    await settle(50);
    expect(h.engine.activeKeys, contains('son:ambiance-lac-brume'));
    expect(h.contentFetched, contains('/audio/sons/ambiance-lac-brume.v2.ogg'));
    // Base landscapes: today's rule (a free user downloads nothing for them).
    expect(h.contentFetched.where((p) => p.contains('pluie-ville')), isEmpty);
  });

  test('a replaced file (new media_rev) is used for the next session, never in the middle of one', () async {
    final model = await h.start(plan: Plan.annual);
    await model.startCatalogUpdates();
    model.selectLandscape('lac-brume');
    await model.play();
    await settle(50);
    String playedFile() =>
        (h.engine.layers.firstWhere((l) => l.key == 'son:ambiance-lac-brume').source as FileAudioSource).path;
    expect(playedFile(), endsWith('/audio/sons/ambiance-lac-brume.v2.ogg'));
    h.catalog = (_) => jsonResponse(catalogResponse(revision: 8, sounds: [ambianceLacBrume(rev: 3)]));
    expect(await model.checkPublishedCatalog(), isTrue);
    await settle(50);
    // Premium: the new file comes in the background, but the session keeps the one it plays.
    expect(h.contentFetched, contains('/audio/sons/ambiance-lac-brume.v3.ogg'));
    model.setLayerLevel(LayerKind.son, 'ambiance-lac-brume', 30);
    await settle(50);
    expect(playedFile(), endsWith('/audio/sons/ambiance-lac-brume.v2.ogg'));
    expect(h.engine.calls, isNot(contains('stop')));
    await h.handler.stop();
    await model.play();
    await settle(50);
    expect(playedFile(), endsWith('/audio/sons/ambiance-lac-brume.v3.ogg'));
  });

  test('the wallpaper of a published landscape keeps working across updates and restarts', () async {
    final model = await h.start(plan: Plan.annual);
    await model.startCatalogUpdates();
    final result = await model.setLandscapeWallpaper('lac-brume');
    expect(result.name, 'opened');
    final set = h.wallpaperPlatform.set.single;
    expect(set['video'], endsWith('/videos/paysages/lac-brume.v2.mp4'));
    h.wallpaperPlatform.selection = 'lac-brume';
    // A newer catalog with a new revision of its files: the wallpaper stays allowed.
    h.catalog = (_) => jsonResponse(catalogResponse(revision: 8, landscapes: [lacBrume(rev: 3)]));
    expect(await model.checkPublishedCatalog(), isTrue);
    await settle();
    expect(h.wallpaperPlatform.allowed, isNot(contains(false)));
    // At the next launch, older files go, but not those of the wallpaper.
    final stale = File('${root.path}/content/audio/musiques/retiree.v1.ogg')
      ..createSync(recursive: true)
      ..writeAsStringSync('x');
    model.dispose();
    final again = _Live(root)..wallpaperPlatform.selection = 'lac-brume';
    again.store.files.addAll(h.store.files);
    h = again;
    await h.start(plan: Plan.annual);
    await settle(50);
    expect(stale.existsSync(), isFalse);
    expect(File(set['video']! as String).existsSync(), isTrue);
  });

  test('a published catalog that misses an item of the base is ignored whole', () async {
    final model = await h.start(plan: Plan.annual);
    h.catalog = (_) {
      final json = catalogResponse();
      ((json['catalog'] as Map<String, dynamic>)['paysages'] as List).removeWhere((l) => (l as Map)['id'] == 'pluie-ville');
      return jsonResponse(json);
    };
    expect(await model.checkPublishedCatalog(), isFalse);
    expect(model.catalog.landscape('lac-brume'), isNull);
    expect(model.catalog.landscape('pluie-ville'), isNotNull);
    expect(await h.got(), isEmpty, reason: 'silent');
  });

  test('a schedule keeps its published landscape after an update that keeps it', () async {
    final model = await h.start(plan: Plan.annual);
    await model.startCatalogUpdates();
    final schedule = Schedule(
      id: 's1',
      hour: 22,
      minute: 0,
      days: Schedule.everyDay,
      rampMinutes: 10,
      landscapeId: 'lac-brume',
      reminder: Reminder.dormir,
      active: true,
    );
    expect(await model.saveSchedule(schedule), isTrue);
    h.catalog = (_) => jsonResponse(catalogResponse(revision: 8, landscapes: [lacBrume()..['nom'] = 'Lac brumeux']));
    expect(await model.checkPublishedCatalog(), isTrue);
    await settle();
    expect(model.schedules.single.landscapeId, 'lac-brume');
    expect(h.native.lastPayload['schedules'].single['paysage_nom'], 'Lac brumeux');
  });
}

extension on _Live {
  /// Events delivered so far (broadcast stream: let them arrive first).
  Future<List<AppEvent>> got() async {
    await Future<void>.delayed(Duration.zero);
    return events;
  }
}
