// Contract between the UI (lib/ui) and the application layer (lib/app, lib/services).
// The UI only depends on this file and on lib/core. RealAppModel (lib/app/app_controller.dart)
// implements it on top of the platform services; tests and previews use a fake.
import 'package:flutter/foundation.dart';

import '../core/catalog.dart';
import '../core/landscape_media.dart';
import '../core/lightning.dart';
import '../core/plan.dart';
import '../core/problem_report.dart' show AppExit;
import '../core/scene.dart';
import '../core/schedule.dart';
import '../core/settings.dart';
import '../core/sleep.dart';
import '../core/wallpaper.dart';

/// A saved selection: landscape and its full mix (dossier, screen 2: "le cœur enregistre la sélection").
class Favorite {
  const Favorite({required this.id, required this.scene, required this.createdAt});

  final String id;
  final Scene scene;
  final DateTime createdAt;

  String get landscapeId => scene.landscapeId;

  Map<String, dynamic> toJson() => {
        'id': id,
        'scene': scene.toJson(),
        'created_at': createdAt.toIso8601String(),
      };

  static Favorite fromJson(Map<String, dynamic> json) => Favorite(
        id: json['id'] as String,
        scene: Scene.fromJson((json['scene'] as Map).cast<String, dynamic>()),
        createdAt: DateTime.parse(json['created_at'] as String),
      );
}

enum PurchaseChoice { annual, monthly, lifetime }

/// A product as Google Play prices it (prices are never hard-coded in the UI when Play answers).
class ProductOffer {
  const ProductOffer({
    required this.choice,
    required this.price,
    required this.available,
    this.hasFreeTrial = false,
  });

  final PurchaseChoice choice;

  /// Localised price from Google Play, e.g. « 59,99 € ». Falls back to the dossier price offline.
  final String price;
  final bool available;
  final bool hasFreeTrial;
}

/// One-shot events the UI reacts to (navigation, toasts).
sealed class AppEvent {
  const AppEvent();
}

class OpenPremiumEvent extends AppEvent {
  const OpenPremiumEvent();
}

/// "Commencer la nuit", by the button or by the setting "Écran noir pendant le minuteur".
class OpenStandbyEvent extends AppEvent {
  const OpenStandbyEvent();
}

class OfflineEvent extends AppEvent {
  const OfflineEvent();
}

class ToastEvent extends AppEvent {
  const ToastEvent(this.message);
  final String message;
}

/// A shared mix was opened from a link and loaded (locked items stay visible but muted for free users).
class SharedMixOpenedEvent extends AppEvent {
  const SharedMixOpenedEvent({required this.lockedItems});
  final int lockedItems;
}

enum PermissionKind { notifications, exactAlarm }

abstract class AppModel extends ChangeNotifier {
  // ---- Static data
  Catalog get catalog;
  ProductRules get rules;

  // ---- Listening state
  /// The scene being played (or ready to play).
  Scene get scene;
  bool get playing;

  /// True while sounds of a new landscape are being prepared or downloaded.
  bool get loadingAudio;

  /// Landscape shown on the home screen. It can differ from [scene] when the user browses
  /// onto a locked landscape: the current sound keeps playing (dossier, screen 2).
  String get browsedLandscapeId;
  bool get browsedLandscapeLocked;

  /// Last landscape seen in each theme, so coming back to a theme restores it.
  String lastLandscapeOfTheme(String themeId);

  DateTime? get timerEndsAt;

  // ---- Data
  List<Schedule> get schedules;

  /// Next scheduled start among active schedules.
  DateTime? get nextScheduledStart;
  List<Favorite> get favorites;
  bool get isCurrentSceneFavorite;
  SleepStats get sleepStats;
  AppSettings get settings;

  // ---- Account and offer
  Entitlements get entitlements;
  Plan get plan => entitlements.plan;
  bool get signedIn;
  List<ProductOffer> get offers;

  // ---- Environment
  /// False only after a real failed attempt (dossier, screen 13).
  bool get online;
  bool get exactAlarmAllowed;

  // ---- Events
  Stream<AppEvent> get events;

  // ---- Onboarding
  bool get onboarded;
  Future<void> completeOnboarding();

  // ---- Playback
  Future<void> play();
  Future<void> pause();
  Future<void> togglePlay();
  void setTimer(TimerSetting timer);

  /// Home swipes and arrows. Updates the image at once; the sound follows after ~1.5 s
  /// without further browsing, and only if the landscape is allowed.
  void browseLandscape(String landscapeId);

  /// Explicit choice from the Landscapes grid (loads its default mix). Locked → OpenPremiumEvent.
  void selectLandscape(String landscapeId);
  void setMoment(Moment moment);

  /// Adds, changes or removes (level 0) a layer. Locked item → OpenPremiumEvent;
  /// too many audio layers → ToastEvent. A level above 0 in a muted category unmutes it
  /// (moving a slider of a muted category makes it heard again).
  void setLayerLevel(LayerKind kind, String id, int level);

  // ---- Mute (`sourdine`): a whole category silenced, every layer and its level kept

  /// Whether [kind] (sounds or music) is muted. The decor has no mute.
  bool categoryMuted(LayerKind kind) => scene.isMuted(kind);
  bool get soundsMuted => categoryMuted(LayerKind.son);
  bool get musicMuted => categoryMuted(LayerKind.musique);

  /// Mutes or unmutes sounds or music (fade of about 1 s), keeping every layer and its level,
  /// so unmuting restores the exact mix. Saved with the scene. Ignored for the decor.
  /// Concrete no-op default so that fakes and previews need not implement it.
  void setCategoryMuted(LayerKind kind, bool muted) {}

