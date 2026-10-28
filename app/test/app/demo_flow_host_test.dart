// Host twin of integration_test/demo_flow_test.dart: the same demo flow (integration_test/
// demo_flow.dart) on the real RealAppModel and UI, wired like bootstrap.dart wires the demo
// build, with fake platform services. It proves every step of the on-device test without a
// device; the device run adds the real plugins, R8-free debug build and Android itself.
import 'dart:io';

import 'package:eventide/app/app_controller.dart';
import 'package:eventide/app/app_model.dart';
import 'package:eventide/services/ads_service.dart';
import 'package:eventide/services/api_client.dart';
import 'package:eventide/services/audio/fake_audio_engine.dart';
import 'package:eventide/services/audio/playback_handler.dart';
import 'package:eventide/services/billing_service.dart';
import 'package:eventide/services/content_repository.dart';
import 'package:eventide/ui/app.dart';
import 'package:eventide/ui/landscape/landscape_image.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../../integration_test/demo_flow.dart';
import '../services/fakes.dart' hide settle;
import '../ui/ui_test_utils.dart';

void main() {
  setUpAll(loadAppFonts);

  testWidgets('demo flow: Premium unlocked locally, no purchase, schedule armed without network', (tester) async {
    usePhoneView(tester); // reduced motion, like the device run
    final catalog = loadTestCatalog();
    final store = MemoryStore();
    final engine = FakeAudioEngine();
    final native = FakeNativeBridge()..demoBuild = true;
    final permissions = FakePermissions()..granted[PermissionKind.notifications] = false;
    final connectivity = FakeConnectivity(online: false); // Premium plays offline
    final handler = PlaybackHandler(engine: engine, focus: FakeFocus(), native: native);
    final client = MockClient((request) async => http.Response('', 500));
    final api = ApiClient(
      baseUrl: '',
      client: client,
      store: store,
      native: native,
      appVersion: '1.0.0',
      deviceSalt: 'salt',
    );
    final billing = DemoBilling();
    final model = RealAppModel(
      catalog: catalog,
      store: store,
      handler: handler,
      content: ContentRepository(
        directory: Directory('/nonexistent/eventide-content'),
        client: client,
        api: api,
        bundledAssets: () async => allBundledAudio(catalog),
        connectivity: connectivity,
      ),
      native: native,
      api: api,
      connectivity: connectivity,
      speech: FakeSpeech(),
      billing: billing,
      ads: const NoAdsService(),
      account: FakeAccount(),
      links: FakeLinks(),
      share: FakeShare(),
      permissions: permissions,
      urls: FakeUrlOpener(),
      config: const AppConfig(demo: true),
    );
    await model.init();
    model.handleLifecycle(AppLifecycleState.resumed);
    await tester.pumpWidget(EventideApp(model: model));
    await tester.runAsync(LandscapeImages.discoverAssets);
    await settle(tester);

    final lines = <String>[];
    final result = await runDemoFlow(tester, model, stopPlayback: handler.stop, report: lines.add);

    expect(result.audioPlayed, isTrue);
    expect(lines, containsAllInOrder(['demo_mode=on plan=annual', 'audio=playing', 'premium_sound=vagues']));
    expect(lines.last, 'flow=ok');
    // The Premium landscape and sound came from bundled assets: no download was attempted.
    expect(engine.calls, contains('start'));
    // Nothing was bought, restored or shown: the demo never calls Google Play or AdMob.
    expect(billing.calls, isEmpty);
    // The schedule is armed natively, without the free-plan network requirement.
    final payload = native.lastPayload;
    expect(payload['requires_network'], isFalse);
    final synced = (payload['schedules'] as List).single as Map;
    expect(synced['id'], result.schedule.id);
    expect(synced['paysage'], 'torrent-montagne');
    expect(synced['paysage_nom'], 'Torrent de montagne');
    expect(handler.status.value.playing || handler.status.value.paused, isFalse);
    expect(catalog.landscape('torrent-montagne')!.free, isFalse);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
  });
}
