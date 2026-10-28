import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:eventide/app/app_controller.dart';
import 'package:eventide/app/app_model.dart';
import 'package:eventide/core/catalog.dart';
import 'package:eventide/core/plan.dart';
import 'package:eventide/core/scene.dart';
import 'package:eventide/core/schedule.dart';
import 'package:eventide/core/settings.dart';
import 'package:eventide/core/share_codec.dart';
import 'package:eventide/services/ads_service.dart';
import 'package:eventide/services/api_client.dart';
import 'package:eventide/services/audio/audio_engine.dart';
import 'package:eventide/services/audio/fake_audio_engine.dart';
import 'package:eventide/services/audio/playback_handler.dart';
import 'package:eventide/services/billing_service.dart';
import 'package:eventide/services/content_repository.dart';
import 'package:eventide/services/storage.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../services/fakes.dart';

class Harness {
  final Catalog catalog = loadTestCatalog();
  MemoryStore store = MemoryStore();
  final engine = FakeAudioEngine();
  final focus = FakeFocus();
  final native = FakeNativeBridge();
  final connectivity = FakeConnectivity();
  final speech = FakeSpeech();
  final billing = FakeBilling();
  final ads = FakeAds();
  final account = FakeAccount();
  final links = FakeLinks();
  final share = FakeShare();
  final permissions = FakePermissions();
  final events = <AppEvent>[];
  DateTime now = DateTime(2026, 10, 28, 21);
  late PlaybackHandler handler;
  late RealAppModel model;

  Future<RealAppModel> start({Plan? plan, Future<http.Response> Function(http.Request)? backend}) async {
    handler = PlaybackHandler(engine: engine, focus: focus, native: native, now: () => now);
    final client = MockClient(backend ?? (request) async => http.Response('', 500));
    final api = ApiClient(
      baseUrl: backend == null ? '' : 'https://api.test/v1',
      client: client,
      store: store,
      native: native,
      appVersion: '1.0.0',
      deviceSalt: 'salt',
    );
    final content = ContentRepository(
      directory: Directory('/nonexistent/eventide-content'),
      client: client,
      api: api,
      bundledAssets: () async => allBundledAudio(catalog),
      connectivity: connectivity,
    );
    model = RealAppModel(
      catalog: catalog,
      store: store,
      handler: handler,
      content: content,
      native: native,
      api: api,
      connectivity: connectivity,
      speech: speech,
      billing: billing,
      ads: ads,
      account: account,
      links: links,
      share: share,
      permissions: permissions,
      config: AppConfig(forcedPlan: plan, browseDebounce: const Duration(milliseconds: 60)),
      now: () => now,
      random: Random(7),
    );
    model.events.listen(events.add);
    await model.init();
    await settle();
    return model;
  }

  /// Events are delivered asynchronously (broadcast stream): let them arrive first.
  Future<List<T>> got<T extends AppEvent>() async {
    await Future<void>.delayed(Duration.zero);
    return events.whereType<T>().toList();
  }
}

Future<http.Response> Function(http.Request) _voiceBackend(int status, Object body) => (request) async {
      if (request.url.path == '/v1/installations') {
        return http.Response(jsonEncode({'installation_id': 'i', 'token': 't'}), 201);
      }
      if (request.url.path == '/v1/voice') return http.Response(jsonEncode(body), status);
      return http.Response(jsonEncode({'error': 'not_found'}), 404);
    };

