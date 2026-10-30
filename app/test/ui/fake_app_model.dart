// In-memory AppModel for widget tests and screenshot previews. Behaves like the real
// controller for everything the UI can observe, and records every action in [calls].
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:eventide/app/app_model.dart';
import 'package:eventide/core/catalog.dart';
import 'package:eventide/core/landscape_media.dart';
import 'package:eventide/core/plan.dart';
import 'package:eventide/core/scene.dart';
import 'package:eventide/core/schedule.dart';
import 'package:eventide/core/settings.dart';
import 'package:eventide/core/sleep.dart';

Catalog loadTestCatalog() {
  final json = jsonDecode(
    File('assets/catalog.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  return Catalog.fromJson(json);
}

class FakeAppModel extends AppModel {
  FakeAppModel({
    Catalog? catalog,
    Plan plan = Plan.free,
    bool onboarded = true,
    this.online = true,
    this.exactAlarmAllowed = false,
    this.signedIn = false,
    List<Schedule>? schedules,
    List<Night>? nights,
    DateTime? now,
    Set<PermissionKind>? granted,
    Set<PermissionKind>? deniedForever,
    Set<String>? hintsSeen,
  }) : catalog = catalog ?? loadTestCatalog(),
       // ignore: prefer_initializing_formals
       _plan = plan,
       _now = now ?? DateTime(2026, 10, 28, 20, 30),
       _schedules = [...?schedules],
       _nights = [...?nights],
       _granted = {...?granted},
       deniedForever = {...?deniedForever},
       hintsSeen = {...?hintsSeen} {
    rules = ProductRules(this.catalog);
    _settings = AppSettings(onboarded: onboarded);
    _scene = Scene.fromLandscape(this.catalog.defaultLandscape);
    _browsed = _scene.landscapeId;
  }

  /// Every action called by the UI, e.g. `togglePlay`, `setTimer:TimerDuration(30)`.
  final List<String> calls = [];

  @override
  final Catalog catalog;
  @override
  late final ProductRules rules;

  Plan _plan;
  final DateTime _now;
  late Scene _scene;
  late String _browsed;
  bool _playing = false;
  bool _loading = false;
  final Map<String, String> _lastOfTheme = {};
  final List<Schedule> _schedules;
  final List<Night> _nights;
  final List<Favorite> _favorites = [];
  late AppSettings _settings;
  final Set<PermissionKind> _granted;
  final StreamController<AppEvent> _events =
      StreamController<AppEvent>.broadcast();
  int _idCounter = 0;

  /// Demo build (« Full Relax Démo »): set to true to preview the demo texts.
  @override
  bool demoMode = false;

  @override
  bool online;
  @override
  bool exactAlarmAllowed;
  @override
  bool signedIn;

  /// Permissions refused with « Ne plus demander » (cleared once granted).
  final Set<PermissionKind> deniedForever;

  /// Hints already shown (stands for the controller's local storage).
  final Set<String> hintsSeen;

  DateTime get now => _now;

  // ---- Test helpers

  void emit(AppEvent event) => _events.add(event);

  set plan(Plan plan) {
    _plan = plan;
    notifyListeners();
  }

  set loadingAudio(bool value) {
    _loading = value;
    notifyListeners();
  }

  set scene(Scene scene) {
    _scene = scene;
    _browsed = scene.landscapeId;
    notifyListeners();
  }

  void addFavoriteForTest(Scene scene) {
    _favorites.add(
      Favorite(id: 'f${_idCounter++}', scene: scene, createdAt: _now),
    );
    notifyListeners();
  }

  void setPlaying(bool value) {
    _playing = value;
    notifyListeners();
  }

  // ---- State

  @override
  Scene get scene => _scene;
  @override
  bool get playing => _playing;
  @override
  bool get loadingAudio => _loading;
  @override
  String get browsedLandscapeId => _browsed;
  @override
  bool get browsedLandscapeLocked {
    final l = catalog.landscape(_browsed);
    return l == null || !rules.canUseLandscape(plan, l);
  }

  @override
  String lastLandscapeOfTheme(String themeId) =>
      _lastOfTheme[themeId] ?? catalog.landscapesOfTheme(themeId).first.id;

  // Wall clock, like the real controller: the Standby screen counts down against
  // DateTime.now(). With the fixed `_now` the remaining time turned negative once the real
  // clock passed 28 Oct 2026 21:30, and « Il reste … » became « Le son s’arrête ».
  @override
  DateTime? get timerEndsAt => switch (_scene.timer) {
    TimerDuration(:final minutes) when _playing => DateTime.now().add(
      Duration(minutes: minutes),
    ),
    TimerNight() when _playing => DateTime.now().add(
      Duration(hours: catalog.limits.nightMaxHours),
    ),
    _ => null,
  };

  @override
  List<Schedule> get schedules => List.unmodifiable(_schedules);
  @override
  DateTime? get nextScheduledStart => Schedule.nextOf(_schedules, _now);
  @override
  List<Favorite> get favorites => List.unmodifiable(_favorites);
  @override
  bool get isCurrentSceneFavorite =>
      _favorites.any((f) => f.scene.landscapeId == _browsed);
  @override
  SleepStats get sleepStats => SleepStats.from(_nights, _now);
  @override
  AppSettings get settings => _settings;

  @override
  Entitlements get entitlements => Entitlements(
    plan: _plan,
    premium: _plan.isPremium,
    expiresAt: _plan == Plan.annual
        ? DateTime(2027, 10, 28)
        : (_plan == Plan.monthly ? DateTime(2026, 11, 28) : null),
    autoRenewing: _plan == Plan.annual || _plan == Plan.monthly,
  );

  @override
  List<ProductOffer> get offers => const [
    ProductOffer(
      choice: PurchaseChoice.annual,
      price: '59,99 €',
      available: true,
      hasFreeTrial: true,
    ),
    ProductOffer(
      choice: PurchaseChoice.monthly,
      price: '7,99 €',
      available: true,
    ),
    ProductOffer(
      choice: PurchaseChoice.lifetime,
      price: '79,99 €',
      available: true,
    ),
  ];

  @override
  Stream<AppEvent> get events => _events.stream;
  @override
  bool get onboarded => _settings.onboarded;

  @override
  bool hintSeen(String id) => hintsSeen.contains(id);

  @override
  Future<void> markHintSeen(String id) async {
    _log('markHintSeen:$id');
    hintsSeen.add(id);
  }

  void _log(String call) => calls.add(call);

  // ---- Actions

  @override
  Future<void> completeOnboarding() async {
    _log('completeOnboarding');
    _settings = _settings.copyWith(onboarded: true);
    notifyListeners();
  }

  @override
  Future<void> play() async {
    _log('play');
    _playing = true;
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    _log('pause');
    _playing = false;
    notifyListeners();
  }

  @override
  Future<void> togglePlay() async {
    _log('togglePlay');
    _playing = !_playing;
    notifyListeners();
  }

  @override
  void setTimer(TimerSetting timer) {
    _log('setTimer:$timer');
    _scene = _scene.copyWith(timer: timer);
    notifyListeners();
  }

  @override
  void browseLandscape(String landscapeId) {
    _log('browseLandscape:$landscapeId');
    final l = catalog.landscape(landscapeId);
    if (l == null) return;
    _browsed = landscapeId;
    _lastOfTheme[l.themeId] = landscapeId;
    if (rules.canUseLandscape(plan, l)) _scene = _scene.withLandscape(l);
    notifyListeners();
  }

  @override
  void selectLandscape(String landscapeId) {
    _log('selectLandscape:$landscapeId');
    final l = catalog.landscape(landscapeId);
    if (l == null) return;
    if (!rules.canUseLandscape(plan, l)) {
      _events.add(const OpenPremiumEvent());
      return;
    }
    _scene = _scene.withLandscape(l);
    _browsed = landscapeId;
    _lastOfTheme[l.themeId] = landscapeId;
    notifyListeners();
  }

  @override
  void setMoment(Moment moment) {
    _log('setMoment:${moment.name}');
    _scene = _scene.copyWith(moment: moment);
    notifyListeners();
  }

  @override
  void setLayerLevel(LayerKind kind, String id, int level) {
    _log('setLayerLevel:${kind.name}:$id:$level');
    // Like the real model: decor only on a 3D scene that can show it (contract § 12).
    if (kind == LayerKind.decor && level > 0 && !catalog.decorApplies(_scene.landscapeId, id)) return;
    if (level > 0 && !rules.canUseItem(plan, kind, id)) {
      _events.add(const OpenPremiumEvent());
      return;
    }
    final next = _scene.withLevel(
      kind,
      id,
      level,
      maxAudioLayers: catalog.limits.layersMax,
    );
    if (identical(next, _scene) && level > 0 && !_scene.hasLayer(kind, id)) {
      _events.add(
        ToastEvent('${catalog.limits.layersMax} sons au maximum en même temps'),
      );
      return;
    }
    // Like the real model: a level above 0 in a muted category unmutes it.
    _scene = level > 0 ? next.withMuted(kind, false) : next;
    notifyListeners();
  }

  @override
  void setCategoryMuted(LayerKind kind, bool muted) {
    _log('setCategoryMuted:${kind.name}:$muted');
    _scene = _scene.withMuted(kind, muted);
    notifyListeners();
  }

  @override
  Future<void> toggleFavorite() async {
    _log('toggleFavorite');
    if (isCurrentSceneFavorite) {
      _favorites.removeWhere((f) => f.scene.landscapeId == _browsed);
      notifyListeners();
      return;
    }
    final max = rules.maxFavorites(plan);
    if (max != null && _favorites.length >= max) {
      _events.add(const OpenPremiumEvent());
      return;
    }
    _favorites.add(
      Favorite(id: 'f${_idCounter++}', scene: _scene, createdAt: _now),
    );
    _events.add(const ToastEvent('Ajouté aux favoris'));
    notifyListeners();
  }

  @override
  void applyFavorite(Favorite favorite) {
    _log('applyFavorite:${favorite.id}');
    _scene = favorite.scene;
    _browsed = favorite.scene.landscapeId;
    notifyListeners();
  }

  @override
  void removeFavorite(String favoriteId) {
    _log('removeFavorite:$favoriteId');
    _favorites.removeWhere((f) => f.id == favoriteId);
    notifyListeners();
  }

  @override
  Schedule newScheduleDraft() => Schedule(
    id: 'draft-${_idCounter++}',
    hour: 22,
    minute: 0,
    days: Schedule.everyDay,
    landscapeId: _scene.landscapeId,
  );

  @override
  Future<bool> saveSchedule(Schedule schedule) async {
    _log('saveSchedule:${schedule.time}');
    final index = _schedules.indexWhere((s) => s.id == schedule.id);
    if (index >= 0) {
      _schedules[index] = schedule;
    } else {
      final max = rules.maxSchedules(plan);
      if (max != null && _schedules.length >= max) {
        _events.add(const OpenPremiumEvent());
        return false;
      }
      _schedules.add(schedule);
    }
    notifyListeners();
    return true;
  }

  @override
  Future<void> setScheduleActive(String scheduleId, bool active) async {
    _log('setScheduleActive:$scheduleId:$active');
    final index = _schedules.indexWhere((s) => s.id == scheduleId);
    if (index >= 0) {
      _schedules[index] = _schedules[index].copyWith(active: active);
    }
    notifyListeners();
  }

  @override
  Future<void> deleteSchedule(String scheduleId) async {
    _log('deleteSchedule:$scheduleId');
    _schedules.removeWhere((s) => s.id == scheduleId);
    notifyListeners();
  }

  @override
  bool permissionGranted(PermissionKind kind) =>
      kind == PermissionKind.exactAlarm
      ? exactAlarmAllowed
      : _granted.contains(kind);

  @override
  bool permissionPermanentlyDenied(PermissionKind kind) =>
      deniedForever.contains(kind) && !permissionGranted(kind);

  @override
  Future<void> openAppSettings() async => _log('openAppSettings');

  @override
  Future<bool> requestPermission(PermissionKind kind) async {
    _log('requestPermission:${kind.name}');
    if (deniedForever.contains(kind)) return false;
    if (kind == PermissionKind.exactAlarm) {
      exactAlarmAllowed = true;
    } else {
      _granted.add(kind);
    }
    notifyListeners();
    return true;
  }

  @override
  Future<void> setSleepTracking(bool enabled) async {
    _log('setSleepTracking:$enabled');
    _scene = _scene.copyWith(sleepTracking: enabled);
    notifyListeners();
  }

  @override
  Future<void> startNight() async {
    _log('startNight');
    _playing = true;
    notifyListeners();
    _events.add(const OpenStandbyEvent());
  }

  @override
  Future<void> leaveStandby() async {
    _log('leaveStandby');
  }

  @override
  Future<void> updateSettings(AppSettings settings) async {
    _log('updateSettings:${settings.toJson()}');
    _settings = settings;
    notifyListeners();
  }

  @override
  Future<Uri> createShareLink() async =>
      Uri.parse('https://example.org/m/abc123');

  @override
  Future<void> shareMix() async => _log('shareMix');

  @override
  Future<void> copyShareLink() async => _log('copyShareLink');

  @override
  Future<void> buy(PurchaseChoice choice) async => _log('buy:${choice.name}');

  @override
  Future<void> restorePurchases() async => _log('restorePurchases');

  @override
  Future<void> openManageSubscription() async => _log('openManageSubscription');

  // ---- Platform hooks

  @override
  Future<void> beforeExit() async => _log('beforeExit');

  @override
  Future<void> openBatteryGuide() async => _log('openBatteryGuide');

  @override
  Future<void> openAdPrivacyOptions() async => _log('openAdPrivacyOptions');

  @override
  Future<void> openPrivacyPolicy() async => _log('openPrivacyPolicy');

  @override
  Future<void> signInWithGoogle() async {
    _log('signInWithGoogle');
    signedIn = true;
    _settings = _settings.copyWith(onboarded: true);
    notifyListeners();
  }

  @override
  Future<bool> retryConnection() async {
    _log('retryConnection');
    return online;
  }

  @override
  Future<String> exportData() async {
    _log('exportData');
    return '{"favoris": [], "programmations": []}';
  }

  @override
  Future<void> deleteAccountData() async {
    _log('deleteAccountData');
    _favorites.clear();
    _schedules.clear();
    _nights.clear();
    notifyListeners();
  }

  // ---- Living landscapes

  /// Videos the model can give, by landscape (none by default: still pictures only).
  final Map<String, LandscapeVideoSource> videos = {};

  /// Every landscape whose video the UI asked for.
  final List<String> videoRequests = [];

  @override
  Future<LandscapeVideoSource?> landscapeVideo(String landscapeId) async {
    videoRequests.add(landscapeId);
    final l = catalog.landscape(landscapeId);
    // Same rule as the real model: nothing for a locked landscape.
    if (l == null || !rules.canUseLandscape(plan, l)) return null;
    return videos[landscapeId];
  }

  @override
  void dispose() {
    _events.close();
    super.dispose();
  }
}
