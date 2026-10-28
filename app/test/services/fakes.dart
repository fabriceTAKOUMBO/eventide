// Fakes for every platform-facing service: unit tests never call a plugin.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:eventide/app/app_model.dart';
import 'package:eventide/core/catalog.dart';
import 'package:eventide/core/plan.dart';
import 'package:eventide/services/account_service.dart';
import 'package:eventide/services/ads_service.dart';
import 'package:eventide/services/audio/audio_focus.dart';
import 'package:eventide/services/audio/media_artwork.dart';
import 'package:eventide/services/billing_service.dart';
import 'package:eventide/services/connectivity.dart';
import 'package:eventide/services/links_service.dart';
import 'package:eventide/services/native_bridge.dart';
import 'package:eventide/services/permissions_service.dart';
import 'package:eventide/services/storage.dart';
import 'package:eventide/services/voice/speech_recognizer.dart';

/// The real catalog shipped with the app.
Catalog loadTestCatalog() =>
    Catalog.fromJson(jsonDecode(File('assets/catalog.json').readAsStringSync()) as Map<String, dynamic>);

/// Every audio item of the catalog, as if bundled (no file IO in tests).
Set<String> allBundledAudio(Catalog catalog) => {
      for (final kind in const [LayerKind.son, LayerKind.musique])
        for (final item in catalog.items(kind)) 'assets/audio/${kind == LayerKind.son ? 'sons' : 'musiques'}/${item.id}.ogg',
    };

/// In-memory LocalStore with the same JSON round trip as the real one.
class MemoryStore extends LocalStore {
  MemoryStore() : super(Directory('/nonexistent/eventide-test'));

  final Map<String, String> files = {};

  @override
  Future<Object?> read(String name) async {
    final raw = files[name];
    if (raw == null) return null;
    final decoded = jsonDecode(raw);
    return decoded is Map ? decoded['data'] : null;
  }

  @override
  Future<void> write(String name, Object? data, {int version = LocalStore.formatVersion}) async {
    files[name] = jsonEncode({'version': version, 'data': data});
  }

  @override
  Future<void> delete(String name) async {
    files.remove(name);
  }
}

class FakeNativeBridge implements NativeBridge {
  final List<String> syncedPayloads = [];
  String? pendingStart;
  bool exactAllowed = true;
  int noConnectionNotifications = 0;
  int exactSettingsOpened = 0;
  int batteryGuides = 0;
  String integrityToken = 'integrity-token';
  bool integrityFails = false;
  String? lastNonce;
  NetworkInfo network = const NetworkInfo(connected: true, unmetered: true);
  final _launch = StreamController<void>.broadcast();

  Map<String, dynamic> get lastPayload => jsonDecode(syncedPayloads.last) as Map<String, dynamic>;

  void requestLaunch() => _launch.add(null);

  @override
  Future<AlarmSyncResult> syncSchedules(String payloadJson) async {
    syncedPayloads.add(payloadJson);
    final schedules = (jsonDecode(payloadJson) as Map)['schedules'] as List;
    if (schedules.isEmpty) return const AlarmSyncResult(mode: AlarmMode.none);
    return AlarmSyncResult(mode: exactAllowed ? AlarmMode.exact : AlarmMode.inexact);
  }

  @override
  Future<bool> canScheduleExactAlarms() async => exactAllowed;

  @override
  Future<bool> openExactAlarmSettings() async {
    exactSettingsOpened++;
    return true;
  }

  @override
  Future<String?> consumePendingStart() async {
    final id = pendingStart;
    pendingStart = null;
    return id;
  }

  @override
  Future<String> androidId() async => 'android-id-1';

  @override
  Future<String> requestIntegrityToken(String nonce, {String? cloudProjectNumber}) async {
    lastNonce = nonce;
    if (integrityFails) throw StateError('no Play Integrity');
    return integrityToken;
  }

  @override
  Future<void> showNoConnectionNotification() async => noConnectionNotifications++;

  @override
  Future<void> openBatteryOptimizationGuide() async => batteryGuides++;

  @override
  Future<NetworkInfo?> networkStatus() async => network;

  @override
  Stream<void> get launchScheduleRequests => _launch.stream;

  /// Native demo build flag (manifest meta-data in the real app).
  bool demoBuild = false;

  @override
  Future<bool> isDemoBuild() async => demoBuild;
}

class FakeConnectivity implements ConnectivityChecker {
  FakeConnectivity({this.online = true, this.unmetered = true});

  bool online;
  bool unmetered;
  int checks = 0;

  @override
  Future<bool> check() async {
    checks++;
    return online;
  }

  @override
  Future<bool> isUnmetered() async => unmetered;
}

class FakeFocus implements AudioFocus {
  bool granted = true;
  int activations = 0;
  int deactivations = 0;
  final _changes = StreamController<FocusChange>.broadcast(sync: true);
  final _noisy = StreamController<void>.broadcast(sync: true);

  void emit(FocusChange change) => _changes.add(change);
  void unplug() => _noisy.add(null);

  @override
  Future<bool> activate() async {
    activations++;
    return granted;
  }

  @override
  Future<void> deactivate() async => deactivations++;

  @override
  Stream<FocusChange> get changes => _changes.stream;

  @override
  Stream<void> get becomingNoisy => _noisy.stream;
}

class FakeSpeech implements SpeechRecognizer {
  bool available = true;
  List<String> locales = const ['en_US', 'fr_FR', 'fr_BE'];
  String? usedLocale;
  void Function(String text, bool isFinal)? _onResult;
  void Function(double level)? _onLevel;
  void Function(String error)? _onError;
  void Function()? _onDone;
  int stops = 0;
  int cancels = 0;

