// Builds the real services and the RealAppModel. Order matters for scheduled starts: the audio
// handler is registered with audio_service first, so that a MEDIA_PLAY event queued by the
// alarm receiver (headless engine start) reaches it as soon as possible; the handler then
// publishes its loading state at once (foreground-service deadline) and waits for the model.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener, AppLifecycleState, WidgetsBinding, WidgetsFlutterBinding;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../core/catalog.dart';
import '../core/crash_guard.dart';
import '../core/landscape_media.dart';
import '../services/account_service.dart';
import '../services/ads_service.dart';
import '../services/api_client.dart';
import '../services/audio/audio_focus.dart';
import '../services/audio/media_artwork.dart';
import '../services/audio/playback_handler.dart';
import '../services/audio/soloud_audio_engine.dart';
import '../services/billing_service.dart';
import '../services/connectivity.dart';
import '../services/content_repository.dart';
import '../services/diagnostics.dart';
import '../services/links_service.dart';
import '../services/native_bridge.dart';
import '../services/permissions_service.dart';
import '../services/storage.dart';
import '../services/wallpaper_service.dart';

import '../ui/landscape/imaginaire_view.dart' show Imaginaire, kImaginaireRuntimeVersion;
import '../ui/landscape/landscape_video.dart' show LandscapeVideos;
import 'app_controller.dart';
import 'demo_mode.dart';
import 'env.dart';

/// Registers the handler with audio_service (media notification, background playback).
///
/// The media card (docs/app/architecture.md « Carte de lecture »): the foreground service runs
/// while the sound plays, so the card cannot be swiped away then; on pause the service leaves
/// the foreground (androidStopForegroundOnPause) and the card can be dismissed, which stops the
/// session (PlaybackHandler.onNotificationDeleted). Lock screen visibility is public (set by
/// audio_service on its MediaStyle notification, which carries the session token).
Future<PlaybackHandler> initPlayback(NativeBridge native) async {
  PlaybackHandler build() => PlaybackHandler(
        engine: SoLoudAudioEngine(),
        focus: AudioSessionFocus(),
        native: native,
      );
  try {
    return await AudioService.init<PlaybackHandler>(
      builder: build,
      config: const AudioServiceConfig(
        // Same channel id as before: Android keeps the channel (and the user's choices for it)
        // created by an earlier version, with its earlier name.
        androidNotificationChannelId: 'be.cinaf.eventide.playback',
        androidNotificationChannelName: 'Lecture',
        androidNotificationChannelDescription:
            'Carte de lecture sur l’écran verrouillé et dans les notifications : paysage, '
            'minuteur et commandes du son',
        androidNotificationIcon: 'drawable/ic_notification',
        // Opaque accent: some Android 12 and older devices draw the progress bar badly without.
        notificationColor: Color(0xFF2A3A2C),
        androidStopForegroundOnPause: true,
        androidNotificationOngoing: false,
        androidNotificationClickStartsActivity: true,
        androidShowNotificationBadge: false,
      ),
    );
  } catch (e) {
    // Never block the app on the media service (tests, unsupported platform): foreground only.
    debugPrint('bootstrap: AudioService.init failed ($e)');
    return build();
  }
}

Future<Catalog> loadCatalog() async =>
    Catalog.fromJson(jsonDecode(await rootBundle.loadString('assets/catalog.json')) as Map<String, dynamic>);

Future<Set<String>> _bundledAssets() async {
  try {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    return manifest
        .listAssets()
        .where((k) =>
            k.startsWith('assets/audio/') || k.startsWith('assets/landscapes/') || k == _sceneRuntime)
        .toSet();
  } catch (_) {
    return const {};
  }
}

/// Entry page of the 3D scenes' runtime (contract § 12).
const String _sceneRuntime = 'assets/imaginaire/index.html';

/// The catalog without the landscapes this phone can never show (contract § 12): a filmed
/// landscape needs its video or its poster, bundled or on the content server (`remote.json`);
/// a 3D scene needs the bundled runtime or its poster. In production, the landscapes made
/// from test material (demo build only) are left out, and a theme left empty is hidden.
Future<Catalog> _showableCatalog(Catalog catalog, Future<Set<String>> bundled) async {
  final assets = await bundled;
  final remote = await _remoteLandscapeMedia();
  final runtime = assets.contains(_sceneRuntime);
  return catalog.showing((l) {
    final media = assets.contains(LandscapeMediaKeys.bundledVideo(l.id)) ||
        assets.contains(LandscapeMediaKeys.bundledImage(l.id)) ||
        remote.videos.contains(l.id) ||
        remote.images.contains(l.id);
    return media || (l.is3d && runtime);
  });
}

/// Which Premium landscapes have a video or a poster on the content server (generated file).
Future<RemoteLandscapeMedia> _remoteLandscapeMedia() async {
  try {
    return RemoteLandscapeMedia.fromJson(jsonDecode(await rootBundle.loadString(LandscapeMediaKeys.remoteManifest)));
  } catch (_) {
    return RemoteLandscapeMedia.none;
  }
}

/// Everything main() does before runApp(); the integration test (integration_test/) calls it too,
/// so that it drives exactly the app the user gets.
Future<({PlaybackHandler handler, RealAppModel model})> startEventide() async {
  WidgetsFlutterBinding.ensureInitialized();
  final native = MethodChannelNativeBridge();
  // First: a scheduled start may have booted this engine without any activity.
  final handler = await initPlayback(native);
  // Lock screen card: tapping it must open the app. Our own launch intent goes on the media
  // session now, before it is first activated (docs/app/architecture.md § 15.3).
  unawaited(MethodChannelDeviceDiagnostics().installMediaSessionActivity());
  final model = await createAppModel(handler: handler, native: native);
  final crumbs = _watchSession(handler, model);
  AppLifecycleListener(onStateChange: (state) {
    model.handleLifecycle(state);
    crumbs.lifecycle(state);
    // Crash guard: reaching the background normally ends the start (§ 19).
    if (state == AppLifecycleState.hidden || state == AppLifecycleState.paused) {
      CrashGuard.current.markStable();
    }
  });
  final initial = WidgetsBinding.instance.lifecycleState;
  if (initial != null) model.handleLifecycle(initial);
  return (handler: handler, model: model);
}