void main() {
  late Harness h;

  setUp(() => h = Harness());

  group('playback', () {
    test('opens on the default free landscape and plays its default mix', () async {
      final model = await h.start();
      expect(model.scene.landscapeId, 'cascade-foret');
      expect(model.browsedLandscapeLocked, isFalse);
      await model.play();
      expect(model.playing, isTrue);
      expect(h.engine.activeKeys, {'son:eau-vive', 'son:oiseaux', 'son:vent'});
      expect(h.engine.volumeOf('son:eau-vive'), closeTo(0.6, 1e-9));
      expect(model.timerEndsAt, h.now.add(const Duration(hours: 1)));
      await model.togglePlay();
      expect(model.playing, isFalse);
      await model.togglePlay();
      expect(model.playing, isTrue);
      expect(h.engine.calls, ['start', 'pause', 'resume']);
    });

    test('free user offline: « Hors connexion », nothing starts', () async {
      h.connectivity.online = false;
      final model = await h.start();
      await model.play();
      expect((await h.got<OfflineEvent>()), hasLength(1));
      expect(h.engine.calls, isEmpty);
      expect(model.online, isFalse);
      h.connectivity.online = true;
      expect(await model.retryConnection(), isTrue);
      expect(model.online, isTrue);
    });

    test('Premium plays offline', () async {
      h.connectivity.online = false;
      final model = await h.start(plan: Plan.annual);
      await model.play();
      expect(model.playing, isTrue);
    });

    test('timer change while playing restarts the countdown', () async {
      final model = await h.start();
      await model.play();
      model.setTimer(const TimerDuration(15));
      expect(model.scene.timer, const TimerDuration(15));
      expect(model.timerEndsAt, h.now.add(const Duration(minutes: 15)));
      model.setTimer(const TimerNone());
      expect(model.timerEndsAt, isNull);
    });

    test('black screen setting opens standby when playback starts with a timer', () async {
      final model = await h.start(plan: Plan.annual);
      await model.updateSettings(model.settings.copyWith(blackScreenDuringTimer: true));
      model.handleLifecycle(AppLifecycleState.resumed);
      await settle();
      await model.play();
      expect((await h.got<OpenStandbyEvent>()), hasLength(1));
    });
  });

  group('landscapes and mix', () {
    test('browsing: image at once, sound after the pause, locked landscapes only seen', () async {
      final model = await h.start();
      await model.play();
      model.browseLandscape('sous-bois');
      expect(model.browsedLandscapeId, 'sous-bois');
      expect(model.scene.landscapeId, 'cascade-foret');
      await settle(150);
      expect(model.scene.landscapeId, 'sous-bois');
      expect(h.engine.activeKeys, {'son:vent', 'son:oiseaux'});
      expect(h.engine.lastFade, MixRules.crossFade);
      expect(model.lastLandscapeOfTheme('nature'), 'sous-bois');

      model.browseLandscape('berge-mousseuse');
      expect(model.browsedLandscapeLocked, isTrue);
      await settle(150);
      expect(model.scene.landscapeId, 'sous-bois', reason: 'the current sound keeps playing');
      expect(model.playing, isTrue);
    });

    test('quick successive swipes load only the last landscape', () async {
      final model = await h.start(plan: Plan.annual);
      model.browseLandscape('berge-mousseuse');
      await settle(20);
      model.browseLandscape('torrent-montagne');
      await settle(150);
      expect(model.scene.landscapeId, 'torrent-montagne');
    });

    test('choosing a locked landscape opens Premium', () async {
      final model = await h.start();
      model.selectLandscape('aurore-boreale');
      expect((await h.got<OpenPremiumEvent>()), hasLength(1));
      expect(model.scene.landscapeId, 'cascade-foret');
      model.selectLandscape('sous-bois');
      expect(model.scene.landscapeId, 'sous-bois');
      expect(model.scene.sounds.map((l) => l.id), ['vent', 'oiseaux']);
      expect(model.lastLandscapeOfTheme('astral'), 'ciel-etoile');
    });

    test('mix: locked item → Premium, beyond 6 layers → message, levels follow while playing', () async {
      final model = await h.start();
      await model.play();
      model.setLayerLevel(LayerKind.son, 'vagues', 50);
      expect((await h.got<OpenPremiumEvent>()), hasLength(1));
      model.setLayerLevel(LayerKind.son, 'pluie-douce', 40);
      model.setLayerLevel(LayerKind.son, 'ruisseau', 40);
      model.setLayerLevel(LayerKind.musique, 'piano-doux', 30);
      expect(model.scene.audioLayerCount, 6);
      model.setLayerLevel(LayerKind.musique, 'nappes-apaisantes', 30);
      expect((await h.got<ToastEvent>()).single.message, contains('6 sons au maximum'));
      model.setLayerLevel(LayerKind.son, 'eau-vive', 80);
      await settle();
      expect(h.engine.volumeOf('son:eau-vive'), closeTo(0.8, 1e-9));
      expect(h.engine.volumeOf('musique:piano-doux'), closeTo(0.24, 1e-9));
      model.setLayerLevel(LayerKind.son, 'eau-vive', 0);
      await settle();
      expect(h.engine.activeKeys.contains('son:eau-vive'), isFalse);
      // Decor is visual only.
      model.setLayerLevel(LayerKind.decor, 'lucioles', 50);
      await settle();
      expect(h.engine.activeKeys.any((k) => k.startsWith('decor:')), isFalse);
    });
  });

  group('favorites', () {
    test('toggle, then the free limit of 3 opens Premium', () async {
      final model = await h.start();
      await model.toggleFavorite();
      expect(model.isCurrentSceneFavorite, isTrue);
      expect((await h.got<ToastEvent>()).last.message, AppMessages.addedToFavorites);
      model.setMoment(Moment.nuit);
      expect(model.isCurrentSceneFavorite, isTrue, reason: 'the light is not part of the mix');
      await model.toggleFavorite();
      expect(model.favorites, isEmpty);
      for (final id in ['pluie-douce', 'ruisseau', 'piano-doux']) {
        model.setLayerLevel(id == 'piano-doux' ? LayerKind.musique : LayerKind.son, id, 30);
        await model.toggleFavorite();
      }
      expect(model.favorites, hasLength(3));
      model.setLayerLevel(LayerKind.son, 'pluie-douce', 70);
      await model.toggleFavorite();
      expect(model.favorites, hasLength(3));
      expect((await h.got<OpenPremiumEvent>()), hasLength(1));
      model.applyFavorite(model.favorites.first);
      expect(model.scene.levelOf(LayerKind.son, 'pluie-douce'), 30);
      model.removeFavorite(model.favorites.first.id);
      expect(model.favorites, hasLength(2));
    });
  });

  group('schedules', () {
    test('free: one schedule synced natively with the landscape name; the second opens Premium', () async {
      final model = await h.start();
      final draft = model.newScheduleDraft();
      expect(draft.hour, 22);
      expect(draft.rampMinutes, 10);
      expect(await model.saveSchedule(draft), isTrue);
      final payload = h.native.lastPayload;
      expect(payload['requires_network'], isTrue);
      final synced = (payload['schedules'] as List).single as Map;
      expect(synced['heure'], '22:00');
      expect(synced['paysage_nom'], 'Cascade en forêt');
      expect(synced['jours'], [1, 2, 3, 4, 5, 6, 7]);
      expect(model.nextScheduledStart, DateTime(2026, 10, 28, 22));
      expect(await model.saveSchedule(model.newScheduleDraft()), isFalse);
      expect((await h.got<OpenPremiumEvent>()), hasLength(1));
      await model.setScheduleActive(draft.id, false);
      expect(h.native.lastPayload['schedules'], isEmpty);
      expect(model.nextScheduledStart, isNull);
      await model.deleteSchedule(draft.id);
      expect(model.schedules, isEmpty);
    });

    test('Premium: unlimited, offline allowed', () async {
      final model = await h.start(plan: Plan.annual);
      expect(await model.saveSchedule(model.newScheduleDraft()), isTrue);
      expect(await model.saveSchedule(model.newScheduleDraft().copyWith(hour: 13, minute: 30)), isTrue);
      expect(h.native.lastPayload['schedules'], hasLength(2));
      expect(h.native.lastPayload['requires_network'], isFalse);
      expect(model.nextScheduledStart, DateTime(2026, 10, 28, 22));
    });

    test('scheduled start: the landscape of the schedule ramps up with the reminder text', () async {
      final model = await h.start();
      final schedule = model.newScheduleDraft().copyWith(landscapeId: 'sous-bois', rampMinutes: 15);
      await model.saveSchedule(schedule);
      h.native.pendingStart = schedule.id;
      await h.handler.click();
      await settle();
      expect(model.playing, isTrue);
      expect(model.scene.landscapeId, 'sous-bois');
      expect(h.engine.lastRampUp, const Duration(minutes: 15));
      expect(h.handler.mediaItem.value?.artist, 'C’est l’heure d’aller dormir');
      expect(h.handler.mediaItem.value?.title, 'Sous-bois ensoleillé');
    });

    test('scheduled start of a free user without network: « Pas de connexion » notification', () async {
      final model = await h.start();
      final schedule = model.newScheduleDraft();
      await model.saveSchedule(schedule);
      h.connectivity.online = false;
      h.native.pendingStart = schedule.id;
      await h.handler.click();
      await settle();
      expect(model.playing, isFalse);
      expect(h.engine.calls, isEmpty);
      expect(h.native.noConnectionNotifications, 1);
    });

    test('« Lancer » on the fallback notification starts the pending schedule', () async {
      final model = await h.start();
      final schedule = model.newScheduleDraft().copyWith(reminder: Reminder.detente);
      await model.saveSchedule(schedule);
      h.native.pendingStart = schedule.id;
      h.native.requestLaunch();
      await settle();
      expect(model.playing, isTrue);
      expect(h.handler.mediaItem.value?.artist, 'C’est l’heure de vous détendre');
    });

    test('a scheduled « dormir » start opens a night when tracking is on', () async {
      final model = await h.start();
      await model.setSleepTracking(true);
      final schedule = model.newScheduleDraft();
      await model.saveSchedule(schedule);
      h.native.pendingStart = schedule.id;
      await h.handler.click();
      await settle();
      h.now = h.now.add(const Duration(hours: 8));
      await model.leaveStandby();
      expect(model.sleepStats.lastNight?.duration, const Duration(hours: 8));
    });
  });

  group('voice (no backend: rules only)', () {
    test('« pause » is heard at once, « Annuler » restores the exact previous state', () async {
      final model = await h.start();
      await model.play();
      await model.startVoice();
      expect(model.voiceState, isA<VoiceListening>());
      expect(h.speech.usedLocale, 'fr_BE');
      h.speech.partial('pau');
      h.speech.level(0.5);
      final listening = model.voiceState as VoiceListening;
      expect(listening.partialText, 'pau');
      expect(listening.soundLevel, 0.5);
      h.speech.finalOnStop = 'Pause';
      await model.stopVoice();
      await settle();
      final result = model.voiceState as VoiceResult;
      expect(result.phrase, 'Pause');
      expect(result.changes.single.label, 'Lecture');
      expect(model.playing, isFalse);
      await model.undoVoice();
      expect(model.playing, isTrue);
      expect(model.voiceState, isA<VoiceIdle>());
    });

    test('settings and schedules changed by voice are undone too', () async {
      final model = await h.start(plan: Plan.annual);
      await model.startVoice();
      h.speech.finalResult('mets le texte plus grand');
      await settle();
      expect(model.settings.textSize, 1);
      expect(model.voiceState, isA<VoiceResult>());
      expect((model.voiceState as VoiceResult).quotaLabel, isNull);
      await model.undoVoice();
      expect(model.settings.textSize, 0);

      await model.startVoice();
      h.speech.finalResult('arrête dans une heure et demie');
      await settle();
      expect(model.scene.timer, const TimerDuration(90));
      model.keepVoice();
      expect(model.voiceState, isA<VoiceIdle>());
      expect(model.scene.timer, const TimerDuration(90));
    });

    test('not understood → rephrase; out of catalog → refused; nothing heard', () async {
      final model = await h.start();
      await model.startVoice();
      h.speech.finalResult('raconte-moi une histoire');
      await settle();
      expect(model.voiceState, isA<VoiceRephrase>());
      await model.startVoice();
      h.speech.finalResult('quelle heure est-il');
      await settle();
      expect(model.voiceState, isA<VoiceRefused>());
      await model.startVoice();
      h.speech.error('error_no_match');
      await settle();
      expect((model.voiceState as VoiceRephrase).phrase, '');
    });

    test('share by voice opens the Share screen', () async {
      final model = await h.start();
      await model.startVoice();
      h.speech.finalResult('partage mon mix');
      await settle();
      expect((await h.got<OpenShareEvent>()), hasLength(1));
      expect(model.voiceState, isA<VoiceResult>());
    });

    test('microphone not granted: explained error, nothing recorded', () async {
      h.permissions.granted[PermissionKind.microphone] = false;
      final model = await h.start();
      await model.startVoice();
      expect(model.voiceState, isA<VoiceError>());
      expect(h.speech.listening, isFalse);
    });

    test('resetVoice cancels listening', () async {
      final model = await h.start();
      await model.startVoice();
      model.resetVoice();
      expect(h.speech.cancels, 1);
      expect(model.voiceState, isA<VoiceIdle>());
      h.speech.finalResult('pause');
      await settle();
      expect(model.voiceState, isA<VoiceIdle>());
    });
  });

  group('voice with backend', () {
    test('free trial used up → Premium screen', () async {
      final model = await h.start(backend: _voiceBackend(402, {'error': 'voice_quota_exhausted'}));
      await model.startVoice();
      h.speech.finalResult('pause');
      await settle();
      expect(model.voiceState, isA<VoiceRefused>());
      expect((await h.got<OpenPremiumEvent>()), hasLength(1));
      expect(model.entitlements.voice.trialRemaining, 0);
    });

    test('lifetime without credits → credits screen', () async {
      final model = await h.start(plan: Plan.lifetime, backend: _voiceBackend(402, {'error': 'voice_quota_exhausted'}));
      await model.startVoice();
      h.speech.finalResult('raconte-moi une histoire');
      await settle();
      expect((await h.got<OpenCreditsEvent>()), hasLength(1));
    });

    test('counted request shows the remaining trial', () async {
      final model = await h.start(
        backend: _voiceBackend(200, {
          'actions': [
            {'op': 'definir', 'cible': 'moment', 'valeur': 'nuit'},
          ],
          'source': 'model',
          'voice': {'mode': 'trial', 'trial_remaining': 2},
        }),
      );
      await model.startVoice();
      h.speech.finalResult('fais comme si c’était la nuit noire');
      await settle();
      final result = model.voiceState as VoiceResult;
      expect(result.quotaLabel, 'Essai gratuit · 2 demandes restantes');
      expect(model.scene.moment, Moment.nuit);
    });
  });

  group('sharing', () {
    test('without backend: self-contained link, share sheet and clipboard', () async {
      final model = await h.start();
      final link = await model.createShareLink();
      expect(link.host, 'eventide.app');
      expect(link.path, '/s');
      expect(sceneFromShareUri(link, h.catalog)?.landscapeId, 'cascade-foret');
      await model.shareMix();
      expect(h.share.shared.single, contains(link.toString()));
      expect(h.share.shared.single, contains('Cascade en forêt'));
      await model.copyShareLink();
      expect(h.share.copied.single, link.toString());
    });

    test('a free recipient sees Premium items locked and muted', () async {
      final model = await h.start();
      final shared = Scene(
        landscapeId: 'cascade-foret',
        sounds: const [Layer(id: 'eau-vive', level: 50), Layer(id: 'vagues', level: 40)],
      );
      h.links.open(shareLinkFor(shared, 'eventide.app'));
      await settle();
      expect((await h.got<SharedMixOpenedEvent>()).single.lockedItems, 1);
      expect(model.scene.hasLayer(LayerKind.son, 'vagues'), isTrue);
      await model.play();
      expect(h.engine.activeKeys, {'son:eau-vive'});

      final lockedLandscape = Scene(landscapeId: 'aurore-boreale');
      h.links.open(shareLinkFor(lockedLandscape, 'eventide.app'));
      await settle();
      expect(model.browsedLandscapeId, 'aurore-boreale');
      expect(model.browsedLandscapeLocked, isTrue);
      expect(model.scene.landscapeId, 'cascade-foret');
    });
  });

  group('sleep', () {
    test('« Commencer la nuit » with tracking: standby, sound, night recorded on wake after 3 h', () async {
      final model = await h.start();
      await model.setSleepTracking(true);
      await model.startNight();
      expect(model.playing, isTrue);
      expect((await h.got<OpenStandbyEvent>()), hasLength(1));
      h.now = h.now.add(const Duration(hours: 1));
      await model.leaveStandby();
      expect(model.sleepStats.lastNight, isNull);
      h.now = h.now.add(const Duration(hours: 6));
      await model.leaveStandby();
      expect(model.sleepStats.lastNight?.duration, const Duration(hours: 7));
    });

    test('tracking off: no night recorded', () async {
      final model = await h.start();
      await model.startNight();
      h.now = h.now.add(const Duration(hours: 8));
      await model.leaveStandby();
      expect(model.sleepStats.lastNight, isNull);
    });
  });

  group('purchases, ads, account', () {
    test('a verified purchase unlocks Premium and lifts the network requirement', () async {
      final model = await h.start();
      await model.saveSchedule(model.newScheduleDraft());
      expect(h.native.lastPayload['requires_network'], isTrue);
      h.billing.emit(EntitlementsChanged(entitlementsFor(Plan.annual)));
      await settle();
      expect(model.plan, Plan.annual);
      expect(h.native.lastPayload['requires_network'], isFalse);
      expect((await h.got<ToastEvent>()).last.message, AppMessages.premiumActive);
      expect(jsonDecode(h.store.files[StoreKeys.entitlements]!)['data']['plan'], 'annual');
      await model.buy(PurchaseChoice.annual);
      await model.buyCredits();
      expect(h.billing.calls, containsAll(['buy:annual', 'credits']));
    });

    test('free: interstitial at opening and at exit, capped; never during playback', () async {
      h.store.files[StoreKeys.settings] = jsonEncode({
        'version': 1,
        'data': const AppSettings(onboarded: true).toJson(),
      });
      final model = await h.start();
      model.handleLifecycle(AppLifecycleState.resumed);
      await settle();
      expect(h.ads.shown, [AdPlacement.open]);
      await model.beforeExit();
      expect(h.ads.shown, [AdPlacement.open, AdPlacement.exit]);
      await model.beforeExit();
      expect(h.ads.shown, hasLength(2));
      h.now = h.now.add(const Duration(hours: 5));
      await model.play();
      await model.beforeExit();
      expect(h.ads.shown, hasLength(2));
    });

    test('no ad before the welcome screen is done', () async {
      final model = await h.start();
      model.handleLifecycle(AppLifecycleState.resumed);
      await settle();
      await model.beforeExit();
      expect(h.ads.shown, isEmpty);
    });

    test('Premium: no ads at all', () async {
      final model = await h.start(plan: Plan.monthly);
      model.handleLifecycle(AppLifecycleState.resumed);
      await settle();
      await model.beforeExit();
      expect(h.ads.shown, isEmpty);
      expect(model.offers.first.choice, PurchaseChoice.annual);
    });

    test('exact alarm permission opens the settings screen', () async {
      h.native.exactAllowed = false;
      h.permissions.granted[PermissionKind.exactAlarm] = false;
      final model = await h.start();
      expect(model.exactAlarmAllowed, isFalse);
      expect(await model.requestPermission(PermissionKind.exactAlarm), isFalse);
      expect(h.permissions.requested, [PermissionKind.exactAlarm]);
    });

    test('data stays on the phone and survives a restart', () async {
      final model = await h.start();
      model.selectLandscape('sous-bois');
      await model.toggleFavorite();
      await model.saveSchedule(model.newScheduleDraft());
      await model.updateSettings(model.settings.copyWith(highContrast: true));
      await settle(500);
      model.dispose();
      final store = h.store;
      h = Harness()..store = store;
      final again = await h.start();
      expect(again.scene.landscapeId, 'sous-bois');
      expect(again.favorites, hasLength(1));
      expect(again.schedules, hasLength(1));
      expect(again.settings.highContrast, isTrue);
    });

    test('export then delete all data', () async {
      final model = await h.start();
      await model.completeOnboarding();
      await model.toggleFavorite();
      final export = jsonDecode(await model.exportData()) as Map<String, dynamic>;
      expect(export['telephone'][StoreKeys.favorites], hasLength(1));
      expect(export.containsKey('serveur'), isFalse);
      await model.deleteAccountData();
      expect(h.store.files, isEmpty);
      expect(model.favorites, isEmpty);
      expect(model.onboarded, isFalse);
      expect(model.settings, const AppSettings());
      expect(h.account.signOuts, 1);
      expect((await h.got<ToastEvent>()).last.message, AppMessages.dataDeleted);
    });

    test('a cached subscription works offline, until 7 days after its expiry', () async {
      final expired = Entitlements(
        plan: Plan.annual,
        premium: true,
        expiresAt: h.now.subtract(const Duration(days: 3)),
        voice: const VoiceQuota(mode: VoiceMode.included),
      );
      h.store.files[StoreKeys.entitlements] = jsonEncode({'version': 1, 'data': expired.toJson()});
      final model = await h.start();
      expect(model.plan, Plan.annual);
      h.now = h.now.add(const Duration(days: 5));
      expect(model.plan, Plan.free);
    });

    test('Google sign-in without backend only marks the account locally', () async {
      final model = await h.start();
      await model.signInWithGoogle();
      expect(model.signedIn, isTrue);
    });
  });
}
