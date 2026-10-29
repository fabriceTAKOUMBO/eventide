// RealAppModel: the application layer behind the UI contract (app_model.dart), wired on the
// platform services. Rules live in lib/core; this class sequences them with storage, audio,
// network, billing, ads and the native scheduled starts.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;

import '../core/catalog.dart';
import '../core/landscape_media.dart';
import '../core/lightning.dart';
import '../core/media_card.dart';
import '../core/ops.dart';
import '../core/plan.dart';
import '../core/scene.dart';
import '../core/schedule.dart';
import '../core/settings.dart';
import '../core/share_codec.dart';
import '../core/sleep.dart';
import '../services/account_service.dart';
import '../services/ads_service.dart';
import '../services/api_client.dart';
import '../services/audio/audio_engine.dart';
import '../services/audio/event_scheduler.dart';
import '../services/audio/media_artwork.dart';
import '../services/audio/playback_handler.dart';
import '../services/billing_service.dart';
import '../services/connectivity.dart';
import '../services/content_repository.dart';
import '../services/links_service.dart';
import '../services/native_bridge.dart';
import '../services/permissions_service.dart';
import '../services/storage.dart';
import '../services/voice/speech_recognizer.dart';
import '../services/voice/voice_pipeline.dart';
import 'app_model.dart';
import 'demo_mode.dart';
import 'sleep_tracker.dart';

/// Static choices of the controller (from Env in the app, explicit in tests).
class AppConfig {
  const AppConfig({
    this.shareHost = 'eventide.app',
    this.forcedPlan,
    this.browseDebounce = const Duration(milliseconds: 1500),
    this.subscriptionOfflineGrace = const Duration(days: 7),
    this.demo = false,
  });

  final String shareHost;

  /// Demo build (DemoMode.resolve): Premium forced on the phone, no purchase, no ads, no
  /// entitlement request to the server.
  final bool demo;

  /// DEBUG_FORCE_PLAN (debug builds only).
  final Plan? forcedPlan;

  /// The sound follows a swiped landscape after this pause (dossier, screen 2).
  final Duration browseDebounce;

  /// A cached subscription stays valid this long after its expiry when the server cannot be
  /// reached (Premium works offline).
  final Duration subscriptionOfflineGrace;
}

/// Messages shown by the controller (French, plain words).
abstract final class AppMessages {
  static const addedToFavorites = 'Ajouté aux favoris';
  static const removedFromFavorites = 'Retiré des favoris';
  static String tooManyLayers(int max) => '$max sons au maximum en même temps. Retirez-en un d’abord.';
  static const nothingToPlay = 'Ajoutez un son dans « Mon mix » pour commencer.';
  static const contentUnavailable = 'Ce son n’est pas disponible pour le moment. Réessayez plus tard.';
  static const notDownloaded = 'Ces sons ne sont pas encore téléchargés. Connectez-vous une fois à internet.';
  static const cannotStart = 'Le son ne peut pas démarrer pour le moment (un appel est peut-être en cours).';
  static const shareNotFound = 'Ce lien de partage n’existe plus.';
  static const shareOffline = 'Pas de connexion pour ouvrir ce lien. Réessayez plus tard.';
  static const premiumActive = 'Merci ! Premium est activé.';
  static const creditsAdded = 'Crédits d’assistant ajoutés.';
  static const purchasePending = 'Paiement en attente de confirmation par Google Play.';
  static const nothingToRestore = 'Aucun achat Premium trouvé pour ce compte Google Play.';
  static const signInFailed = 'La connexion avec Google n’a pas abouti. Réessayez.';
  static const signedIn = 'Votre compte Google est relié.';
  static const deleteOffline = 'Suppression impossible sans connexion. Réessayez plus tard.';
  static const deleteFailed = 'La suppression n’a pas abouti. Réessayez plus tard.';
  static const dataDeleted = 'Vos données ont été supprimées.';
  static const openPlayManually =
      'Ouvrez Google Play, touchez votre photo, puis « Paiements et abonnements » et « Abonnements ».';
  static String openPageManually(Uri uri) => 'La page ne s’ouvre pas. Adresse : $uri';

  // Voice
  static const micDenied = 'Autorisez le micro pour parler à l’assistant.';
  static const noRecognizer = 'La reconnaissance vocale n’est pas disponible sur ce téléphone.';
  static const nothingHeard = 'Je n’ai rien entendu. Touchez le micro et parlez tout de suite.';
  static const recognizerOffline = 'Pas de connexion : la reconnaissance vocale de ce téléphone a besoin d’internet.';
  static const trialUsed = 'Vos 3 essais gratuits de l’assistant sont utilisés.';
  static const creditsUsed = 'Vos crédits d’assistant sont épuisés.';
  static const premiumOnly = 'Cela fait partie de Premium.';

  static String rephrase(String reason) => switch (reason) {
        'ambigu' => 'Plusieurs programmations correspondent. Précisez l’heure, par exemple « celle de 22 h ».',
        'introuvable' => 'Je ne trouve pas cette programmation.',
        _ => VoiceMessages.notUnderstood,
      };

  static String refuse(String reason, int maxLayers) => switch (reason) {
        'hors_catalogue' =>
          'Je ne sais pas faire cela. Je règle les sons, le minuteur, les programmations, le sommeil et les réglages.',
        'couches_max' => tooManyLayers(maxLayers),
        _ => 'Je ne peux pas faire cela à la voix.',
      };
}

class _Prepared {
  _Prepared(this.request, {required this.failed, required this.offline});

  final PlayRequest request;

  /// Some layers could not be resolved.
  final bool failed;

  /// ...because a network access was needed.
  final bool offline;
}

class RealAppModel extends AppModel implements PlaybackHost {
  RealAppModel({
    required Catalog catalog,
    required this._store,
    required this._handler,
    required this._content,
    required this._native,
    required ApiClient api,
    required this._connectivity,
    required this._speech,
    required this._billing,
    required this._ads,
    required this._account,
    required this._links,
    required this._share,
    required this._permissions,
    required this._urls,
    this._config = const AppConfig(),
    this._artwork,
    DateTime Function()? now,
    Random? random,
  })  : _catalog = catalog,
        _rules = ProductRules(catalog),
        _api = api,
        _voice = VoicePipeline(catalog: catalog, api: api),
        _now = now ?? DateTime.now,
        _random = random ?? Random(),
        _scene = Scene.fromLandscape(catalog.defaultLandscape),
        _browsedId = catalog.defaultLandscape.id;

  final Catalog _catalog;
  final ProductRules _rules;
  final LocalStore _store;
  final PlaybackHandler _handler;
  final ContentRepository _content;
  final NativeBridge _native;
  final ApiClient _api;
  final ConnectivityChecker _connectivity;
  final SpeechRecognizer _speech;
  final VoicePipeline _voice;
  final Billing _billing;
  final AdsService _ads;
  final AccountAuth _account;
  final LinkSource _links;
  final ShareSheet _share;
  final Permissions _permissions;
  final UrlOpener _urls;
  final AppConfig _config;

  /// Pictures of the system media card (null in tests that do not need them).
  final MediaArtwork? _artwork;
  final DateTime Function() _now;
  final Random _random;

  final _events = StreamController<AppEvent>.broadcast();
  final _ready = Completer<void>();
  final List<StreamSubscription<Object?>> _subscriptions = [];

  Scene _scene;
  String _browsedId;
  final Map<String, String> _lastByTheme = {};
  Timer? _browseTimer;
  List<Schedule> _schedules = const [];
  List<Favorite> _favorites = const [];
  List<Night> _nights = const [];
  AppSettings _settings = const AppSettings();
  Entitlements _entitlements = Entitlements.free();
  bool _signedIn = false;
  List<ProductOffer> _offers = fallbackOffers;
  bool _online = true;
  DateTime? _onlineCheckedAt;
  bool _exactAlarmAllowed = false;
  AlarmMode _alarmMode = AlarmMode.none;
  final Map<PermissionKind, bool> _permissionCache = {};
  final Map<PermissionKind, bool> _deniedForever = {};
  final Set<String> _hintsSeen = {};
  final SleepTracker _tracker = SleepTracker();
  final Map<AdPlacement, DateTime> _adLastShown = {};
  final AdPolicy _adPolicy = const AdPolicy();

  /// Landscapes whose poster is downloaded (synchronous lookups by the UI).
  final Set<String> _posterIds = {};

  // System media card (lock screen, notification shade): see « Media card » below.
  final ValueNotifier<MediaCardInfo?> _mediaCard = ValueNotifier(null);
  Object? _cardInputs;

  /// Pictures asked for during this listening session (landscape|moment).
  final Set<String> _artRequested = {};