  /// Text delivered as final result when stop() is called.
  String? finalOnStop;

  bool get listening => _onResult != null;

  void partial(String text) => _onResult?.call(text, false);
  void finalResult(String text) => _onResult?.call(text, true);
  void level(double value) => _onLevel?.call(value);
  void error(String message) => _onError?.call(message);
  void done() => _onDone?.call();

  @override
  Future<bool> initialize() async => available;

  @override
  Future<String?> frenchLocale() async => pickFrenchLocale(locales);

  @override
  Future<void> listen({
    required String? localeId,
    required void Function(String text, bool isFinal) onResult,
    required void Function(double level) onLevel,
    required void Function(String error) onError,
    required void Function() onDone,
    Duration maxDuration = const Duration(seconds: 20),
  }) async {
    usedLocale = localeId;
    _onResult = onResult;
    _onLevel = onLevel;
    _onError = onError;
    _onDone = onDone;
  }

  @override
  Future<void> stop() async {
    stops++;
    final text = finalOnStop;
    if (text != null) finalResult(text);
  }

  @override
  Future<void> cancel() async {
    cancels++;
    _onResult = null;
  }
}

class FakeBilling implements Billing {
  final _events = StreamController<BillingEvent>.broadcast();
  final List<String> calls = [];

  void emit(BillingEvent event) => _events.add(event);

  @override
  Stream<BillingEvent> get events => _events.stream;

  @override
  Future<void> initialize() async => calls.add('initialize');

  @override
  Future<List<ProductOffer>> loadOffers() async => const [
        ProductOffer(choice: PurchaseChoice.annual, price: '59,99 €', available: true, hasFreeTrial: true),
        ProductOffer(choice: PurchaseChoice.monthly, price: '7,99 €', available: true),
        ProductOffer(choice: PurchaseChoice.lifetime, price: '79,99 €', available: true),
      ];

  @override
  Future<void> buy(PurchaseChoice choice) async => calls.add('buy:${choice.name}');

  @override
  Future<void> buyCredits() async => calls.add('credits');

  @override
  Future<void> restore() async => calls.add('restore');

  @override
  String? get creditsPrice => '2,99 €';
}

class FakeAds implements AdsService {
  final List<AdPlacement> shown = [];
  int privacyForms = 0;

  @override
  Future<bool> initialize() async => true;

  @override
  Future<bool> show(AdPlacement placement) async {
    shown.add(placement);
    return true;
  }

  @override
  Future<void> showPrivacyOptions() async => privacyForms++;
}

class FakeAccount implements AccountAuth {
  String? idToken = 'google-id-token';
  int signOuts = 0;

  @override
  Future<String?> signIn() async => idToken;

  @override
  Future<void> signOut() async => signOuts++;
}

class FakeLinks implements LinkSource {
  final _links = StreamController<Uri>.broadcast();

  void open(Uri uri) => _links.add(uri);

  @override
  Future<Uri?> initialLink() async => null;

  @override
  Stream<Uri> get links => _links.stream;
}

class FakeShare implements ShareSheet {
  final List<String> shared = [];
  final List<String> copied = [];

  @override
  Future<void> share(String text, {String? subject}) async => shared.add(text);

  @override
  Future<void> copy(String text) async => copied.add(text);
}

class FakePermissions implements Permissions {
  final Map<PermissionKind, bool> granted = {
    PermissionKind.microphone: true,
    PermissionKind.notifications: true,
    PermissionKind.exactAlarm: true,
  };
  final List<PermissionKind> requested = [];

  /// Kinds refused with « Ne plus demander ».
  final Set<PermissionKind> deniedForever = {};
  int settingsOpened = 0;

  @override
  Future<bool> isGranted(PermissionKind kind) async => granted[kind] ?? false;

  @override
  Future<bool> request(PermissionKind kind) async {
    requested.add(kind);
    return granted[kind] ?? false;
  }

  @override
  Future<bool> isPermanentlyDenied(PermissionKind kind) async => deniedForever.contains(kind);

  @override
  Future<bool> openSettings() async {
    settingsOpened++;
    return true;
  }
}

class FakeUrlOpener implements UrlOpener {
  final List<Uri> opened = [];

  /// False: nothing on the phone can open links.
  bool succeeds = true;

  @override
  Future<bool> open(Uri uri) async {
    opened.add(uri);
    return succeeds;
  }
}

/// In-memory files of the media card pictures.
class MemoryArtworkFiles implements ArtworkFiles {
  final Map<String, Uint8List> files = {};
  final List<String> writes = [];

  @override
  String get directory => '/cache/media_art';

  @override
  Future<bool> exists(String path) async => files.containsKey(path);

  @override
  Future<void> write(String path, Uint8List bytes) async {
    writes.add(path);
    files[path] = bytes;
  }
}

Entitlements entitlementsFor(Plan plan) => switch (plan) {
      Plan.free => Entitlements.free(),
      Plan.lifetime => const Entitlements(
          plan: Plan.lifetime, premium: true, voice: VoiceQuota(mode: VoiceMode.credits, creditsRemaining: 10)),
      _ => Entitlements(plan: plan, premium: true, voice: const VoiceQuota(mode: VoiceMode.included)),
    };

/// Lets pending microtasks and short timers run.
Future<void> settle([int ms = 20]) => Future<void>.delayed(Duration(milliseconds: ms));
