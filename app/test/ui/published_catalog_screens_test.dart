// The published catalog on screen (contract § 13): the real RealAppModel and UI, a fake backend.
// A newer catalog adds its landscape to the theme page and its melody to « Mon mix » while the
// Paysages sheet is open, and the sound keeps playing.
import 'dart:convert';
import 'dart:io';

import 'package:eventide/app/app_controller.dart';
import 'package:eventide/core/catalog.dart';
import 'package:eventide/core/landscape_media.dart';
import 'package:eventide/core/plan.dart';
import 'package:eventide/services/api_client.dart';
import 'package:eventide/services/audio/fake_audio_engine.dart';
import 'package:eventide/services/audio/playback_handler.dart';
import 'package:eventide/services/catalog_updates.dart';
import 'package:eventide/services/content_repository.dart';
import 'package:eventide/services/storage.dart';
import 'package:eventide/ui/app.dart';
import 'package:eventide/ui/navigation.dart';
import 'package:eventide/ui/screens/landscapes_sheet.dart';
import 'package:eventide/ui/screens/mix_sheet.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../services/fakes.dart' hide settle;
import '../services/published_fixtures.dart';
import 'app_harness.dart' show navigatorOf, openRoute, settle;
import 'ui_test_utils.dart';

void main() {
  testWidgets('a newer catalog appears in the open theme page and in « Mon mix », the sound goes on', (
    tester,
  ) async {
    usePhoneView(tester);
    final base = loadTestCatalog();
    final store = MemoryStore()..files[StoreKeys.installation] = jsonEncode({'version': 1, 'data': {'token': 't'}});
    final engine = FakeAudioEngine();
    final native = FakeNativeBridge();
    final connectivity = FakeConnectivity();
    final handler = PlaybackHandler(engine: engine, focus: FakeFocus(), native: native);
    final catalogRequests = <http.Request>[];
    var answer = catalogResponse(revision: 0, landscapes: [], sounds: [], music: []);
    final client = MockClient((request) async {
      if (request.url.path == '/v1/catalog') {
        catalogRequests.add(request);
        return jsonResponse(answer);
      }
      return jsonResponse({'error': 'not_found'}, 404);
    });
    final api = ApiClient(
      baseUrl: 'https://api.test/v1',
      client: client,
      store: store,
      native: native,
      appVersion: '1.0.0',
      deviceSalt: 'salt',
    );
    const media = {'assets/landscapes/cascade-foret.jpg', 'assets/landscapes/cascade-foret.mp4'};
    final assets = {...allBundledAudio(base), ...media};
    final updates = CatalogUpdates(
      api: api,
      store: store,
      base: base,
      bundledRemote: RemoteLandscapeMedia.fromJson(bundledRemoteJson()),
      bundledAssets: () async => assets,
      log: (_) {},
    );
    final shown = await updates.load();
    final model = RealAppModel(
      catalog: shown.catalog,
      store: store,
      handler: handler,
      content: ContentRepository(
        directory: Directory('/nonexistent/eventide-content'),
        client: client,
        api: api,
        bundledAssets: () async => assets,
        connectivity: connectivity,
        remoteMedia: () async => shown.remote,
      ),
      native: native,
      api: api,
      connectivity: connectivity,
      billing: FakeBilling(),
      ads: FakeAds(),
      account: FakeAccount(),
      links: FakeLinks(),
      share: FakeShare(),
      permissions: FakePermissions(),
      urls: FakeUrlOpener(),
      config: const AppConfig(forcedPlan: Plan.free),
      catalogUpdates: updates,
    );
    await model.init();
    model.handleLifecycle(AppLifecycleState.resumed);
    await model.completeOnboarding();
    await model.markHintSeen('home_swipe');
    await tester.pumpWidget(EventideApp(model: model));
    await settle(tester);
    // First screen drawn: the first answer (nothing published yet).
    await model.startCatalogUpdates();
    expect(catalogRequests, hasLength(1));

    await model.play();
    await settle(tester);
    expect(model.playing, isTrue);
    final calls = [...engine.calls];
    final keys = {...engine.activeKeys};

    await openRoute(tester, Routes.landscapes, (_) => const LandscapesSheet());
    Finder inSheet(String text) =>
        find.descendant(of: find.byType(LandscapesSheet), matching: find.text(text));
    expect(inSheet('Cascade en forêt'), findsOneWidget);
    expect(inSheet('Lac de brume'), findsNothing);

    // Published from the dashboard: on the next check, without a restart.
    answer = catalogResponse(revision: 1);
    expect(await model.checkPublishedCatalog(), isTrue);
    await settle(tester);
    expect(inSheet('Lac de brume'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Lac de brume, Premium')), findsOneWidget);
    expect(model.playing, isTrue);
    expect(engine.calls, calls);
    expect(engine.activeKeys, keys);

    // Withdrawn again: it leaves the open page, the sound still goes on.
    answer = catalogResponse(revision: 2, landscapes: [], sounds: [], music: []);
    expect(await model.checkPublishedCatalog(), isTrue);
    await settle(tester);
    expect(inSheet('Lac de brume'), findsNothing);
    expect(model.playing, isTrue);
    expect(engine.calls, calls);

    // The chosen tab stays when a theme disappears meanwhile (the media of its only landscape
    // left the content server): the tabs are kept by theme, not by position.
    await tester.ensureVisible(inSheet('Favoris'));
    await tester.tap(inSheet('Favoris'));
    await settle(tester);
    expect(find.text('Aucun favori'), findsOneWidget);
    expect(inSheet('Urbain'), findsOneWidget);
    final noCity = catalogResponse(revision: 3, landscapes: [], sounds: [], music: []);
    for (final list in ['videos', 'images']) {
      ((noCity['distant'] as Map<String, dynamic>)[list] as List).remove('pluie-ville');
    }
    answer = noCity;
    expect(await model.checkPublishedCatalog(), isTrue);
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(inSheet('Urbain'), findsNothing);
    expect(find.text('Aucun favori'), findsOneWidget);

    // Published again, with its melody: « Mon mix » offers it, the ambiance only with its landscape.
    answer = catalogResponse(revision: 4);
    expect(await model.checkPublishedCatalog(), isTrue);
    navigatorOf(tester).pop();
    await settle(tester);
    Finder mixList() => find.descendant(of: find.byType(MixSheet), matching: find.byType(Scrollable)).first;
    await openRoute(tester, Routes.mix, (_) => const MixSheet(initialKind: LayerKind.musique));
    await tester.scrollUntilVisible(find.text('Harpe céleste'), 200, scrollable: mixList());
    expect(find.text('Harpe céleste'), findsOneWidget);
    navigatorOf(tester).pop();
    await settle(tester);
    await openRoute(tester, Routes.mix, (_) => const MixSheet());
    // The end of « Ajouter un son »: the last sound offered with cascade-foret, never the ambiance
    // of the published landscape.
    final last = base.item(LayerKind.son, 'chouette')!.name;
    await tester.scrollUntilVisible(find.text(last), 200, scrollable: mixList());
    await tester.fling(mixList(), const Offset(0, -2000), 3000);
    await settle(tester);
    expect(find.text(last), findsOneWidget);
    expect(find.text('Ambiance du lac'), findsNothing);

    await handler.stop();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
  });
}