  bool _preparing = false;
  int _audioGeneration = 0;
  final Map<String, AudioSourceRef> _sources = {};
  bool _foreground = false;
  bool _foregroundInitDone = false;
  DateTime? _lastStandbyEvent;
  String? _lastLink;
  DateTime? _lastLinkAt;
  Timer? _saveSceneTimer;
  Timer? _saveStateTimer;

  // Voice
  VoiceState _voiceState = const VoiceIdle();
  int _voiceSession = 0;
  String _partial = '';
  double _level = 0;
  bool _finalHandled = true;
  Timer? _voiceMaxTimer;
  Timer? _voiceStopGrace;
  String? _locale;
  bool _localeResolved = false;
  AppSnapshot? _undoSnapshot;
  OpenNight? _undoNight;

  /// Completes when local data is loaded (the audio handler waits for it).
  Future<void> get ready => _ready.future;

  /// How the next scheduled start is armed (exact, inexact, none).
  AlarmMode get alarmMode => _alarmMode;

  // ---------------------------------------------------------------------------
  // Init and lifecycle
  // ---------------------------------------------------------------------------

  Future<void> init() async {
    try {
      await _load();
    } catch (e) {
      debugPrint('RealAppModel: load failed ($e)');
    }
    _handler.nightMaxHours = _catalog.limits.nightMaxHours;
    _handler.status.addListener(_onPlaybackStatus);
    // The media card follows every change of the model (cheap when nothing it shows moved).
    addListener(_refreshMediaCard);
    _refreshMediaCard();
    _handler.attachHost(this);
    _subscriptions
      ..add(_billing.events.listen(_onBillingEvent))
      ..add(_links.links.listen((uri) => unawaited(openLink(uri))))
      ..add(_native.launchScheduleRequests.listen((_) => unawaited(_checkPendingStart())));
    if (!_ready.isCompleted) _ready.complete();
    notifyListeners();
    // Not awaited: file system only, the UI shows procedural pictures until it answers.
    unawaited(_refreshPosters());
    unawaited(_afterInit());
  }

  Future<void> _afterInit() async {
    try {
      await _billing.initialize();
    } catch (e) {
      debugPrint('RealAppModel: billing init failed ($e)');
    }
    await _syncSchedules();
    await _refreshPermissions();
    notifyListeners();
  }

  Future<void> _load() async {
    final sceneJson = await _store.readMap(StoreKeys.scene);
    if (sceneJson != null) {
      // An unreadable or unknown scene keeps the default one.
      final scene = _tryParse(() => Scene.fromJson(sceneJson));
      if (scene != null && _catalog.landscape(scene.landscapeId) != null) _scene = scene;
    }
    _browsedId = _scene.landscapeId;
    _schedules = [
      for (final json in await _store.readList(StoreKeys.schedules))
        if (_tryParse(() => Schedule.fromJson(json)) case final Schedule s) s,
    ];
    _favorites = [
      for (final json in await _store.readList(StoreKeys.favorites))
        if (_tryParse(() => Favorite.fromJson(json)) case final Favorite f) f,
    ];
    _nights = [
      for (final json in await _store.readList(StoreKeys.nights))
        if (_tryParse(() => Night.fromJson(json)) case final Night n) n,
    ];
    final settingsJson = await _store.readMap(StoreKeys.settings);
    if (settingsJson != null) _settings = AppSettings.fromJson(settingsJson);
    final entitlementsJson = await _store.readMap(StoreKeys.entitlements);
    if (entitlementsJson != null) _entitlements = Entitlements.fromJson(entitlementsJson);
    final quotaJson = await _store.readMap(StoreKeys.voiceTrial);
    if (quotaJson != null) _entitlements = _withQuota(_entitlements, VoiceQuota.fromJson(quotaJson));
    final state = await _store.readMap(StoreKeys.appState);
    if (state != null) {
      final last = state['last_landscape_by_theme'];
      if (last is Map) {
        for (final entry in last.entries) {
          if (entry.value is String && _catalog.landscape(entry.value as String) != null) {
            _lastByTheme['${entry.key}'] = entry.value as String;
          }
        }
      }
      _signedIn = state['signed_in'] == true;
      final hints = state['hints_seen'];
      if (hints is List) _hintsSeen.addAll(hints.whereType<String>());
      _tracker.open = OpenNight.fromJson(state['open_night']);
      for (final placement in AdPlacement.values) {
        final at = DateTime.tryParse('${state['ad_${placement.name}']}');
        if (at != null) _adLastShown[placement] = at;
      }
    }
  }

  static T? _tryParse<T>(T Function() parse) {
    try {
      return parse();
    } catch (_) {
      return null;
    }
  }

