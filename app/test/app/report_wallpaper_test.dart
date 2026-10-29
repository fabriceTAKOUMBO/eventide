// RealAppModel: « Signaler un problème » and « Fond d'écran », on fake platform services.
import 'dart:io';
import 'dart:typed_data';

import 'package:eventide/app/app_controller.dart';
import 'package:eventide/core/landscape_media.dart';
import 'package:eventide/core/plan.dart';
import 'package:eventide/core/problem_report.dart';
import 'package:eventide/core/wallpaper.dart';
import 'package:eventide/services/api_client.dart';
import 'package:eventide/services/audio/fake_audio_engine.dart';
import 'package:eventide/services/audio/playback_handler.dart';
import 'package:eventide/services/content_repository.dart';
import 'package:eventide/services/diagnostics.dart';
import 'package:eventide/services/wallpaper_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../services/device_fakes.dart';
import '../services/fakes.dart';

class _Setup {
  _Setup(this.root);

  final Directory root;
  final share = FakeShare();
  final device = FakeDeviceDiagnostics();
  final platform = FakeWallpaperPlatform();
  late RealAppModel model;

  Future<RealAppModel> start({Plan? plan, bool withExtras = true}) async {
    final catalog = loadTestCatalog();
    final store = MemoryStore();
    final native = FakeNativeBridge();
    final handler = PlaybackHandler(engine: FakeAudioEngine(), focus: FakeFocus(), native: native);
    final client = MockClient((request) async => http.Response('', 500));
    final api = ApiClient(
      baseUrl: '',
      client: client,
      store: store,
      native: native,
      appVersion: '1.0.0',
      deviceSalt: 'salt',
    );
    const media = {'assets/landscapes/cascade-foret.mp4', 'assets/landscapes/cascade-foret.jpg'};
    final content = ContentRepository(
      directory: Directory('${root.path}/content'),
      client: client,
      api: api,
      bundledAssets: () async => {...allBundledAudio(catalog), ...media},
      connectivity: FakeConnectivity(),
      remoteMedia: () async => RemoteLandscapeMedia.none,
    );
    final log = DiagnosticsLog();
    model = RealAppModel(
      catalog: catalog,
      store: store,
      handler: handler,
      content: content,
      native: native,
      api: api,
      connectivity: FakeConnectivity(),
      speech: FakeSpeech(),
      billing: FakeBilling(),
      ads: FakeAds(),
      account: FakeAccount(),
      links: FakeLinks(),
      share: share,
      permissions: FakePermissions(),
      urls: FakeUrlOpener(),
      config: AppConfig(forcedPlan: plan),
      problems: withExtras ? ProblemReports(device: device, log: log, directory: Directory('${root.path}/diag')) : null,
      wallpaper: withExtras
          ? LandscapeWallpaper(
              platform: platform,
              directory: Directory('${root.path}/wallpaper'),
              bundledAssets: () async => media,
              loadAsset: (asset) async => Uint8List.fromList(asset.codeUnits),
            )
          : null,
    );
    await model.init();
    await settle();
    return model;
  }
}

void main() {
  late Directory root;
  late _Setup setup;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('eventide-extras');
    setup = _Setup(root);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  group('Signaler un problème', () {
    test('the last abnormal exit is known after start; the report goes to the share sheet', () async {
      setup.device.pending = [
        AppExit(reason: ExitReason.crashNative, at: DateTime(2026, 10, 29, 22, 14), importance: 100),
        AppExit(reason: ExitReason.lowMemory, at: DateTime(2026, 10, 29, 23), importance: 400),
      ];
      final model = await setup.start();
      expect(model.lastAbnormalExit?.reason, ExitReason.crashNative);
      expect(await model.shareProblemReport(), isTrue);
      final text = setup.share.shared.single;
      expect(text, contains('Eventide — rapport de problème'));
      expect(text, contains('SM-S921B'));
      expect(text, contains('Plantage natif'));
      expect(text, isNot(contains('android-id')), reason: 'no identifier');
    });

    test('data deletion forgets the exits and the log', () async {
      setup.device.pending = [AppExit(reason: ExitReason.anr, at: DateTime(2026, 10, 29), importance: 100)];
      final model = await setup.start();
      await model.deleteAccountData();
      expect(model.lastAbnormalExit, isNull);
      expect(setup.platform.clears, 1);
    });

    test('without the service (tests, previews): nothing to share, nothing offered', () async {
      final model = await setup.start(withExtras: false);
      expect(model.lastAbnormalExit, isNull);
      expect(await model.shareProblemReport(), isFalse);
      expect(model.wallpaperSupport, WallpaperSupport.none);
      expect(await model.setLandscapeWallpaper('cascade-foret'), WallpaperResult.unsupported);
      expect(await model.saveLandscapeVideoToGallery('cascade-foret'), isFalse);
    });
  });

  group('Fond d’écran', () {
    test('a free landscape: its bundled video and poster, then Android\'s preview', () async {
      final model = await setup.start();
      expect(model.wallpaperSupport, const WallpaperSupport(liveWallpaper: true, gallery: true));
      expect(await model.setLandscapeWallpaper('cascade-foret'), WallpaperResult.opened);
      final sent = setup.platform.set.single;
      expect(sent['name'], 'Cascade en forêt');
      expect(sent['video'], endsWith('/wallpaper/cascade-foret.mp4'));
      expect(sent['poster'], endsWith('/wallpaper/cascade-foret.jpg'));
      expect(await model.saveLandscapeVideoToGallery('cascade-foret'), isTrue);
      expect(setup.platform.gallery.single.$2, 'Eventide - Cascade en forêt');
    });

    test('a Premium landscape on the free plan: refused, nothing asked to Android', () async {
      final model = await setup.start(plan: Plan.free);
      expect(await model.setLandscapeWallpaper('pluie-ville'), WallpaperResult.notAllowed);
      expect(await model.saveLandscapeVideoToGallery('pluie-ville'), isFalse);
      expect(setup.platform.set, isEmpty);
      expect(setup.platform.gallery, isEmpty);
    });

    test('the wallpaper follows the plan: a Premium landscape shows its still picture on the free plan', () async {
      setup.platform.selection = 'pluie-ville';
      await setup.start(plan: Plan.free);
      expect(setup.platform.allowed, [false]);
    });

    test('… and its video with Premium', () async {
      setup.platform.selection = 'pluie-ville';
      await setup.start(plan: Plan.annual);
      expect(setup.platform.allowed, [true]);
    });
  });
}
