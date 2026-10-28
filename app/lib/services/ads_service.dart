// AdMob for the free plan: Google's consent form (UMP, required in Europe) before any ad request,
// interstitials at opening and at exit only, never during playback, frequency-capped, general
// audience content only. Nothing at all for Premium (the controller never calls this then).
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

enum AdPlacement { open, exit }

/// Pure placement rules, kept out of the plugin code so they can be tested.
class AdPolicy {
  const AdPolicy({this.cap = const Duration(hours: 4)});

  /// At most one interstitial per placement in this window.
  final Duration cap;

  bool canShow({
    required bool showsAds,
    required bool playing,
    required DateTime? lastShown,
    required DateTime now,
  }) {
    if (!showsAds || playing) return false;
    return lastShown == null || now.difference(lastShown) >= cap;
  }
}

abstract class AdsService {
  /// Gathers consent (shows Google's form when required) and initializes the SDK if ads may be
  /// requested. Safe to call several times.
  Future<bool> initialize();

  /// Shows an interstitial if one is ready (waits briefly for the first load). True if shown.
  Future<bool> show(AdPlacement placement);

  /// « Gérer mes choix publicitaires » (privacy options form), when required in the region.
  Future<void> showPrivacyOptions();
}

class AdMobAdsService implements AdsService {
  AdMobAdsService({required this.openUnitId, required this.exitUnitId});

  final String openUnitId;
  final String exitUnitId;

  Future<bool>? _init;
  bool _canRequest = false;
  final Map<AdPlacement, InterstitialAd?> _loaded = {};
  final Map<AdPlacement, Completer<void>?> _loading = {};

  @override
  Future<bool> initialize() => _init ??= _initialize();

  Future<bool> _initialize() async {
    try {
      final updated = Completer<void>();
      ConsentInformation.instance.requestConsentInfoUpdate(
        ConsentRequestParameters(),
        () async {
          await ConsentForm.loadAndShowConsentFormIfRequired((FormError? error) {
            if (error != null) debugPrint('Ads: consent form error ${error.message}');
          });
          if (!updated.isCompleted) updated.complete();
        },
        (FormError error) {
          debugPrint('Ads: consent update failed ${error.message}');
          if (!updated.isCompleted) updated.complete();
        },
      );
      await updated.future.timeout(const Duration(seconds: 30), onTimeout: () {});
      _canRequest = await ConsentInformation.instance.canRequestAds();
      if (!_canRequest) return false;
      await MobileAds.instance.updateRequestConfiguration(
        RequestConfiguration(maxAdContentRating: MaxAdContentRating.g),
      );
      await MobileAds.instance.initialize();
      _load(AdPlacement.open);
      _load(AdPlacement.exit);
      return true;
    } catch (e) {
      debugPrint('Ads: init failed ($e)');
      _init = null;
      return false;
    }
  }

  void _load(AdPlacement placement) {
    if (!_canRequest || _loaded[placement] != null || _loading[placement] != null) return;
    final done = Completer<void>();
    _loading[placement] = done;
    InterstitialAd.load(
      adUnitId: placement == AdPlacement.open ? openUnitId : exitUnitId,
      request: const AdRequest(),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (InterstitialAd ad) {
          _loaded[placement] = ad;
          _loading[placement] = null;
          done.complete();
        },
        onAdFailedToLoad: (LoadAdError error) {
          debugPrint('Ads: load failed ${error.message}');
          _loading[placement] = null;
          done.complete();
        },
      ),
    );
  }

  @override
  Future<bool> show(AdPlacement placement) async {
    if (!await initialize()) return false;
    _load(placement);
    final loading = _loading[placement];
    if (loading != null) {
      await loading.future.timeout(const Duration(seconds: 4), onTimeout: () {});
    }
    final ad = _loaded.remove(placement);
    if (ad == null) return false;
    final closed = Completer<void>();
    ad.fullScreenContentCallback = FullScreenContentCallback<InterstitialAd>(
      onAdDismissedFullScreenContent: (InterstitialAd ad) {
        ad.dispose();
        if (!closed.isCompleted) closed.complete();
      },
      onAdFailedToShowFullScreenContent: (InterstitialAd ad, AdError error) {
        ad.dispose();
        if (!closed.isCompleted) closed.complete();
      },
    );
    await ad.show();
    await closed.future.timeout(const Duration(minutes: 2), onTimeout: () {});
    _load(placement);
    return true;
  }

  @override
  Future<void> showPrivacyOptions() async {
    try {
      await ConsentForm.showPrivacyOptionsForm((FormError? error) {});
    } catch (e) {
      debugPrint('Ads: privacy options failed ($e)');
    }
  }
}

/// Used for Premium-only builds, tests, and platforms without AdMob.
class NoAdsService implements AdsService {
  const NoAdsService();

  @override
  Future<bool> initialize() async => false;

  @override
  Future<bool> show(AdPlacement placement) async => false;

  @override
  Future<void> showPrivacyOptions() async {}
}