  /// Wire to AppLifecycleListener (main.dart).
  void handleLifecycle(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _foreground = true;
        unawaited(_onResumed());
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _foreground = false;
        unawaited(_flushSaves());
      case AppLifecycleState.inactive:
        break;
    }
  }

  Future<void> _onResumed() async {
    await _ready.future;
    final night = _tracker.onWake(_now());
    if (night != null) await _addNight(night);
    if (!_foregroundInitDone) {
      _foregroundInitDone = true;
      await _firstForeground();
    } else {
      await _refreshPermissions();
      final allowed = await _native.canScheduleExactAlarms();
      if (allowed != _exactAlarmAllowed) {
        _exactAlarmAllowed = allowed;
        await _syncSchedules();
      }
      notifyListeners();
    }
    await _checkPendingStart();
  }

  Future<void> _firstForeground() async {
    _exactAlarmAllowed = await _native.canScheduleExactAlarms();
    try {
      _offers = await _billing.loadOffers();
    } catch (_) {}
    notifyListeners();
    final online = await _connectivity.check();
    _setOnline(online);
    if (online && _api.enabled) await _refreshEntitlements();
    if (entitlements.plan.isPremium) {
      unawaited(_prefetch(wifiOnly: _settings.wifiOnly));
    }
    if (online) await _maybeShowAd(AdPlacement.open);
  }

  /// « Lancer » on the fallback notification, or the app opened right at a scheduled start.
  Future<void> _checkPendingStart() async {
    final id = await _native.consumePendingStart();
    if (id != null) await _handler.playScheduled(id);
  }

  Future<void> _refreshPermissions() async {
    for (final kind in PermissionKind.values) {
      final granted = await _permissions.isGranted(kind);
      _permissionCache[kind] = granted;
      _deniedForever[kind] = !granted && await _permissions.isPermanentlyDenied(kind);
    }
    _exactAlarmAllowed = _permissionCache[PermissionKind.exactAlarm] ?? _exactAlarmAllowed;
  }

  void _setOnline(bool online) {
    _online = online;
    _onlineCheckedAt = _now();
    notifyListeners();
  }

  void _emit(AppEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  @override
  void dispose() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    _browseTimer?.cancel();
    _saveSceneTimer?.cancel();
    _saveStateTimer?.cancel();
    _voiceMaxTimer?.cancel();
    _voiceStopGrace?.cancel();
    _handler.status.removeListener(_onPlaybackStatus);
    _events.close();
    _mediaCard.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Persistence
  // ---------------------------------------------------------------------------

  void _saveScene() {
    _saveSceneTimer?.cancel();
    _saveSceneTimer = Timer(const Duration(milliseconds: 400), () {
      _saveSceneTimer = null;
      unawaited(_store.write(StoreKeys.scene, _scene.toJson()));
    });
  }

  void _saveState() {
    _saveStateTimer?.cancel();
    _saveStateTimer = Timer(const Duration(milliseconds: 400), () {
      _saveStateTimer = null;
      unawaited(_writeState());
    });
  }

  Future<void> _writeState() => _store.write(StoreKeys.appState, {
        'last_landscape_by_theme': _lastByTheme,
        'signed_in': _signedIn,
        'open_night': _tracker.open?.toJson(),
        'hints_seen': [..._hintsSeen],
        for (final entry in _adLastShown.entries) 'ad_${entry.key.name}': entry.value.toIso8601String(),
      });

  Future<void> _flushSaves() async {
    if (_saveSceneTimer != null) {
      _saveSceneTimer!.cancel();
      _saveSceneTimer = null;
      await _store.write(StoreKeys.scene, _scene.toJson());
    }
    if (_saveStateTimer != null) {
      _saveStateTimer!.cancel();
      _saveStateTimer = null;
      await _writeState();
    }
  }

  Future<void> _saveSchedules() => _store.write(StoreKeys.schedules, [for (final s in _schedules) s.toJson()]);

  Future<void> _saveFavorites() => _store.write(StoreKeys.favorites, [for (final f in _favorites) f.toJson()]);

  Future<void> _saveSettings() => _store.write(StoreKeys.settings, _settings.toJson());

  // ---------------------------------------------------------------------------
  // Static data, entitlements
  // ---------------------------------------------------------------------------

  @override
  Catalog get catalog => _catalog;

  @override
  ProductRules get rules => _rules;

  @override
  bool get demoMode => _config.demo;

  @override
  Entitlements get entitlements {
    if (_config.demo) return DemoMode.entitlements;
    final forced = _config.forcedPlan;
    if (forced != null) {
      return Entitlements(
        plan: forced,
        premium: forced.isPremium,
        voice: switch (forced) {
          Plan.free => _entitlements.voice.mode == VoiceMode.trial
              ? _entitlements.voice
              : const VoiceQuota(mode: VoiceMode.trial, trialRemaining: 3),
          Plan.lifetime => VoiceQuota(mode: VoiceMode.credits, creditsRemaining: _entitlements.voice.creditsRemaining),
          _ => const VoiceQuota(mode: VoiceMode.included),
        },
      );
    }
    final e = _entitlements;
    final expires = e.expiresAt;
    if (e.plan == Plan.monthly || e.plan == Plan.annual) {
      if (expires != null && _now().isAfter(expires.add(_config.subscriptionOfflineGrace))) {
        return Entitlements(plan: Plan.free, premium: false, voice: e.voice);
      }
    }
    return e;
  }

  Plan get _plan => entitlements.plan;

  static Entitlements _withQuota(Entitlements e, VoiceQuota quota) => Entitlements(
        plan: e.plan,
        premium: e.premium,
        expiresAt: e.expiresAt,
        autoRenewing: e.autoRenewing,
        voice: quota,
      );

  Future<void> _setEntitlements(Entitlements next) async {
    final wasPremium = entitlements.plan.isPremium;
    _entitlements = next;
    await _store.write(StoreKeys.entitlements, next.toJson());
    await _store.write(StoreKeys.voiceTrial, next.voice.toJson());
    await _syncSchedules();
    if (!wasPremium && entitlements.plan.isPremium) {
      unawaited(_prefetch(wifiOnly: _settings.wifiOnly));
    }
    notifyListeners();
  }

  Future<void> _updateVoiceQuota(VoiceQuota quota) async {
    _entitlements = _withQuota(_entitlements, quota);
    await _store.write(StoreKeys.voiceTrial, quota.toJson());
  }

  Future<void> _refreshEntitlements() async {
    if (_config.demo) return; // Premium is forced locally; the server knows nothing of it.
    try {
      await _setEntitlements(Entitlements.fromJson(await _api.entitlements()));
    } catch (e) {
      debugPrint('RealAppModel: entitlements refresh failed ($e)');
    }
  }

  @override
  bool get signedIn => _signedIn;

  @override
  List<ProductOffer> get offers => _offers;

  @override
  String? get creditsPrice => _billing.creditsPrice;

  @override
  bool get online => _online;

  @override
  bool get exactAlarmAllowed => _exactAlarmAllowed;

  @override
  Stream<AppEvent> get events => _events.stream;

  // ---------------------------------------------------------------------------
  // Listening state
  // ---------------------------------------------------------------------------

  @override
  Scene get scene => _scene;

  @override
  bool get playing => _handler.status.value.playing;

  @override
  bool get loadingAudio => _preparing || _handler.status.value.loading;

  @override
  DateTime? get timerEndsAt => _handler.status.value.timerEndsAt;

  @override
  String get browsedLandscapeId => _browsedId;

  @override
  bool get browsedLandscapeLocked {
    final landscape = _catalog.landscape(_browsedId);
    return landscape == null || !_rules.canUseLandscape(_plan, landscape);
  }

  @override
  String lastLandscapeOfTheme(String themeId) {
    final remembered = _lastByTheme[themeId];
    if (remembered != null) return remembered;
    final list = _catalog.landscapesOfTheme(themeId);
    return list.isEmpty ? _catalog.defaultLandscape.id : list.first.id;
  }

  void _onPlaybackStatus() => notifyListeners();

  // ---------------------------------------------------------------------------
  // Audio preparation
  // ---------------------------------------------------------------------------

  bool get _loaded {
    final st = _handler.status.value;
    return st.playing || st.paused;
  }

  /// Engine layers of [scene]. A muted category keeps its layers at volume 0 (parked by the
  /// engine). [progressive]: the mix starts from silence or changes landscape, so the music
  /// comes in over [MixRules.musicEntry].
  Future<_Prepared> _prepare(
    Scene scene, {
    String? subtitle,
    Duration rampUp = Duration.zero,
    String? scheduleId,
    bool progressive = false,
  }) async {
    final layers = <EngineLayer>[];
    final events = <EventLayer>[];
    var failed = false;
    var offline = false;
    for (final kind in const [LayerKind.son, LayerKind.musique]) {
      for (final layer in scene.layers(kind)) {
        // Locked items of a shared mix stay visible but muted for a free user.
        if (layer.level <= 0 || !_rules.canUseItem(_plan, kind, layer.id)) continue;
        final key = MixRules.layerKey(kind, layer.id);
        final item = _catalog.item(kind, layer.id);
        final eventSound = item?.events;
        if (eventSound != null) {
          // Played by events (thunder, contract § 11): each variant is found or downloaded when
          // an event needs it, never all of them before the sound starts.
          final variants = [
            for (final id in eventSound.variants)
              if (await _content.isPublished(kind, id)) EventVariant(id, () => _resolveVariant(kind, id)),
          ];
          if (variants.isEmpty) continue;
          events.add(EventLayer(
            key: key,
            variants: variants,
            volume: MixRules.layerVolume(kind, scene.effectiveLevel(kind, layer.level)),
            interval: eventSound.interval,
            firstDelay: eventSound.firstDelay,
          ));
          continue;
        }
        // An ambiance neither bundled nor on the content server (test material, demo build
        // only) is left out without a message.
        if (item != null && item.isAmbiance && !await _content.isPublished(kind, layer.id)) continue;
        try {
          final source = _sources[key] ??= await _content.resolve(kind, layer.id, allowNetwork: true);
          layers.add(EngineLayer(
            key: key,
            source: source,
            volume: MixRules.layerVolume(kind, scene.effectiveLevel(kind, layer.level)),
            fadeIn: MixRules.entryFade(kind, progressive: progressive),
            resumeFade: MixRules.resumeFadeOf(kind),
          ));
        } on ContentUnavailableException catch (e) {
          failed = true;
          offline = offline || e.offline;
        }
      }
    }
    if (layers.isEmpty && events.isNotEmpty) {
      // Only event sounds (thunder alone): a parked, silent voice carries the session, so that
      // pause, timer and media card work as with any mix (a parked voice is not decoded).
      final carrier = _carrierSource();
      if (carrier != null) layers.add(EngineLayer(key: _carrierKey, source: carrier, volume: 0));
    }
    final landscape = _catalog.landscape(scene.landscapeId);
    return _Prepared(
      PlayRequest(
        landscapeId: scene.landscapeId,
        title: landscape?.name ?? 'Eventide',
        subtitle: subtitle,
        layers: layers,
        timer: scene.timer,
        rampUp: rampUp,
        scheduleId: scheduleId,
        events: events,
      ),
      failed: failed,
      offline: offline,
    );
  }

  Future<AudioSourceRef> _resolveVariant(LayerKind kind, String id) async =>
      _sources[MixRules.layerKey(kind, id)] ??= await _content.resolve(kind, id, allowNetwork: true);

  static const String _carrierKey = 'carrier';

  /// A free, bundled loop (never heard: parked at volume 0) for a mix of event sounds only.
  AudioSourceRef? _carrierSource() {
    for (final s in _catalog.sounds) {
      if (s.free && s.events == null && !s.isAmbiance) {
        return AssetAudioSource(ContentRepository.assetKey(LayerKind.son, s.id));
      }
    }
    return null;
  }

  void _reportContentFailure(_Prepared prepared) {
    if (prepared.offline) {
      if (!_plan.isPremium) {
        _setOnline(false);
        _emit(const OfflineEvent());
      } else {
        _emit(const ToastEvent(AppMessages.notDownloaded));
      }
    } else {
      _emit(const ToastEvent(AppMessages.contentUnavailable));
    }
  }

  /// The free plan needs a real connection to start sound (dossier § 3, screen 13).
  Future<bool> _freeUserOnline() async {
    if (_plan.isPremium) return true;
    final checked = _onlineCheckedAt;
    if (_online && checked != null && _now().difference(checked) < const Duration(minutes: 2)) return true;
    final online = await _connectivity.check();
    _setOnline(online);
    return online;
  }

  /// Brings the loaded audio in line with the scene (never cuts what plays on a failure).
  /// [crossFade]: the mix was replaced (landscape, favorite, shared mix), new music comes in
  /// progressively. [fade]: fade of the kept layers otherwise (default 0.4 s).
  Future<void> _syncAudio({bool crossFade = false, Duration? fade}) async {
    if (!_loaded) return;
    final generation = ++_audioGeneration;
    final prepared = await _prepare(_scene, progressive: crossFade);
    if (generation != _audioGeneration || !_loaded) return;
    if (prepared.failed) _reportContentFailure(prepared);
    if (prepared.request.layers.isEmpty) {
      if (_scene.audioLayerCount == 0) await _handler.stop();
      return;
    }
    await _handler.updateLayers(prepared.request, crossFade: crossFade, fade: fade);
  }

  // ---------------------------------------------------------------------------
  // Playback
  // ---------------------------------------------------------------------------

  void _setPreparing(bool value) {
    _preparing = value;
    notifyListeners();
  }

  @override
  Future<void> play() async {
    await _ready.future;
    if (_handler.status.value.paused) {
      await _handler.play();
      return;
    }
    if (playing || loadingAudio) return;
    final landscape = _catalog.landscape(_scene.landscapeId);
    if (landscape == null || !_rules.canUseLandscape(_plan, landscape)) {
      _emit(const OpenPremiumEvent());
      return;
    }
    if (_scene.audioLayerCount == 0) {
      _emit(const ToastEvent(AppMessages.nothingToPlay));
      return;
    }
    _setPreparing(true);
    try {
      if (!await _freeUserOnline()) {
        _emit(const OfflineEvent());
        return;
      }
      _unmuteSilentStart();
      final prepared = await _prepare(_scene, progressive: true);
      if (prepared.request.layers.isEmpty) {
        _reportContentFailure(prepared);
        return;
      }
      if (prepared.failed) _reportContentFailure(prepared);
      if (!await _handler.start(prepared.request)) {
        _emit(const ToastEvent(AppMessages.cannotStart));
      }
    } finally {
      _setPreparing(false);
    }
  }

  /// A start from silence where everything in the mix is muted would play nothing: both
  /// categories are unmuted first (contract § 1). A resume after a pause keeps the mute.
  void _unmuteSilentStart() {
    if (!_scene.fullyMuted) return;
    _scene = _scene.withoutMute();
    _saveScene();
    notifyListeners();
  }

  @override
  Future<void> pause() => _handler.pause();

  @override
  Future<void> togglePlay() => playing ? pause() : play();

  @override
  void setTimer(TimerSetting timer) {
    if (_scene.timer == timer && !_loaded) return;
    _scene = _scene.copyWith(timer: timer);
    _saveScene();
    _handler.setTimer(timer);
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // PlaybackHost (system and scheduled starts)
  // ---------------------------------------------------------------------------

  @override
  Future<PlayRequest?> requestPlay({String? scheduleId}) async {
    await _ready.future;
    Scene scene = _scene;
    String? subtitle;
    var rampUp = Duration.zero;
    Schedule? schedule;
    if (scheduleId != null) {
      for (final s in _schedules) {
        if (s.id == scheduleId) schedule = s;
      }
      if (schedule == null || !schedule.active) return null; // deleted or switched off meanwhile
      var landscape = _catalog.landscape(schedule.landscapeId);
      if (landscape == null || !_rules.canUseLandscape(_plan, landscape)) {
        // Premium ended since the schedule was made: fall back to a free landscape.
        landscape = _catalog.defaultLandscape;
      }
      scene = Scene.fromLandscape(
        landscape,
        moment: _scene.moment,
        timer: _scene.timer,
        sleepTracking: _scene.sleepTracking,
        mutedSounds: _scene.mutedSounds,
        mutedMusic: _scene.mutedMusic,
      );
      // A scheduled start is never silent.
      if (scene.fullyMuted) scene = scene.withoutMute();
      subtitle = schedule.reminder.notificationText;
      rampUp = Duration(minutes: schedule.rampMinutes);
    } else {
      final landscape = _catalog.landscape(scene.landscapeId);
      if (landscape == null || !_rules.canUseLandscape(_plan, landscape)) return null;
    }
    if (!_plan.isPremium) {
      final online = await _connectivity.check();
      _setOnline(online);
      if (!online) {
        // Free plan needs the network: notify instead of playing (dossier, screen 9).
        if (scheduleId != null) await _native.showNoConnectionNotification();
        if (_foreground) _emit(const OfflineEvent());
        return null;
      }
    }
    final silentStart = schedule == null && scene.fullyMuted;
    if (silentStart) scene = scene.withoutMute();
    final prepared = await _prepare(
      scene,
      subtitle: subtitle,
      rampUp: rampUp,
      scheduleId: scheduleId,
      progressive: true,
    );
    if (prepared.request.layers.isEmpty) {
      if (_foreground) _reportContentFailure(prepared);
      return null;
    }
    // Started from the notification with everything muted: unmuted (see _unmuteSilentStart).
    if (silentStart) _unmuteSilentStart();
    if (schedule != null) {
      _scene = scene;
      _browsedId = scene.landscapeId;
      _rememberTheme(scene.landscapeId);
      _saveScene();
      if (schedule.reminder == Reminder.dormir && scene.sleepTracking) {
        _tracker.startNight(_now());
        _saveState();
      }
      notifyListeners();
    }
    return prepared.request;
  }

  @override
  void onPlaybackStarted(PlayRequest request) {
    final noTimer = request.timer is TimerNone;
    if (_foreground && _settings.blackScreenDuringTimer && !noTimer) _openStandby();
  }

  @override
  void onPlaybackStopped(StopReason reason, Duration listened) {
    // A picture that failed may be made at the next session (the UI may be up by then).
    _artRequested.clear();
    final night = _tracker.onPlaybackStopped(_now(), listened);
    _saveState();
    if (night != null) unawaited(_addNight(night));
    notifyListeners();
  }

  void _openStandby() {
    final last = _lastStandbyEvent;
    final now = _now();
    if (last != null && now.difference(last) < const Duration(seconds: 5)) return;
    _lastStandbyEvent = now;
    _emit(const OpenStandbyEvent());
  }

  // ---------------------------------------------------------------------------
  // Landscapes and mix
  // ---------------------------------------------------------------------------

  void _rememberTheme(String landscapeId) {
    final landscape = _catalog.landscape(landscapeId);
    if (landscape == null) return;
    _lastByTheme[landscape.themeId] = landscapeId;
    _saveState();
  }

  @override
  void browseLandscape(String landscapeId) {
    final landscape = _catalog.landscape(landscapeId);
    if (landscape == null) return;
    _browsedId = landscapeId;
    _rememberTheme(landscapeId);
    _browseTimer?.cancel();
    _browseTimer = Timer(_config.browseDebounce, () {
      _browseTimer = null;
      unawaited(_commitBrowse(landscapeId));
      // The card goes back to the scene when the browse did not change it (locked, offline).
      _refreshMediaCard();
    });
    notifyListeners();
  }

  Future<void> _commitBrowse(String landscapeId) async {
    final landscape = _catalog.landscape(landscapeId);
    if (landscape == null || _browsedId != landscapeId) return;
    // A locked landscape is only seen: the current sound keeps playing (dossier, screen 2).
    if (!_rules.canUseLandscape(_plan, landscape)) return;
    if (landscape.id == _scene.landscapeId) return;
    if (_loaded && !_plan.isPremium && !_online) {
      _emit(const OfflineEvent());
      return;
    }
    _scene = _scene.withLandscape(landscape);
    _saveScene();
    notifyListeners();
    await _syncAudio(crossFade: true);
  }

  @override
  void selectLandscape(String landscapeId) {
    final landscape = _catalog.landscape(landscapeId);
    if (landscape == null) return;
    if (!_rules.canUseLandscape(_plan, landscape)) {
      _emit(const OpenPremiumEvent());
      return;
    }
    _browseTimer?.cancel();
    _browsedId = landscapeId;
    _rememberTheme(landscapeId);
    _scene = _scene.withLandscape(landscape);
    _saveScene();
    notifyListeners();
    unawaited(_syncAudio(crossFade: true));
  }

  @override
  void setMoment(Moment moment) {
    if (_scene.moment == moment) return;
    _scene = _scene.copyWith(moment: moment);
    _saveScene();
    notifyListeners();
  }

  @override
  void setLayerLevel(LayerKind kind, String id, int level) {
    final item = _catalog.item(kind, id);
    if (item == null) return;
    final target = level.clamp(0, 100);
    final present = _scene.hasLayer(kind, id);
    if (target > 0 && !_rules.canUseItem(_plan, kind, id)) {
      _emit(const OpenPremiumEvent());
      return;
    }
    final max = _catalog.limits.layersMax;
    if (!present && target > 0 && kind.isAudio && _scene.audioLayerCount >= max) {
      _emit(ToastEvent(AppMessages.tooManyLayers(max)));
      return;
    }
    var next = _scene.withLevel(kind, id, target, maxAudioLayers: max);
    // Touching a level of a muted category makes it heard again.
    final unmute = target > 0 && next.isMuted(kind);
    if (unmute) next = next.withMuted(kind, false);
    if (identical(next, _scene)) return;
    _scene = next;
    _saveScene();
    notifyListeners();
    if (kind.isAudio) unawaited(_syncAudio(fade: unmute ? MixRules.muteFade : null));
  }

  @override
  void setCategoryMuted(LayerKind kind, bool muted) {
    final next = _scene.withMuted(kind, muted);
    if (identical(next, _scene)) return;
    _scene = next;
    _saveScene();
    notifyListeners();
    unawaited(_syncAudio(fade: MixRules.muteFade));
  }

  // ---------------------------------------------------------------------------
  // Favorites
  // ---------------------------------------------------------------------------

  static String _mixKey(Scene scene) {
    final json = shareableSceneJson(scene)..remove('moment');
    return jsonEncode(json);
  }

  Favorite? _currentFavorite() => _favoriteOf(_scene);

  Favorite? _favoriteOf(Scene scene) {
    final key = _mixKey(scene);
    for (final f in _favorites) {
      if (_mixKey(f.scene) == key) return f;
    }
    return null;
  }

  @override
  List<Favorite> get favorites => List.unmodifiable(_favorites);

  @override
  bool get isCurrentSceneFavorite => _currentFavorite() != null;

  @override
  Future<void> toggleFavorite() => _toggleFavorite(quiet: false);

  /// [quiet]: from the media card, no message and no Premium screen (the app may be closed);
  /// at the free limit nothing changes.
  Future<void> _toggleFavorite({required bool quiet}) async {
    final existing = _currentFavorite();
    if (existing != null) {
      _favorites = [
        for (final f in _favorites)
          if (f.id != existing.id) f,
      ];
      await _saveFavorites();
      if (!quiet) _emit(const ToastEvent(AppMessages.removedFromFavorites));
      notifyListeners();
      return;
    }
    final max = _rules.maxFavorites(_plan);
    if (max != null && _favorites.length >= max) {
      if (!quiet) _emit(const OpenPremiumEvent());
      return;
    }
    _favorites = [
      ..._favorites,
      Favorite(
        id: _newId(),
        // The mix only: no timer, no sleep tracking, no mute (listening states).
        scene: _scene.copyWith(timer: Scene.defaultTimer, sleepTracking: false).withoutMute(),
        createdAt: _now(),
      ),
    ];
    await _saveFavorites();
    if (!quiet) _emit(const ToastEvent(AppMessages.addedToFavorites));
    notifyListeners();
  }

  @override
  void applyFavorite(Favorite favorite) {
    final landscape = _catalog.landscape(favorite.landscapeId);
    if (landscape == null) return;
    if (!_rules.canUseLandscape(_plan, landscape)) {
      _emit(const OpenPremiumEvent());
      return;
    }
    _browseTimer?.cancel();
    _scene = favorite.scene.copyWith(
      timer: _scene.timer,
      sleepTracking: _scene.sleepTracking,
      mutedSounds: _scene.mutedSounds,
      mutedMusic: _scene.mutedMusic,
    );
    _browsedId = _scene.landscapeId;
    _rememberTheme(_scene.landscapeId);
    _saveScene();
    notifyListeners();
    unawaited(_syncAudio(crossFade: true));
  }

  @override
  void removeFavorite(String favoriteId) {
    _favorites = [
      for (final f in _favorites)
        if (f.id != favoriteId) f,
    ];
    unawaited(_saveFavorites());
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Media card (PlaybackHost): what the lock screen and notification card show, and its
  // buttons. Every button goes through the app's own paths: previous/next is a home swipe
  // (debounced, default mix, progressive melody, locked landscapes skipped), the heart is
  // the favourite toggle, the timer button sets the timer. Play/pause is handled by the
  // playback handler and only changes the sound (never the landscape video).
  // ---------------------------------------------------------------------------

  @override
  ValueListenable<MediaCardInfo?> get mediaCard => _mediaCard;

  bool get _browsePending => _browseTimer?.isActive ?? false;

  /// Landscape of the card: the scene's, or the usable one a previous/next tap or a swipe is
  /// about to load (the card shows it at once, the sound follows after the browse pause).
  String get _cardLandscapeId {
    if (_browsePending && _browsedId != _scene.landscapeId) {
      final browsed = _catalog.landscape(_browsedId);
      if (browsed != null && _rules.canUseLandscape(_plan, browsed)) return _browsedId;
    }
    return _scene.landscapeId;
  }

  /// Sound loaded or being prepared: the card is (or is about to be) on screen.
  bool get _audioActive {
    final st = _handler.status.value;
    return _preparing || st.loading || st.playing || st.paused;
  }

  void _refreshMediaCard() {
    if (_events.isClosed) return;
    final id = _cardLandscapeId;
    final landscape = _catalog.landscape(id);
    if (landscape == null) return;
    final art = _artwork;
    final moment = _scene.moment;
    final inputs = (_scene, _favorites, id, _plan, art?.peek(id, moment));
    if (inputs != _cardInputs) {
      _cardInputs = inputs;
      final scene = id == _scene.landscapeId ? _scene : _scene.withLandscape(landscape);
      bool usable(Landscape l) => _rules.canUseLandscape(_plan, l);
      _mediaCard.value = MediaCardInfo(
        landscapeId: id,
        title: landscape.name,
        artist: mixSummary(scene, _catalog, canUse: (kind, item) => _rules.canUseItem(_plan, kind, item)),
        moment: moment,
        favorite: _favoriteOf(scene) != null,
        previousId: neighbourLandscape(_catalog, id, -1, usable),
        nextId: neighbourLandscape(_catalog, id, 1, usable),
        artUri: art?.peek(id, moment),
      );
    }
    _requestArtwork(landscape, moment);
  }

  /// Makes the card's picture in the background, only while the card can be seen; the card
  /// is published without it first and updated when it is ready.
  void _requestArtwork(Landscape landscape, Moment moment) {
    final art = _artwork;
    if (art == null || !_audioActive || art.peek(landscape.id, moment) != null) return;
    if (!_artRequested.add('${landscape.id}|${moment.name}')) return;
    unawaited(art.resolve(landscape, moment).then((uri) {
      if (uri != null) _refreshMediaCard();
    }));
  }

  @override
  Future<void> skipLandscape(int direction) async {
    await _ready.future;
    final target = neighbourLandscape(
      _catalog,
      _cardLandscapeId,
      direction,
      (l) => _rules.canUseLandscape(_plan, l),
    );
    if (target != null) browseLandscape(target);
  }

  @override
  Future<void> toggleFavoriteFromCard() async {
    await _ready.future;
    // A previous/next tap still waiting: the heart is for the landscape the card shows.
    if (_browsePending) {
      _browseTimer!.cancel();
      _browseTimer = null;
      await _commitBrowse(_browsedId);
    }
    await _toggleFavorite(quiet: true);
  }

  @override
  Future<void> cycleTimerFromCard() async {
    await _ready.future;
    setTimer(nextMediaCardTimer(_scene.timer));
  }

  // ---------------------------------------------------------------------------
  // Schedules
  // ---------------------------------------------------------------------------

  @override
  List<Schedule> get schedules => List.unmodifiable(_schedules);

  @override
  DateTime? get nextScheduledStart => Schedule.nextOf(_armableSchedules(), _now());

  /// Active schedules within the plan's limit (a free user after a downgrade keeps one).
  List<Schedule> _armableSchedules() {
    final max = _rules.maxSchedules(_plan);
    final out = <Schedule>[];
    for (final s in _schedules) {
      if (!s.active || _catalog.landscape(s.landscapeId) == null) continue;
      if (max != null && out.length >= max) break;
      out.add(s);
    }
    return out;
  }

  Future<void> _syncSchedules() async {
    final payload = jsonEncode({
      'schedules': [
        for (final s in _armableSchedules()) {...s.toJson(), 'paysage_nom': _catalog.landscape(s.landscapeId)!.name},
      ],
      'requires_network': !_rules.offlineAllowed(_plan),
    });
    try {
      final result = await _native.syncSchedules(payload);
      _alarmMode = result.mode;
    } catch (e) {
      debugPrint('RealAppModel: syncSchedules failed ($e)');
    }
  }

  @override
  Schedule newScheduleDraft() {
    final current = _catalog.landscape(_scene.landscapeId);
    final landscape =
        current != null && _rules.canUseLandscape(_plan, current) ? current : _catalog.defaultLandscape;
    return Schedule(
      id: _newId(),
      hour: 22,
      minute: 0,
      days: Schedule.everyDay,
      rampMinutes: Schedule.defaultRampMinutes,
      landscapeId: landscape.id,
      reminder: Reminder.dormir,
      active: true,
    );
  }

  @override
  Future<bool> saveSchedule(Schedule schedule) async {
    final index = _schedules.indexWhere((s) => s.id == schedule.id);
    final max = _rules.maxSchedules(_plan);
    if (index < 0 && max != null && _schedules.length >= max) {
      _emit(const OpenPremiumEvent());
      return false;
    }
    final landscape = _catalog.landscape(schedule.landscapeId);
    if (landscape == null) return false;
    if (!_rules.canUseLandscape(_plan, landscape)) {
      _emit(const OpenPremiumEvent());
      return false;
    }
    _schedules = index < 0
        ? [..._schedules, schedule]
        : [
            for (final s in _schedules) s.id == schedule.id ? schedule : s,
          ];
    await _saveSchedules();
    await _syncSchedules();
    notifyListeners();
    return true;
  }

  @override
  Future<void> setScheduleActive(String scheduleId, bool active) async {
    _schedules = [
      for (final s in _schedules) s.id == scheduleId ? s.copyWith(active: active) : s,
    ];
    await _saveSchedules();
    await _syncSchedules();
    notifyListeners();
  }

  @override
  Future<void> deleteSchedule(String scheduleId) async {
    _schedules = [
      for (final s in _schedules)
        if (s.id != scheduleId) s,
    ];
    await _saveSchedules();
    await _syncSchedules();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Permissions
  // ---------------------------------------------------------------------------

  @override
  bool permissionGranted(PermissionKind kind) => _permissionCache[kind] ?? false;

  @override
  Future<bool> requestPermission(PermissionKind kind) async {
    final granted = await _permissions.request(kind);
    _permissionCache[kind] = granted;
    _deniedForever[kind] = !granted && await _permissions.isPermanentlyDenied(kind);
    if (kind == PermissionKind.exactAlarm && granted != _exactAlarmAllowed) {
      _exactAlarmAllowed = granted;
      await _syncSchedules();
    }
    notifyListeners();
    return granted;
  }

  @override
  bool permissionPermanentlyDenied(PermissionKind kind) => _deniedForever[kind] ?? false;

  /// The answer is read again when the app comes back to the foreground.
  @override
  Future<void> openAppSettings() async {
    await _permissions.openSettings();
  }

  @override
  Future<void> openBatteryGuide() => _native.openBatteryOptimizationGuide();

  // ---------------------------------------------------------------------------
  // Sleep
  // ---------------------------------------------------------------------------

  @override
  SleepStats get sleepStats {
    final nights = _rules.sleepHistory(_plan) || _nights.isEmpty ? _nights : [_nights.last];
    return SleepStats.from(nights, _now());
  }

  Future<void> _addNight(Night night) async {
    final all = [..._nights, night]..sort((a, b) => a.end.compareTo(b.end));
    _nights = all.length > 120 ? all.sublist(all.length - 120) : all;
    await _store.write(StoreKeys.nights, [for (final n in _nights) n.toJson()]);
    _saveState();
    notifyListeners();
  }

  @override
  Future<void> setSleepTracking(bool enabled) async {
    _scene = _scene.copyWith(sleepTracking: enabled);
    if (!enabled) {
      _tracker.open = null;
      _saveState();
    }
    _saveScene();
    notifyListeners();
  }

  @override
  Future<void> startNight() async {
    if (_scene.sleepTracking) {
      _tracker.startNight(_now());
      _saveState();
    }
    if (!playing) await play();
    _openStandby();
  }

  @override
  Future<void> leaveStandby() async {
    final night = _tracker.onWake(_now());
    _saveState();
    if (night != null) await _addNight(night);
  }

  // ---------------------------------------------------------------------------
  // Settings, onboarding
  // ---------------------------------------------------------------------------

  @override
  AppSettings get settings => _settings;

  @override
  bool get onboarded => _settings.onboarded;

  @override
  Future<void> completeOnboarding() => updateSettings(_settings.copyWith(onboarded: true));

  @override
  bool hintSeen(String id) => _hintsSeen.contains(id);

  @override
  Future<void> markHintSeen(String id) async {
    if (!_hintsSeen.add(id)) return;
    await _writeState();
  }

  // ---------------------------------------------------------------------------
  // Living landscapes (videos and posters). Never tied to the sound: nothing here reads or
  // changes the playback state, and nothing in the playback path touches the video.
  // ---------------------------------------------------------------------------

  /// Premium offline: sounds, music and landscape posters in the background.
  Future<void> _prefetch({required bool wifiOnly}) async {
    try {
      await _content.prefetchForOffline(_catalog, wifiOnly: wifiOnly);
    } catch (e) {
      debugPrint('RealAppModel: prefetch failed ($e)');
    }
    await _refreshPosters();
  }

  Future<void> _refreshPosters() async {
    final ids = await _content.downloadedLandscapeImages();
    if (_events.isClosed) return; // disposed meanwhile
    if (ids.length == _posterIds.length && ids.containsAll(_posterIds)) return;
    _posterIds
      ..clear()
      ..addAll(ids);
    notifyListeners();
  }

  @override
  String? landscapePosterFile(String landscapeId) =>
      _posterIds.contains(landscapeId) ? _content.cachedPath(LandscapeMediaKeys.image(landscapeId)) : null;

  @override
  Stream<LightningStrike> get lightningStrikes => _handler.lightningStrikes;

  @override
  Future<LandscapeVideoSource?> landscapeVideo(String landscapeId) async {
    final landscape = _catalog.landscape(landscapeId);
    // A locked landscape shows its still picture only: nothing is downloaded for it.
    if (landscape == null || !_rules.canUseLandscape(_plan, landscape)) return null;
    // Only Premium content lives on the server; free landscapes are bundled.
    final download = _plan.isPremium;
    final wifiOnly = _settings.wifiOnly;
    try {
      if (!_posterIds.contains(landscapeId)) {
        // The poster first (small): the real picture shows while the video downloads.
        final poster = await _content.landscapeImage(landscapeId, allowDownload: download, wifiOnly: wifiOnly);
        if (poster != null && _posterIds.add(landscapeId) && !_events.isClosed) notifyListeners();
      }
      if (_events.isClosed || !_rules.canUseLandscape(_plan, landscape)) return null;
      return await _content.landscapeVideo(landscapeId, allowDownload: download, wifiOnly: wifiOnly);
    } catch (e) {
      debugPrint('RealAppModel: landscape video $landscapeId unavailable ($e)');
      return null;
    }
  }

  @override
  Future<void> updateSettings(AppSettings settings) async {
    final before = _settings;
    _settings = settings;
    await _saveSettings();
    notifyListeners();
    if (before.wifiOnly && !settings.wifiOnly && _plan.isPremium) {
      unawaited(_prefetch(wifiOnly: false));
    }
  }

  // ---------------------------------------------------------------------------
  // Sharing and incoming links
  // ---------------------------------------------------------------------------

  @override
  Future<Uri> createShareLink() async {
    if (_api.enabled && _online) {
      try {
        return await _api.createShare(shareableSceneJson(_scene));
      } catch (e) {
        debugPrint('RealAppModel: share link from server failed ($e)');
      }
    }
    // Self-contained link, works without the server (contract § 8).
    return shareLinkFor(_scene, _config.shareHost);
  }

  @override
  Future<void> shareMix() async {
    final link = await createShareLink();
    final name = _catalog.landscape(_scene.landscapeId)?.name ?? 'Eventide';
    await _share.share('Écoutez mon ambiance « $name » sur Eventide : $link', subject: 'Mon ambiance Eventide');
  }

  @override
  Future<void> copyShareLink() async {
    final link = await createShareLink();
    await _share.copy(link.toString());
  }

  /// Opens a share link (`/m/<code>` or `/s#<data>`).
  Future<void> openLink(Uri uri) async {
    final text = uri.toString();
    final now = _now();
    if (_lastLink == text && _lastLinkAt != null && now.difference(_lastLinkAt!) < const Duration(seconds: 3)) return;
    _lastLink = text;
    _lastLinkAt = now;
    await _ready.future;
    Scene? shared;
    final code = shareCodeFromUri(uri);
    if (code != null) {
      if (!_api.enabled) return;
      try {
        shared = sceneFromSharedJson(await _api.getShare(code), _catalog);
      } on ApiException catch (e) {
        _emit(ToastEvent(e.status == 404 ? AppMessages.shareNotFound : AppMessages.shareOffline));
        return;
      } on ApiUnavailableException {
        _emit(const ToastEvent(AppMessages.shareOffline));
        return;
      }
    } else {
      shared = sceneFromShareUri(uri, _catalog);
    }
    if (shared == null) return;
    // The recipient keeps their own timer and sleep tracking, and hears the shared mix: a
    // shared scene never carries a mute (contract § 8).
    final scene = shared.copyWith(timer: _scene.timer, sleepTracking: _scene.sleepTracking);
    final locked = _rules.lockedElements(_plan, scene);
    final landscape = _catalog.landscape(scene.landscapeId)!;
    _browseTimer?.cancel();
    _browsedId = landscape.id;
    _rememberTheme(landscape.id);
    if (_rules.canUseLandscape(_plan, landscape)) {
      _scene = scene;
      _saveScene();
      unawaited(_syncAudio(crossFade: true));
    }
    notifyListeners();
    _emit(SharedMixOpenedEvent(lockedItems: locked.length));
  }

  // ---------------------------------------------------------------------------
  // Voice
  // ---------------------------------------------------------------------------

  @override
  VoiceState get voiceState => _voiceState;

  void _setVoice(VoiceState state) {
    _voiceState = state;
    notifyListeners();
  }

  AppSnapshot _snapshot() => AppSnapshot(
        scene: _scene,
        schedules: _schedules,
        settings: _settings,
        playing: playing,
      );

  @override
  Future<void> startVoice() async {
    if (_voiceState is VoiceListening || _voiceState is VoiceThinking) return;
    if (!await _permissions.isGranted(PermissionKind.microphone)) {
      _permissionCache[PermissionKind.microphone] = false;
      _setVoice(const VoiceError(message: AppMessages.micDenied));
      return;
    }
    if (!await _speech.initialize()) {
      _setVoice(const VoiceError(message: AppMessages.noRecognizer));
      return;
    }
    if (!_localeResolved) {
      _locale = await _speech.frenchLocale();
      _localeResolved = true;
    }
    final session = ++_voiceSession;
    _partial = '';
    _level = 0;
    _finalHandled = false;
    _undoSnapshot = null;
    _setVoice(const VoiceListening());
    _voiceMaxTimer?.cancel();
    _voiceMaxTimer = Timer(const Duration(seconds: 21), () => unawaited(stopVoice()));
    try {
      await _speech.listen(
        localeId: _locale,
        maxDuration: const Duration(seconds: 20),
        onResult: (text, isFinal) {
          if (session != _voiceSession || _finalHandled) return;
          _partial = text;
          if (isFinal) {
            _onVoiceFinal(session, text);
          } else {
            _setVoice(VoiceListening(partialText: text, soundLevel: _level));
          }
        },
        onLevel: (level) {
          if (session != _voiceSession || _finalHandled) return;
          _level = level;
          _setVoice(VoiceListening(partialText: _partial, soundLevel: level));
        },
        onError: (error) {
          if (session != _voiceSession || _finalHandled) return;
          if (_partial.trim().isEmpty) {
            _finalHandled = true;
            _cancelVoiceTimers();
            if (error.contains('network')) {
              _setVoice(const VoiceError(message: AppMessages.recognizerOffline, offline: true));
            } else if (error.contains('permission')) {
              _setVoice(const VoiceError(message: AppMessages.micDenied));
            } else {
              _setVoice(const VoiceRephrase(phrase: '', message: AppMessages.nothingHeard));
            }
            return;
          }
          _onVoiceFinal(session, _partial);
        },
        onDone: () {
          if (session != _voiceSession) return;
          _onVoiceFinal(session, _partial);
        },
      );
    } catch (e) {
      debugPrint('RealAppModel: listen failed ($e)');
      _finalHandled = true;
      _cancelVoiceTimers();
      _setVoice(const VoiceError(message: AppMessages.noRecognizer));
    }
  }

  void _cancelVoiceTimers() {
    _voiceMaxTimer?.cancel();
    _voiceMaxTimer = null;
    _voiceStopGrace?.cancel();
    _voiceStopGrace = null;
  }

  @override
  Future<void> stopVoice() async {
    if (_voiceState is! VoiceListening || _finalHandled) return;
    final session = _voiceSession;
    _voiceMaxTimer?.cancel();
    // The final result normally follows stop(); never wait more than 2 s for it.
    _voiceStopGrace?.cancel();
    _voiceStopGrace = Timer(const Duration(seconds: 2), () => _onVoiceFinal(session, _partial));
    try {
      await _speech.stop();
    } catch (_) {
      _onVoiceFinal(session, _partial);
    }
  }

  void _onVoiceFinal(int session, String text) {
    if (session != _voiceSession || _finalHandled) return;
    _finalHandled = true;
    _cancelVoiceTimers();
    unawaited(_processPhrase(session, text.trim()));
  }

  Future<void> _processPhrase(int session, String phrase) async {
    if (phrase.isEmpty) {
      _setVoice(const VoiceRephrase(phrase: '', message: AppMessages.nothingHeard));
      return;
    }
    _setVoice(VoiceThinking(phrase: phrase));
    final before = _snapshot();
    final resolution = await _voice.resolve(phrase: phrase, snapshot: before, entitlements: entitlements);
    if (session != _voiceSession) return; // closed meanwhile
    switch (resolution) {
      case VoiceQuotaExhaustedResolution():
        final lifetime = _plan == Plan.lifetime;
        final quota = entitlements.voice;
        await _updateVoiceQuota(VoiceQuota(
          mode: quota.mode,
          trialRemaining: lifetime ? quota.trialRemaining : 0,
          creditsRemaining: lifetime ? 0 : quota.creditsRemaining,
          monthlyCapReached: quota.monthlyCapReached,
        ));
        _setVoice(VoiceRefused(phrase: phrase, message: lifetime ? AppMessages.creditsUsed : AppMessages.trialUsed));
        _emit(lifetime ? const OpenCreditsEvent() : const OpenPremiumEvent());
      case VoiceFailureResolution(:final message, :final offline, :final rephrase, :final quota):
        if (quota != null) await _updateVoiceQuota(quota);
        if (offline) {
          _setVoice(VoiceError(message: message, offline: true));
        } else if (rephrase) {
          _setVoice(VoiceRephrase(phrase: phrase, message: message));
        } else {
          _setVoice(VoiceError(message: message));
        }
      case VoiceOpsResolution(:final ops, :final quota):
        if (quota != null) await _updateVoiceQuota(quota);
        await _applyVoiceOps(session, phrase, before, ops);
    }
  }

  Future<void> _applyVoiceOps(int session, String phrase, AppSnapshot before, List<Map<String, dynamic>> ops) async {
    final result = applyOps(before, ops, _catalog, newId: _newId, now: _now(), plan: _plan);
    final effects = result.effects;
    final changes = [...result.changes];
    if (effects.contains(const ShareEffect()) && !changes.any((c) => c.label == 'Partage')) {
      changes.add(const ChangeLine('Partage', 'Prêt à envoyer'));
    }
    final label = quotaLabel(entitlements.voice);
    if (changes.isEmpty) {
      // Nothing changed: explain why instead of a « C’est fait » card.
      final rephrase = effects.whereType<RephraseEffect>().firstOrNull;
      final refuse = effects.whereType<RefuseEffect>().firstOrNull;
      if (effects.contains(const OpenPremiumEffect())) {
        _setVoice(VoiceRefused(phrase: phrase, message: AppMessages.premiumOnly));
        _emit(const OpenPremiumEvent());
      } else if (refuse != null) {
        _setVoice(VoiceRefused(phrase: phrase, message: AppMessages.refuse(refuse.reason, _catalog.limits.layersMax)));
      } else {
        _setVoice(VoiceRephrase(phrase: phrase, message: AppMessages.rephrase(rephrase?.reason ?? 'incompris')));
      }
      return;
    }
    // Provisional application: heard at once, undone by « Annuler ».
    _undoSnapshot = before;
    _undoNight = _tracker.open;
    await _installSnapshot(result.snapshot);
    for (final effect in effects) {
      switch (effect) {
        case PauseEffect():
          await pause();
        case ResumeEffect():
          await play();
        case StartNightEffect():
          await startNight();
        case ShareEffect():
          _emit(const OpenShareEvent());
        case OpenPremiumEffect():
          _emit(const OpenPremiumEvent());
        case RephraseEffect():
        case RefuseEffect():
          break;
      }
    }
    if (session != _voiceSession) return;
    _setVoice(VoiceResult(phrase: phrase, changes: changes, quotaLabel: label));
  }

  /// Installs scene, schedules and settings (voice result or undo) and brings audio along.
  Future<void> _installSnapshot(AppSnapshot snapshot) async {
    final landscapeChanged = snapshot.scene.landscapeId != _scene.landscapeId;
    final muteChanged =
        snapshot.scene.mutedSounds != _scene.mutedSounds || snapshot.scene.mutedMusic != _scene.mutedMusic;
    final timerChanged = snapshot.scene.timer != _scene.timer;
    final schedulesChanged = !listEquals(snapshot.schedules, _schedules);
    final settingsChanged = snapshot.settings != _settings;
    _scene = snapshot.scene;
    _browseTimer?.cancel();
    _browsedId = _scene.landscapeId;
    _rememberTheme(_scene.landscapeId);
    _saveScene();
    if (schedulesChanged) {
      _schedules = snapshot.schedules;
      await _saveSchedules();
      await _syncSchedules();
    }
    if (settingsChanged) {
      _settings = snapshot.settings;
      await _saveSettings();
    }
    if (!_scene.sleepTracking && _tracker.isOpen) {
      _tracker.open = null;
      _saveState();
    }
    notifyListeners();
    if (timerChanged) _handler.setTimer(_scene.timer);
    await _syncAudio(crossFade: landscapeChanged, fade: muteChanged ? MixRules.muteFade : null);
  }

  @override
  Future<void> undoVoice() async {
    final before = _undoSnapshot;
    _undoSnapshot = null;
    if (before == null) {
      _setVoice(const VoiceIdle());
      return;
    }
    await _installSnapshot(before);
    _tracker.open = _undoNight;
    _saveState();
    if (before.playing && !playing) {
      await play();
    } else if (!before.playing && playing) {
      await pause();
    }
    _setVoice(const VoiceIdle());
  }

  @override
  void keepVoice() {
    _undoSnapshot = null;
    _setVoice(const VoiceIdle());
  }

  @override
  void resetVoice() {
    if (_voiceState is VoiceListening && !_finalHandled) {
      unawaited(_speech.cancel().catchError((_) {}));
    }
    _voiceSession++;
    _finalHandled = true;
    _cancelVoiceTimers();
    _undoSnapshot = null;
    _setVoice(const VoiceIdle());
  }

  // ---------------------------------------------------------------------------
  // Purchases
  // ---------------------------------------------------------------------------

  void _onBillingEvent(BillingEvent event) {
    switch (event) {
      case EntitlementsChanged(:final entitlements):
        final wasPremium = this.entitlements.plan.isPremium;
        final credits = this.entitlements.voice.creditsRemaining;
        unawaited(_setEntitlements(entitlements).then((_) {
          if (!wasPremium && this.entitlements.plan.isPremium) {
            _emit(const ToastEvent(AppMessages.premiumActive));
          } else if (this.entitlements.voice.creditsRemaining > credits) {
            _emit(const ToastEvent(AppMessages.creditsAdded));
          }
        }));
      case PurchasePending():
        _emit(const ToastEvent(AppMessages.purchasePending));
      case PurchaseFailed(:final message):
        _emit(ToastEvent(message));
    }
  }

  @override
  Future<void> buy(PurchaseChoice choice) async {
    if (_config.demo) {
      _emit(const ToastEvent(DemoMode.premiumActive));
      return;
    }
    await _billing.buy(choice);
  }

  @override
  Future<void> buyCredits() async {
    if (_config.demo) {
      _emit(const ToastEvent(DemoMode.premiumActive));
      return;
    }
    await _billing.buyCredits();
  }

  @override
  Future<void> restorePurchases() async {
    if (_config.demo) {
      _emit(const ToastEvent(DemoMode.nothingToRestore));
      return;
    }
    await _billing.restore();
    if (_api.enabled) await _refreshEntitlements();
    if (!entitlements.plan.isPremium) _emit(const ToastEvent(AppMessages.nothingToRestore));
  }

  // ---------------------------------------------------------------------------
  // Ads
  // ---------------------------------------------------------------------------

  Future<void> _maybeShowAd(AdPlacement placement) async {
    // Never on the very first launch: the welcome screen comes first (dossier, screen 1).
    if (!_settings.onboarded) return;
    final allowed = _adPolicy.canShow(
      showsAds: _rules.showsAds(_plan),
      playing: playing || loadingAudio,
      lastShown: _adLastShown[placement],
      now: _now(),
    );
    if (!allowed || !_online) return;
    try {
      if (await _ads.show(placement)) {
        _adLastShown[placement] = _now();
        _saveState();
      }
    } catch (e) {
      debugPrint('RealAppModel: ad failed ($e)');
    }
  }

  @override
  Future<void> beforeExit() async {
    await _maybeShowAd(AdPlacement.exit);
    await _flushSaves();
  }

  @override
  Future<void> openAdPrivacyOptions() => _ads.showPrivacyOptions();

  // ---------------------------------------------------------------------------
  // Outgoing pages
  // ---------------------------------------------------------------------------

  /// Google Play's subscriptions page, opened on Eventide's subscription.
  static final Uri manageSubscriptionUri = Uri.https('play.google.com', '/store/account/subscriptions', {
    'sku': ProductIds.premium,
    'package': 'be.cinaf.eventide',
  });

  Uri get privacyPolicyUri => Uri.https(_config.shareHost, '/confidentialite');

  @override
  Future<void> openManageSubscription() async {
    if (_config.demo) {
      _emit(const ToastEvent(DemoMode.premiumActive));
      return;
    }
    if (!await _urls.open(manageSubscriptionUri)) _emit(const ToastEvent(AppMessages.openPlayManually));
  }

  @override
  Future<void> openPrivacyPolicy() async {
    final uri = privacyPolicyUri;
    if (!await _urls.open(uri)) _emit(ToastEvent(AppMessages.openPageManually(uri)));
  }

  // ---------------------------------------------------------------------------
  // Account and data
  // ---------------------------------------------------------------------------

  @override
  Future<void> signInWithGoogle() async {
    final idToken = await _account.signIn();
    if (idToken == null) return;
    if (_api.enabled) {
      try {
        await _api.linkGoogle(idToken);
      } catch (e) {
        debugPrint('RealAppModel: link Google failed ($e)');
        _emit(const ToastEvent(AppMessages.signInFailed));
        return;
      }
      await _refreshEntitlements();
    }
    _signedIn = true;
    _saveState();
    _emit(const ToastEvent(AppMessages.signedIn));
    notifyListeners();
  }

  @override
  Future<bool> retryConnection() async {
    final online = await _connectivity.check();
    _setOnline(online);
    if (online && _api.enabled) unawaited(_refreshEntitlements());
    return online;
  }

  @override
  Future<String> exportData() async {
    await _flushSaves();
    final phone = await _store.exportAll();
    Map<String, dynamic>? server;
    if (_api.enabled) {
      try {
        server = await _api.exportAccount();
      } catch (e) {
        debugPrint('RealAppModel: server export failed ($e)');
      }
    }
    return const JsonEncoder.withIndent('  ').convert({
      'application': 'Eventide',
      'exporte_le': _now().toIso8601String(),
      'telephone': phone,
      'serveur': ?server,
    });
  }

  @override
  Future<void> deleteAccountData() async {
    if (_api.enabled) {
      try {
        await _api.deleteAccount();
      } on ApiException catch (e) {
        if (e.status != 401 && e.status != 404) {
          _emit(const ToastEvent(AppMessages.deleteFailed));
          return;
        }
      } on ApiUnavailableException {
        _emit(const ToastEvent(AppMessages.deleteOffline));
        return;
      }
    }
    await _handler.stop();
    await _account.signOut();
    _saveSceneTimer?.cancel();
    _saveStateTimer?.cancel();
    await _store.deleteAll();
    await _content.clear();
    await _api.forgetInstallation();
    _sources.clear();
    _posterIds.clear();
    _scene = Scene.fromLandscape(_catalog.defaultLandscape);
    _browsedId = _scene.landscapeId;
    _lastByTheme.clear();
    _schedules = const [];
    _favorites = const [];
    _nights = const [];
    _settings = const AppSettings();
    _entitlements = Entitlements.free();
    _signedIn = false;
    _tracker.open = null;
    _adLastShown.clear();
    _hintsSeen.clear();
    await _syncSchedules();
    notifyListeners();
    _emit(const ToastEvent(AppMessages.dataDeleted));
  }

  // ---------------------------------------------------------------------------

  String _newId() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(10, (_) => chars[_random.nextInt(chars.length)]).join();
  }
}
