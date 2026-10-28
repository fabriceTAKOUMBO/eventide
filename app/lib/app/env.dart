// Compile-time configuration (`--dart-define=NAME=value`). See docs/app/architecture.md.
import 'package:flutter/foundation.dart';

import '../core/plan.dart';

class Env {
  const Env._();

  /// Base URL of the API, e.g. `https://api.eventide.app/v1` (no trailing slash needed).
  /// Empty: no backend. The app works locally, voice uses on-device rules only and, in debug
  /// builds only, purchases are acknowledged locally without verification.
  static const String apiBaseUrl = String.fromEnvironment('API_BASE_URL');

  /// Host of the share links (`https://<host>/m/<code>`, `https://<host>/s#<data>`).
  /// Placeholder until the domain is bought; must match `-Peventide.shareHost` for App Links.
  static const String shareHost = String.fromEnvironment('SHARE_HOST', defaultValue: 'eventide.app');

  /// Debug only: base URL of a local static server holding the content tree
  /// (`audio/sons/<id>.ogg`, `audio/musiques/<id>.ogg`), fetched without signature.
  /// Example: `http://10.0.2.2:8080` (Android emulator → host machine).
  static const String _devContentBaseUrl = String.fromEnvironment('DEV_CONTENT_BASE_URL');

  /// Google Cloud project number linked to Play Integrity (optional for apps installed from Play).
  static const String playCloudProjectNumber = String.fromEnvironment('PLAY_CLOUD_PROJECT_NUMBER');

  /// AdMob ad unit ids. Defaults: Google's official test ids (never real ads by accident).
  static const String admobInterstitialOpen = String.fromEnvironment(
    'ADMOB_INTERSTITIAL_OPEN',
    defaultValue: 'ca-app-pub-3940256099942544/1033173712',
  );
  static const String admobInterstitialExit = String.fromEnvironment(
    'ADMOB_INTERSTITIAL_EXIT',
    defaultValue: 'ca-app-pub-3940256099942544/1033173712',
  );

  /// AdMob application id. The Android manifest reads it from the Gradle property
  /// `eventide.admobAppId`; kept here for documentation and checks.
  static const String admobAppId = String.fromEnvironment(
    'ADMOB_APP_ID',
    defaultValue: 'ca-app-pub-3940256099942544~3347511713',
  );

  /// Web client id (server client id) used by Google Sign-In to issue an id token for the API.
  static const String googleServerClientId = String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID');

  /// Debug only: forces a plan (`free`, `monthly`, `annual`, `lifetime`) to test the offers.
  static const String _debugForcePlan = String.fromEnvironment('DEBUG_FORCE_PLAN');

  /// Salt appended to ANDROID_ID before hashing (`device_hash`). Not a secret.
  static const String deviceHashSalt = 'eventide-device-v1';

  static bool get hasBackend => apiBaseUrl.isNotEmpty;

  static String get devContentBaseUrl => kDebugMode ? _devContentBaseUrl : '';

  static Plan? get debugForcePlan {
    if (!kDebugMode || _debugForcePlan.isEmpty) return null;
    for (final plan in Plan.values) {
      if (plan.name == _debugForcePlan) return plan;
    }
    return null;
  }

  /// Purchases may be completed without server verification only in debug builds without backend.
  static bool get localPurchaseAcknowledgement => kDebugMode && !hasBackend;

  static String get appVersion => const String.fromEnvironment('APP_VERSION', defaultValue: '1.0.0');
}