/// Breadcrumbs of the problem report: sound state, landscape, memory every 5 minutes.
SessionBreadcrumbs _watchSession(PlaybackHandler handler, RealAppModel model) {
  LandscapeVideos.log = Breadcrumbs.add;
  Imaginaire.log = Breadcrumbs.add;
  final crumbs = SessionBreadcrumbs(log: Breadcrumbs.log, liveVideos: () => LandscapeVideos.hub.liveCount)
    ..start();
  void onStatus() {
    final s = handler.status.value;
    crumbs.playback(s.loading ? 'chargement' : (s.playing ? 'lecture' : (s.paused ? 'pause' : 'arrêt')));
  }

  handler.status.addListener(onStatus);
  model.addListener(() => crumbs.landscape(model.scene.landscapeId));
  crumbs.landscape(model.scene.landscapeId);
  return crumbs;
}

Future<RealAppModel> createAppModel({required PlaybackHandler handler, required NativeBridge native}) async {
  // Demo build only when both the dart-define and the Android demo package say so (the native
  // flag is asked for only when the define is set).
  final demo = DemoMode.resolve(
    requested: Env.demoModeRequested,
    nativeDemoBuild: Env.demoModeRequested && await native.isDemoBuild(),
  );
  if (Env.demoModeRequested) debugPrint('Eventide: demo mode ${demo ? 'on' : 'off (not the demo package)'}');
  final bundled = _bundledAssets();
  final catalog = await _showableCatalog(await loadCatalog(), bundled);
  final support = await getApplicationSupportDirectory();
  // Problem report: the log file survives a crash; the exits recorded by Android are read once.
  unawaited(Breadcrumbs.log.attach(Directory('${support.path}/diagnostics')));
  Breadcrumbs.add('démarrage : Eventide ${Env.appVersion}${demo ? ' (version démo)' : ''}');
  // Crash guard (docs/app/architecture.md § 19): what the previous run left decides a safe start
  // and which 3D scenes are shown as their poster. Its breadcrumbs are written before returning:
  // they must be on the phone if a native crash follows.
  final guard = CrashGuard(
    store: FileGuardStore(File('${support.path}/diagnostics/guard.json')),
    build: '${Env.appVersion}+s$kImaginaireRuntimeVersion',
    log: Breadcrumbs.log.addDurable,
  )..load();
  CrashGuard.current = guard;
  final problems = ProblemReports(
    device: MethodChannelDeviceDiagnostics(),
    log: Breadcrumbs.log,
    directory: Directory('${support.path}/diagnostics'),
  );
  final store = LocalStore(Directory('${support.path}/eventide'));
  final client = http.Client();
  final api = ApiClient(
    baseUrl: Env.apiBaseUrl,
    client: client,
    store: store,
    native: native,
    appVersion: Env.appVersion,
    deviceSalt: Env.deviceHashSalt,
    cloudProjectNumber: Env.playCloudProjectNumber,
  );
  final connectivity = HttpConnectivityChecker(client: client, apiBaseUrl: Env.apiBaseUrl, native: native);
  final content = ContentRepository(
    directory: Directory('${support.path}/content'),
    client: client,
    api: api,
    bundledAssets: () => bundled,
    connectivity: connectivity,
    devBaseUrl: Env.devContentBaseUrl,
    remoteMedia: _remoteLandscapeMedia,
  );
  // Pictures of the media card, kept in the app's cache folder (made again if Android empties it).
  final cache = await getTemporaryDirectory();
  final artwork = MediaArtwork(
    files: IoArtworkFiles(Directory('${cache.path}/media_art')),
    bundledAssets: () => bundled,
    loadAsset: (asset) async {
      final data = await rootBundle.load(asset);
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    },
    downloadedPoster: (id) => content.cachedPath(LandscapeMediaKeys.image(id)),
  );
  // Live wallpaper of the landscape videos (files the wallpaper process reads).
  final wallpaper = LandscapeWallpaper(
    platform: MethodChannelWallpaperPlatform(),
    directory: Directory('${support.path}/wallpaper'),
    bundledAssets: () => bundled,
    loadAsset: (asset) async {
      final data = await rootBundle.load(asset);
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    },
  );

  final Billing billing = demo
      ? DemoBilling()
      : PlayBilling(api: api, localAcknowledgement: Env.localPurchaseAcknowledgement);
  final model = RealAppModel(
    catalog: catalog,
    store: store,
    handler: handler,
    content: content,
    native: native,
    api: api,
    connectivity: connectivity,
    billing: billing,
    ads: demo
        ? const NoAdsService()
        : AdMobAdsService(openUnitId: Env.admobInterstitialOpen, exitUnitId: Env.admobInterstitialExit),
    account: GoogleAccountAuth(serverClientId: Env.googleServerClientId),
    links: AppLinksSource(),
    share: PlatformShareSheet(),
    permissions: PlatformPermissions(native),
    urls: PlatformUrlOpener(),
    config: AppConfig(
      shareHost: Env.shareHost,
      forcedPlan: Env.debugForcePlan,
      demo: demo,
      safeStart: guard.safeStart,
    ),
    artwork: artwork,
    problems: problems,
    wallpaper: wallpaper,
  );
  await model.init();
  return model;
}