  // ---- Favorites
  /// Adds or removes the current selection. At the free limit → OpenPremiumEvent.
  Future<void> toggleFavorite();
  void applyFavorite(Favorite favorite);
  void removeFavorite(String favoriteId);

  // ---- Schedules
  Schedule newScheduleDraft();

  /// Returns false and emits OpenPremiumEvent when the free limit is reached.
  Future<bool> saveSchedule(Schedule schedule);
  Future<void> setScheduleActive(String scheduleId, bool active);
  Future<void> deleteSchedule(String scheduleId);

  // ---- Permissions (always explained by the UI before asking)
  bool permissionGranted(PermissionKind kind);
  Future<bool> requestPermission(PermissionKind kind);

  /// Refused with « Ne plus demander » (or refused twice): asking again would show nothing,
  /// only Android's app settings can grant it now (the UI then offers [openAppSettings]).
  /// Always false for [PermissionKind.exactAlarm], whose request opens a settings screen.
  bool permissionPermanentlyDenied(PermissionKind kind);

  // ---- One-time hints (persisted on the phone: shown once per install)
  bool hintSeen(String id);

  /// Records that the hint [id] was shown. Does not notify listeners (safe during a build).
  Future<void> markHintSeen(String id);

  // ---- Sleep
  Future<void> setSleepTracking(bool enabled);

  /// Starts a night (and the timer's black screen); emits OpenStandbyEvent.
  Future<void> startNight();

  /// Called when the user wakes the standby screen.
  Future<void> leaveStandby();

  // ---- Settings
  Future<void> updateSettings(AppSettings settings);

  // ---- Sharing
  /// Link that recreates the current mix (no schedule, no personal data).
  Future<Uri> createShareLink();

  /// Opens the Android share sheet.
  Future<void> shareMix();

  /// Copies the link to the clipboard.
  Future<void> copyShareLink();

  // ---- Purchases
  Future<void> buy(PurchaseChoice choice);
  Future<void> restorePurchases();

  // ---- Account and data
  Future<void> signInWithGoogle();
  Future<bool> retryConnection();
  Future<String> exportData();
  Future<void> deleteAccountData();

  // ---- Optional hooks (concrete defaults: fakes and previews need not implement them)

  /// Back pressed on the home screen, just before the app closes: the free plan may show its
  /// exit interstitial here (never during playback). Completes when the app may close.
  Future<void> beforeExit() async {}

  /// Opens Android's app settings, from which the user reaches battery optimisation
  /// (guide against vendor background killers, screen 9).
  Future<void> openBatteryGuide() async {}

  /// Google's ad privacy options form (« Choix publicitaires »), free plan only.
  Future<void> openAdPrivacyOptions() async {}

  /// This app's page in Android settings, to grant a permanently denied permission.
  Future<void> openAppSettings() async {}

  /// Google Play's subscriptions page for Eventide (change or cancel the plan).
  Future<void> openManageSubscription() async {}

  /// The full privacy policy online (`https://<SHARE_HOST>/confidentialite`).
  Future<void> openPrivacyPolicy() async {}

  /// Demo build (« Full Relax Démo »): Premium is forced on the phone, nothing can be bought.
  bool get demoMode => false;

  // ---- Living landscapes (looping videos and their posters, docs/app/architecture.md § 14)

  /// Looping video of a landscape when one can be shown now: bundled (free landscapes, and
  /// every landscape of the demo build) or downloaded once and kept (Premium,
  /// `videos/paysages/<id>.mp4`, « Wi-Fi seulement » respected). Null: the still picture stays.
  /// Never downloads anything for a landscape the plan cannot use. Independent of the sound:
  /// playing or pausing the sound never changes the video.
  Future<LandscapeVideoSource?> landscapeVideo(String landscapeId) async => null;

  /// Downloaded poster of a Premium landscape (local file path), or null. Bundled posters
  /// (`assets/landscapes/<id>.jpg`) are found by the UI from the asset manifest.
  String? landscapePosterFile(String landscapeId) => null;

  // ---- Problem report (docs/app/architecture.md « Rapport de problème »)

  /// Last abnormal end of the app recorded by Android (crash, ANR, or killed while in use:
  /// on screen, playing, or as the live wallpaper), or null. Known shortly after start.
  AppExit? get lastAbnormalExit => null;

  /// Opens the share sheet with the plain-text report (app and Android versions, phone model,
  /// exits recorded by Android, recent log of the app; no personal data). False when nothing
  /// could be shared.
  Future<bool> shareProblemReport() async => false;

  // ---- Landscape as wallpaper (docs/app/architecture.md « Fond d'écran vidéo »)

  /// What this phone offers (live wallpaper). Nothing by default.
  WallpaperSupport get wallpaperSupport => WallpaperSupport.none;

  /// Makes [landscapeId] the live wallpaper: its looping video (or its still picture), muted,
  /// paused when not visible. Opens Android's preview, where the user confirms. Only for a
  /// landscape the plan can use ([WallpaperResult.notAllowed] otherwise).
  Future<WallpaperResult> setLandscapeWallpaper(String landscapeId) async => WallpaperResult.unsupported;

  // ---- Storm (contract § 11)

  /// A lightning flash announced just before each thunder of the mix: a filmed storm (`eclairs`) shows
  /// it when the landscape is visible, the thunder follows [LightningStrike.thunderDelay] later.
  /// Concrete default (no thunder) so that fakes and previews need not implement it.
  Stream<LightningStrike> get lightningStrikes => const Stream.empty();
}
