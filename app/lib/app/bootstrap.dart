// Builds the real services and the RealAppModel. Order matters for scheduled starts: the audio
// handler is registered with audio_service first, so that a MEDIA_PLAY event queued by the
// alarm receiver (headless engine start) reaches it as soon as possible; the handler then
// publishes its loading state at once (foreground-service deadline) and waits for the model.
import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../core/catalog.dart';
import '../services/account_service.dart';
import '../services/ads_service.dart';
import '../services/api_client.dart';
import '../services/audio/audio_focus.dart';
import '../services/audio/playback_handler.dart';
import '../services/audio/soloud_audio_engine.dart';
import '../services/billing_service.dart';
import '../services/connectivity.dart';
import '../services/content_repository.dart';
import '../services/links_service.dart';
import '../services/native_bridge.dart';
import '../services/permissions_service.dart';
import '../services/storage.dart';
import '../services/voice/speech_recognizer.dart';
import 'app_controller.dart';
import 'env.dart';

/// Registers the handler with audio_service (media notification, background playback).
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
        androidNotificationChannelId: 'be.cinaf.eventide.playback',
        androidNotificationChannelName: 'Lecture',
        androidNotificationChannelDescription: 'Commandes de lecture des sons',
        androidNotificationIcon: 'drawable/ic_notification',
        androidStopForegroundOnPause: true,
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
    return manifest.listAssets().where((k) => k.startsWith('assets/audio/')).toSet();
  } catch (_) {
    return const {};
  }
}

Future<RealAppModel> createAppModel({required PlaybackHandler handler, required NativeBridge native}) async {
  final catalog = await loadCatalog();
  final support = await getApplicationSupportDirectory();
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
    bundledAssets: _bundledAssets,
    connectivity: connectivity,
    devBaseUrl: Env.devContentBaseUrl,
  );
  late final RealAppModel model;
  final billing = PlayBilling(
    api: api,
    localAcknowledgement: Env.localPurchaseAcknowledgement,
    currentEntitlements: () => model.entitlements,
  );
  model = RealAppModel(
    catalog: catalog,
    store: store,
    handler: handler,
    content: content,
    native: native,
    api: api,
    connectivity: connectivity,
    speech: SpeechToTextRecognizer(),
    billing: billing,
    ads: AdMobAdsService(openUnitId: Env.admobInterstitialOpen, exitUnitId: Env.admobInterstitialExit),
    account: GoogleAccountAuth(serverClientId: Env.googleServerClientId),
    links: AppLinksSource(),
    share: PlatformShareSheet(),
    permissions: PlatformPermissions(native),
    urls: PlatformUrlOpener(),
    config: AppConfig(shareHost: Env.shareHost, forcedPlan: Env.debugForcePlan),
  );
  await model.init();
  return model;
}
