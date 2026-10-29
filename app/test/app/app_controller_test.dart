import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:audio_service/audio_service.dart';
import 'package:eventide/app/app_controller.dart';
import 'package:eventide/app/app_model.dart';
import 'package:eventide/app/demo_mode.dart';
import 'package:eventide/core/catalog.dart';
import 'package:eventide/core/landscape_media.dart';
import 'package:eventide/core/media_card.dart';
import 'package:eventide/core/plan.dart';
import 'package:eventide/core/scene.dart';
import 'package:eventide/core/schedule.dart';
import 'package:eventide/core/settings.dart';
import 'package:eventide/core/share_codec.dart';
import 'package:eventide/services/ads_service.dart';
import 'package:eventide/services/api_client.dart';
import 'package:eventide/services/audio/audio_engine.dart';
import 'package:eventide/services/audio/fake_audio_engine.dart';
import 'package:eventide/services/audio/media_artwork.dart';
import 'package:eventide/services/audio/media_card_controls.dart';
import 'package:eventide/services/audio/playback_handler.dart';
import 'package:eventide/services/billing_service.dart';
import 'package:eventide/services/content_repository.dart';
import 'package:eventide/services/storage.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../services/fakes.dart';

/// No audio device (headless emulator, broken audio HAL): the engine cannot start.
class _NoDeviceEngine extends FakeAudioEngine {
  @override
  Future<void> start(
    List<EngineLayer> layers, {
    Duration fadeIn = const Duration(seconds: 2),
    Duration rampUp = Duration.zero,
  }) async =>
      throw StateError('audio device unavailable');
}

class Harness {
  final Catalog catalog = loadTestCatalog();
  MemoryStore store = MemoryStore();
  final engine = FakeAudioEngine();
  final focus = FakeFocus();
  final native = FakeNativeBridge();
  final connectivity = FakeConnectivity();
  final billing = FakeBilling();
  final ads = FakeAds();
  final account = FakeAccount();
  final links = FakeLinks();
  final share = FakeShare();
  final permissions = FakePermissions();
  final urls = FakeUrlOpener();
  final events = <AppEvent>[];
  DateTime now = DateTime(2026, 10, 28, 21);
  late PlaybackHandler handler;
  late RealAppModel model;

  Future<RealAppModel> start({
    Plan? plan,
    Future<http.Response> Function(http.Request)? backend,
    String shareHost = 'eventide.app',
    bool demo = false,
    AudioEngine? engineOverride,
    Set<String> bundledMedia = const {},
    Set<String> notBundled = const {},
    RemoteLandscapeMedia remoteMedia = RemoteLandscapeMedia.none,
    Directory? contentDirectory,
    MediaArtwork? artwork,
    bool safeStart = false,
  }) async {
    handler = PlaybackHandler(engine: engineOverride ?? engine, focus: focus, native: native, now: () => now);
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
      directory: contentDirectory ?? Directory('/nonexistent/eventide-content'),
      client: client,
      api: api,
      bundledAssets: () async => {...allBundledAudio(catalog), ...bundledMedia}.difference(notBundled),
      connectivity: connectivity,
      remoteMedia: () async => remoteMedia,
    );
    model = RealAppModel(
      catalog: catalog,
      store: store,
      handler: handler,
      content: content,
      native: native,
      api: api,
      connectivity: connectivity,
      billing: billing,
      ads: ads,
      account: account,
      links: links,
      share: share,
      permissions: permissions,
      urls: urls,
      config: AppConfig(
        shareHost: shareHost,
        forcedPlan: plan,
        browseDebounce: const Duration(milliseconds: 60),
        demo: demo,
        safeStart: safeStart,
      ),
      artwork: artwork,
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
      expect(h.engine.activeKeys, {'son:ambiance-cascade-foret', 'son:oiseaux', 'son:vent', 'musique:piano-doux'});
      expect(h.engine.volumeOf('son:ambiance-cascade-foret'), closeTo(0.6, 1e-9));
      // The default melody (20 %) sits under the sounds (music gain 0.8).
      expect(h.engine.volumeOf('musique:piano-doux'), closeTo(0.16, 1e-9));
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
      model.browseLandscape('foret-lucioles');
      expect(model.browsedLandscapeId, 'foret-lucioles');
      expect(model.scene.landscapeId, 'cascade-foret');
      await settle(150);
      expect(model.scene.landscapeId, 'foret-lucioles');
      expect(h.engine.activeKeys, {'son:ruisseau', 'son:vent', 'musique:nappes-apaisantes'});
      expect(h.engine.lastFade, MixRules.crossFade);
      expect(model.lastLandscapeOfTheme('imaginaire'), 'foret-lucioles');

      model.browseLandscape('lac-lune');
      expect(model.browsedLandscapeLocked, isTrue);
      await settle(150);
      expect(model.scene.landscapeId, 'foret-lucioles', reason: 'the current sound keeps playing');
      expect(model.playing, isTrue);
    });

    test('quick successive swipes load only the last landscape', () async {
      final model = await h.start(plan: Plan.annual);
      model.browseLandscape('lac-lune');
      await settle(20);
      model.browseLandscape('aurore');
      await settle(150);
      expect(model.scene.landscapeId, 'aurore');
    });

    test('choosing a locked landscape opens Premium', () async {
      final model = await h.start();
      model.selectLandscape('aurore');
      expect((await h.got<OpenPremiumEvent>()), hasLength(1));
      expect(model.scene.landscapeId, 'cascade-foret');
      model.selectLandscape('foret-lucioles');
      expect(model.scene.landscapeId, 'foret-lucioles');
      expect(model.scene.sounds.map((l) => l.id), ['ruisseau', 'vent']);
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
      model.setLayerLevel(LayerKind.son, 'ambiance-cascade-foret', 80);
      await settle();
      expect(h.engine.volumeOf('son:ambiance-cascade-foret'), closeTo(0.8, 1e-9));
      expect(h.engine.volumeOf('musique:piano-doux'), closeTo(0.24, 1e-9));
      model.setLayerLevel(LayerKind.son, 'ambiance-cascade-foret', 0);
      await settle();
      expect(h.engine.activeKeys.contains('son:ambiance-cascade-foret'), isFalse);
      // Decor never applies to a filmed landscape (contract § 12).
      model.setLayerLevel(LayerKind.decor, 'lucioles', 50);
      expect(model.scene.decor, isEmpty);
      // On a 3D scene: its own decor only, and it is visual only.
      model.selectLandscape('foret-lucioles');
      model.setLayerLevel(LayerKind.decor, 'lucioles', 50);
      model.setLayerLevel(LayerKind.decor, 'neige', 50);
      expect(model.scene.decor, [const Layer(id: 'lucioles', level: 50), const Layer(id: 'brume', level: 30)]);
      await settle();
      expect(h.engine.activeKeys.any((k) => k.startsWith('decor:')), isFalse);
    });

    test('decor applies to a 3D scene only, for its own elements (contract § 12)', () async {
      final model = await h.start(plan: Plan.annual);
      model.selectLandscape('jardin-zen');
      expect(model.scene.decor.map((l) => l.id), ['petales', 'rayons-soleil']);
      model.setLayerLevel(LayerKind.decor, 'pluie', 40);
      model.setLayerLevel(LayerKind.decor, 'etoiles', 40); // not in this scene
      expect(model.scene.decor.map((l) => l.id), ['petales', 'rayons-soleil', 'pluie']);
      // A filmed landscape loads no decor; the mix keeps its sounds.
      model.selectLandscape('pluie-ville');
      expect(model.scene.decor, isEmpty);
      model.setLayerLevel(LayerKind.decor, 'brume', 40);
      expect(model.scene.decor, isEmpty);
      // Back to a 3D scene: its default decor.
      model.selectLandscape('aurore');
      expect(model.scene.decor.map((l) => l.id), ['etoiles', 'neige']);
    });
  });

  group('sourdine (mute) and the progressive melody', () {
    test('muting music fades it to 0 over 1 s, keeps its level, unmuting restores it', () async {
      final model = await h.start();
      await model.play();
      expect(h.engine.volumeOf('musique:piano-doux'), closeTo(0.16, 1e-9));
      model.setCategoryMuted(LayerKind.musique, true);
      expect(model.musicMuted, isTrue);
      expect(model.categoryMuted(LayerKind.musique), isTrue);
      expect(model.soundsMuted, isFalse);
      await settle();
      // Still loaded (parked by the engine), silent; the sounds go on.
      expect(h.engine.activeKeys, contains('musique:piano-doux'));
      expect(h.engine.parkedKeys, {'musique:piano-doux'});
      expect(h.engine.lastFade, MixRules.muteFade);
      expect(h.engine.volumeOf('son:ambiance-cascade-foret'), closeTo(0.6, 1e-9));
      expect(model.scene.levelOf(LayerKind.musique, 'piano-doux'), 20);
      expect(model.playing, isTrue);

      model.setCategoryMuted(LayerKind.musique, false);
      await settle();
      expect(h.engine.volumeOf('musique:piano-doux'), closeTo(0.16, 1e-9));
      expect(h.engine.parkedKeys, isEmpty);
      expect(h.engine.lastFade, MixRules.muteFade);
      // Unmuting is not a new entry: no 20 s fade.
      expect(h.engine.calls.where((c) => c == 'start'), hasLength(1));
    });

    test('everything muted: silent but still playing (timer, video); a fresh start unmutes', () async {
      final model = await h.start();
      await model.play();
      final endsAt = model.timerEndsAt;
      model.setCategoryMuted(LayerKind.son, true);
      model.setCategoryMuted(LayerKind.musique, true);
      await settle();
      expect(model.scene.fullyMuted, isTrue);
      expect(h.engine.parkedKeys, h.engine.activeKeys);
      expect(model.playing, isTrue, reason: 'muting is not pausing');
      expect(model.timerEndsAt, endsAt, reason: 'the timer keeps running');
      // A pause and a resume keep the mute.
      await model.pause();
      await model.play();
      expect(model.playing, isTrue);
      expect(model.scene.fullyMuted, isTrue);
      // Stop, then Play from silence: a start is never silent.
      await h.handler.stop();
      await model.play();
      expect(model.playing, isTrue);
      expect(model.soundsMuted || model.musicMuted, isFalse);
      expect(h.engine.parkedKeys, isEmpty);
      expect(h.engine.volumeOf('son:ambiance-cascade-foret'), closeTo(0.6, 1e-9));
    });

    test('a muted category with the other one audible still starts muted', () async {
      final model = await h.start();
      model.setCategoryMuted(LayerKind.musique, true);
      await model.play();
      expect(model.musicMuted, isTrue);
      expect(h.engine.activeKeys, contains('musique:piano-doux'));
      expect(h.engine.parkedKeys, {'musique:piano-doux'});
    });

    test('moving a level of a muted category unmutes it (1 s fade); removing does not', () async {
      final model = await h.start();
      await model.play();
      model.setCategoryMuted(LayerKind.musique, true);
      await settle();
      model.setLayerLevel(LayerKind.musique, 'piano-doux', 0);
      expect(model.musicMuted, isTrue);
      model.setLayerLevel(LayerKind.musique, 'piano-doux', 30);
      expect(model.musicMuted, isFalse);
      await settle();
      expect(h.engine.lastFade, MixRules.muteFade);
      expect(h.engine.volumeOf('musique:piano-doux'), closeTo(0.24, 1e-9));
      // Same level as stored, but muted: touching it still unmutes.
      model.setCategoryMuted(LayerKind.son, true);
      model.setLayerLevel(LayerKind.son, 'vent', 30);
      expect(model.soundsMuted, isFalse);
      // The decor has no mute.
      model.setCategoryMuted(LayerKind.decor, true);
      expect(model.categoryMuted(LayerKind.decor), isFalse);
    });

    test('the mute is saved with the scene and survives a restart', () async {
      final model = await h.start();
      model.setCategoryMuted(LayerKind.musique, true);
      await settle(500);
      final saved = jsonDecode(h.store.files[StoreKeys.scene]!) as Map<String, dynamic>;
      expect((saved['data'] as Map)['sourdine'], {'sons': false, 'musique': true});
      model.dispose();
      final store = h.store;
      h = Harness()..store = store;
      final again = await h.start();
      expect(again.musicMuted, isTrue);
      expect(again.scene.levelOf(LayerKind.musique, 'piano-doux'), 20);
    });

    test('the mute stays across a landscape change; favorites and shares never carry it', () async {
      final model = await h.start();
      model.setCategoryMuted(LayerKind.musique, true);
      model.selectLandscape('foret-lucioles');
      expect(model.scene.music, const [Layer(id: 'nappes-apaisantes', level: 20)]);
      expect(model.musicMuted, isTrue);
      await model.toggleFavorite();
      expect(model.favorites.single.scene.mutedMusic, isFalse);
      // Applying a favorite keeps the current listening state.
      model.setCategoryMuted(LayerKind.musique, false);
      model.setCategoryMuted(LayerKind.son, true);
      model.applyFavorite(model.favorites.single);
      expect(model.soundsMuted, isTrue);
      expect(model.musicMuted, isFalse);
      // A share link carries no mute, and opening one gives the audible mix.
      final link = await model.createShareLink();
      expect(utf8.decode(base64Url.decode(base64Url.normalize(link.fragment))), isNot(contains('sourdine')));
      h.links.open(link);
      await settle();
      expect(model.soundsMuted || model.musicMuted, isFalse);
    });

    test('the melody comes in over 20 s at a start and a landscape change, the sounds faster', () async {
      final model = await h.start();
      await model.play();
      expect(h.engine.entryFades['musique:piano-doux'], MixRules.musicEntry);
      expect(h.engine.entryFades['son:ambiance-cascade-foret'], const Duration(seconds: 2));
      // Every music layer comes back over 3 s after a pause; the sounds follow the master.
      final music = h.engine.layers.firstWhere((l) => l.key == 'musique:piano-doux');
      final sound = h.engine.layers.firstWhere((l) => l.key == 'son:ambiance-cascade-foret');
      expect(music.resumeFade, MixRules.musicResume);
      expect(sound.resumeFade, isNull);

      model.selectLandscape('foret-lucioles');
      await settle();
      expect(h.engine.entryFades['musique:nappes-apaisantes'], MixRules.musicEntry);
      expect(h.engine.lastFade, MixRules.crossFade);
      // « vent » was already playing: it only glides.
      expect(h.engine.entryFades['son:vent'], const Duration(seconds: 2));

      // A melody added by hand comes in at once (1 s), not over 20 s.
      model.setLayerLevel(LayerKind.musique, 'piano-doux', 30);
      await settle();
      expect(h.engine.entryFades['musique:piano-doux'], MixRules.newLayerFade);
    });

    test('a scheduled start ramps up the master and brings the melody in over 20 s, never silent', () async {
      final model = await h.start();
      model.setCategoryMuted(LayerKind.son, true);
      model.setCategoryMuted(LayerKind.musique, true);
      final schedule = model.newScheduleDraft().copyWith(landscapeId: 'foret-lucioles', rampMinutes: 15);
      await model.saveSchedule(schedule);
      h.native.pendingStart = schedule.id;
      await h.handler.click();
      await settle();
      expect(model.playing, isTrue);
      expect(h.engine.lastRampUp, const Duration(minutes: 15));
      expect(h.engine.entryFades['musique:nappes-apaisantes'], MixRules.musicEntry);
      expect(model.soundsMuted || model.musicMuted, isFalse);
      expect(h.engine.parkedKeys, isEmpty);
    });

    test('a scheduled start keeps a partial mute (music off at night stays off)', () async {
      final model = await h.start();
      model.setCategoryMuted(LayerKind.musique, true);
      final schedule = model.newScheduleDraft().copyWith(landscapeId: 'foret-lucioles');
      await model.saveSchedule(schedule);
      h.native.pendingStart = schedule.id;
      await h.handler.click();
      await settle();
      expect(model.playing, isTrue);
      expect(model.musicMuted, isTrue);
      expect(h.engine.parkedKeys, {'musique:nappes-apaisantes'});
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
      final schedule = model.newScheduleDraft().copyWith(landscapeId: 'foret-lucioles', rampMinutes: 15);
      await model.saveSchedule(schedule);
      h.native.pendingStart = schedule.id;
      await h.handler.click();
      await settle();
      expect(model.playing, isTrue);
      expect(model.scene.landscapeId, 'foret-lucioles');
      expect(h.engine.lastRampUp, const Duration(minutes: 15));
      final item = h.handler.mediaItem.value!;
      expect(item.title, 'Forêt aux lucioles');
      // The card's subtitle is the audible mix; the reminder is the notification's third line.
      expect(item.artist, 'Ruisseau · Vent · Nappes apaisantes');
      expect(item.displayDescription, 'C’est l’heure d’aller dormir');
      expect(item.displayTitle, 'Forêt aux lucioles');
      expect(item.displaySubtitle, 'Ruisseau · Vent · Nappes apaisantes');
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
      expect(h.handler.mediaItem.value?.displayDescription, 'C’est l’heure de vous détendre');
      expect(h.handler.mediaItem.value?.artist, 'Ambiance de la cascade · Oiseaux · Vent · Piano doux');
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

      final lockedLandscape = Scene(landscapeId: 'aurore');
      h.links.open(shareLinkFor(lockedLandscape, 'eventide.app'));
      await settle();
      expect(model.browsedLandscapeId, 'aurore');
      expect(model.browsedLandscapeLocked, isTrue);
      expect(model.scene.landscapeId, 'cascade-foret');
    });

    test('a link naming a retired landscape opens on Cascade en forêt, sounds and music kept', () async {
      final model = await h.start(plan: Plan.annual);
      model.setTimer(const TimerDuration(30));
      h.links.open(Uri.parse(
        'https://eventide.app/s#${base64Url.encode(utf8.encode(jsonEncode({
          'version': 1,
          'paysage': 'lisiere-verte',
          'moment': 'soir',
          'sons': [{'id': 'vent', 'niveau': 40}],
          'musique': [{'id': 'guitare-douce', 'niveau': 20}],
          'decor': [{'id': 'feuilles', 'niveau': 30}],
        }))).replaceAll('=', '')}',
      ));
      await settle();
      expect(model.scene.landscapeId, 'cascade-foret');
      expect(model.scene.sounds, const [Layer(id: 'vent', level: 40)]);
      expect(model.scene.music, const [Layer(id: 'guitare-douce', level: 20)]);
      expect(model.scene.decor, isEmpty, reason: 'a filmed landscape has no decor');
      expect(model.scene.timer, const TimerDuration(30), reason: 'the recipient keeps their timer');
    });

    test('a shared 3D scene keeps only the decor it can show', () async {
      final model = await h.start(plan: Plan.annual);
      final shared = Scene(
        landscapeId: 'ondes',
        sounds: const [Layer(id: 'vagues', level: 30)],
        decor: const [Layer(id: 'etoiles', level: 40), Layer(id: 'neige', level: 50)],
      );
      h.links.open(shareLinkFor(shared, 'eventide.app'));
      await settle();
      expect(model.scene.landscapeId, 'ondes');
      expect(model.scene.decor, const [Layer(id: 'etoiles', level: 40)]);
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
      expect(h.billing.calls, contains('buy:annual'));
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
      model.selectLandscape('foret-lucioles');
      await model.toggleFavorite();
      await model.saveSchedule(model.newScheduleDraft());
      await model.updateSettings(model.settings.copyWith(highContrast: true));
      await settle(500);
      model.dispose();
      final store = h.store;
      h = Harness()..store = store;
      final again = await h.start();
      expect(again.scene.landscapeId, 'foret-lucioles');
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

  group('crash guard (docs/app/architecture.md § 19)', () {
    /// A session that ends on a 3D scene (ondes, Imaginaire) after visiting pluie-ville
    /// (Urbain), with a favourite, a schedule and a setting, all saved; then the app is started
    /// again.
    Future<RealAppModel> restartAfterOndes({required bool safeStart}) async {
      final model = await h.start(plan: Plan.annual);
      await model.toggleFavorite();
      await model.saveSchedule(model.newScheduleDraft().copyWith(landscapeId: 'foret-lucioles'));
      await model.updateSettings(model.settings.copyWith(wifiOnly: true, textSize: 2));
      model.selectLandscape('pluie-ville');
      model.browseLandscape('ondes');
      await settle(600);
      expect(model.scene.landscapeId, 'ondes');
      model.dispose();
      final store = h.store;
      h = Harness()..store = store;
      return h.start(plan: Plan.annual, safeStart: safeStart);
    }

    test('without a crash, the app opens where it was left', () async {
      final again = await restartAfterOndes(safeStart: false);
      expect(again.scene.landscapeId, 'ondes');
      expect(again.lastLandscapeOfTheme('imaginaire'), 'ondes');
      expect(again.lastLandscapeOfTheme('urbain'), 'pluie-ville');
    });

    test('safe start: back on Cascade en forêt, landscapes per theme forgotten; favourites, schedules and settings kept', () async {
      final again = await restartAfterOndes(safeStart: true);
      expect(again.scene.landscapeId, 'cascade-foret');
      expect(again.browsedLandscapeId, 'cascade-foret');
      expect(again.scene.sounds.map((l) => l.id), contains('ambiance-cascade-foret'));
      expect(again.scene.decor, isEmpty);
      expect(again.lastLandscapeOfTheme('nature'), 'cascade-foret');
      expect(again.lastLandscapeOfTheme('imaginaire'), 'foret-lucioles');
      expect(again.favorites, hasLength(1));
      expect(again.schedules.single.landscapeId, 'foret-lucioles');
      expect(again.settings.wifiOnly, isTrue);
      expect(again.settings.textSize, 2);
      // Written at once: a new crash right away does not bring the 3D scene back.
      expect(jsonDecode(h.store.files[StoreKeys.scene]!)['data']['paysage'], 'cascade-foret');
      expect(jsonDecode(h.store.files[StoreKeys.appState]!)['data']['last_landscape_by_theme'], isEmpty);
    });

    test('the card picture is looked up for the landscape the sound follows, not for each one swiped past', () async {
      final lookups = <String>[];
      final files = MemoryArtworkFiles()..files['/content/images/paysages/mer-nuages.jpg'] = Uint8List(1);
      final artwork = MediaArtwork(
        files: files,
        bundledAssets: () async => const {'assets/landscapes/foret-lucioles.jpg'},
        loadAsset: (asset) async {
          lookups.add(asset);
          return Uint8List.fromList([1]);
        },
        downloadedPoster: (id) {
          lookups.add(id);
          return '/content/images/paysages/$id.jpg';
        },
      );
      final model = await h.start(plan: Plan.annual, artwork: artwork);
      model.selectLandscape('foret-lucioles');
      await model.play();
      await settle(150);
      expect(lookups, ['assets/landscapes/foret-lucioles.jpg']);
      expect(h.handler.mediaItem.value!.artUri!.toFilePath(), startsWith('/cache/media_art/foret-lucioles-'));
      // Swiping down Imaginaire quickly, to Mer de nuages where the user stays.
      for (final id in ['lac-lune', 'aurore', 'jardin-zen', 'mer-nuages']) {
        model.browseLandscape(id);
        expect(h.handler.mediaItem.value!.title, model.catalog.landscape(id)!.name, reason: 'the card follows at once');
        await settle(20);
      }
      expect(lookups, hasLength(1), reason: 'no picture looked up while swiping');
      await settle(200);
      expect(model.scene.landscapeId, 'mer-nuages');
      expect(lookups.last, 'mer-nuages');
      expect(h.handler.mediaItem.value!.artUri, Uri.file('/content/images/paysages/mer-nuages.jpg'));
    });

    test('saved data naming a retired landscape opens on Cascade en forêt (contract § 12)', () async {
      final retired = Scene(
        landscapeId: 'lisiere-verte',
        moment: Moment.soir,
        sounds: const [Layer(id: 'vent', level: 40)],
        music: const [Layer(id: 'guitare-douce', level: 20)],
        decor: const [Layer(id: 'feuilles', level: 30)],
        timer: const TimerDuration(45),
      );
      h.store.files[StoreKeys.scene] = jsonEncode({'version': 1, 'data': retired.toJson()});
      h.store.files[StoreKeys.favorites] = jsonEncode({
        'version': 1,
        'data': [Favorite(id: 'f1', scene: retired.copyWith(landscapeId: 'aurore-boreale'), createdAt: h.now).toJson()],
      });
      final schedule = Schedule(
        id: 's1',
        hour: 22,
        minute: 0,
        days: Schedule.everyDay,
        rampMinutes: 10,
        landscapeId: 'lune-lac',
        reminder: Reminder.dormir,
        active: true,
      );
      h.store.files[StoreKeys.schedules] = jsonEncode({'version': 1, 'data': [schedule.toJson()]});
      final model = await h.start(plan: Plan.annual);
      expect(model.scene.landscapeId, 'cascade-foret');
      expect(model.scene.sounds, const [Layer(id: 'vent', level: 40)]);
      expect(model.scene.music, const [Layer(id: 'guitare-douce', level: 20)]);
      expect(model.scene.decor, isEmpty);
      expect(model.scene.timer, const TimerDuration(45));
      expect(model.scene.moment, Moment.soir);
      expect(model.favorites.single.landscapeId, 'cascade-foret');
      expect(model.favorites.single.scene.decor, isEmpty);
      expect(model.schedules.single.landscapeId, 'cascade-foret');
      expect(model.nextScheduledStart, isNotNull, reason: 'the schedule is still armed');
      // Applying the favourite loads its sounds on the default landscape.
      model.selectLandscape('ondes');
      model.applyFavorite(model.favorites.single);
      expect(model.scene.landscapeId, 'cascade-foret');
      expect(model.scene.sounds, const [Layer(id: 'vent', level: 40)]);
    });
  });

  group('hints, permissions and outgoing pages', () {
    test('a hint stays seen after a restart, until the data is deleted', () async {
      final model = await h.start();
      expect(model.hintSeen('home_swipe'), isFalse);
      await model.markHintSeen('home_swipe');
      expect(model.hintSeen('home_swipe'), isTrue);
      expect(jsonDecode(h.store.files[StoreKeys.appState]!)['data']['hints_seen'], ['home_swipe']);
      model.dispose();
      final store = h.store;
      h = Harness()..store = store;
      final again = await h.start();
      expect(again.hintSeen('home_swipe'), isTrue);
      expect(again.hintSeen('other'), isFalse);
      await again.deleteAccountData();
      expect(again.hintSeen('home_swipe'), isFalse);
    });

    test('permanently denied: known at launch, cleared from the settings, and after a request', () async {
      h.permissions.granted[PermissionKind.notifications] = false;
      h.permissions.deniedForever.add(PermissionKind.notifications);
      final model = await h.start();
      expect(model.permissionPermanentlyDenied(PermissionKind.notifications), isTrue);
      expect(model.permissionPermanentlyDenied(PermissionKind.exactAlarm), isFalse);

      await model.openAppSettings();
      expect(h.permissions.settingsOpened, 1);

      // Granted in Android's settings: read again when the app comes back.
      model.handleLifecycle(AppLifecycleState.resumed);
      await settle();
      model.handleLifecycle(AppLifecycleState.paused);
      h.permissions.granted[PermissionKind.notifications] = true;
      h.permissions.deniedForever.remove(PermissionKind.notifications);
      model.handleLifecycle(AppLifecycleState.resumed);
      await settle();
      expect(model.permissionGranted(PermissionKind.notifications), isTrue);
      expect(model.permissionPermanentlyDenied(PermissionKind.notifications), isFalse);

      // Turned off again, then refused with « Ne plus demander » at the next request.
      h.permissions.granted[PermissionKind.notifications] = false;
      h.permissions.deniedForever.add(PermissionKind.notifications);
      expect(await model.requestPermission(PermissionKind.notifications), isFalse);
      expect(model.permissionGranted(PermissionKind.notifications), isFalse);
      expect(model.permissionPermanentlyDenied(PermissionKind.notifications), isTrue);
    });

    test('Google Play subscriptions and the privacy policy open outside the app', () async {
      final model = await h.start(plan: Plan.annual);
      await model.openManageSubscription();
      await model.openPrivacyPolicy();
      expect(h.urls.opened.map((u) => u.toString()), [
        'https://play.google.com/store/account/subscriptions?sku=eventide_premium&package=be.cinaf.eventide',
        'https://eventide.app/confidentialite',
      ]);
      expect(await h.got<ToastEvent>(), isEmpty);

      // Nothing can open links: say where to go instead.
      h.urls.succeeds = false;
      await model.openManageSubscription();
      await model.openPrivacyPolicy();
      expect((await h.got<ToastEvent>()).map((e) => e.message), [
        AppMessages.openPlayManually,
        AppMessages.openPageManually(Uri.parse('https://eventide.app/confidentialite')),
      ]);
    });

    test('the privacy policy follows SHARE_HOST', () async {
      final model = await h.start(shareHost: 'ambiances.example');
      await model.openPrivacyPolicy();
      expect(h.urls.opened.single.toString(), 'https://ambiances.example/confidentialite');
    });

    test('battery guide and ad choices reach the services', () async {
      final model = await h.start();
      await model.openBatteryGuide();
      await model.openAdPrivacyOptions();
      expect(h.native.batteryGuides, 1);
      expect(h.ads.privacyForms, 1);
    });
  });
  group('audio output unavailable', () {
    test('play: the sound cannot start, the model says so and stays usable', () async {
      final model = await h.start(engineOverride: _NoDeviceEngine());
      await model.play();
      expect(model.playing, isFalse);
      expect(model.loadingAudio, isFalse);
      expect((await h.got<ToastEvent>()).single.message, AppMessages.cannotStart);
      model.setLayerLevel(LayerKind.son, 'pluie-douce', 40);
      expect(model.scene.hasLayer(LayerKind.son, 'pluie-douce'), isTrue);
    });
  });

  group('demo build (Premium unlocked on the phone)', () {
    test('entitlements are forced to annual, whatever is cached; the server is never asked', () async {
      h.store.files[StoreKeys.entitlements] = jsonEncode({'version': 1, 'data': Entitlements.free().toJson()});
      final asked = <String>[];
      final model = await h.start(
        demo: true,
        backend: (request) async {
          asked.add(request.url.path);
          if (request.url.path == '/v1/entitlements') {
            return http.Response(jsonEncode(Entitlements.free().toJson()), 200);
          }
          return http.Response(jsonEncode({'error': 'not_found'}), 404);
        },
      );
      model.handleLifecycle(AppLifecycleState.resumed);
      await settle();
      expect(model.demoMode, isTrue);
      expect(model.plan, Plan.annual);
      expect(model.entitlements.premium, isTrue);
      expect(asked, isNot(contains('/v1/entitlements')));
      await model.retryConnection();
      await model.restorePurchases();
      await settle();
      expect(asked, isNot(contains('/v1/entitlements')));
      expect(model.plan, Plan.annual);
    });

    test('no purchase, no restore, no Google Play page: the demo explains itself', () async {
      final model = await h.start(demo: true);
      await model.buy(PurchaseChoice.monthly);
      await model.restorePurchases();
      await model.openManageSubscription();
      expect(h.billing.calls.where((c) => c != 'initialize'), isEmpty);
      expect(h.urls.opened, isEmpty);
      final toasts = [for (final t in await h.got<ToastEvent>()) t.message];
      expect(toasts, [
        DemoMode.premiumActive,
        DemoMode.nothingToRestore,
        DemoMode.premiumActive,
      ]);
      expect(await h.got<OpenPremiumEvent>(), isEmpty);
    });

    test('no ads, even onboarded and online', () async {
      h.store.files[StoreKeys.settings] = jsonEncode({'version': 1, 'data': const AppSettings(onboarded: true).toJson()});
      final model = await h.start(demo: true);
      model.handleLifecycle(AppLifecycleState.resumed);
      await settle();
      await model.beforeExit();
      expect(h.ads.shown, isEmpty);
    });

    test('Premium landscapes and sounds play offline from bundled audio', () async {
      h.connectivity.online = false;
      final model = await h.start(demo: true);
      model.selectLandscape('aurore');
      expect(model.scene.landscapeId, 'aurore');
      model.setLayerLevel(LayerKind.son, 'vagues', 40);
      expect(model.scene.hasLayer(LayerKind.son, 'vagues'), isTrue);
      await model.play();
      expect(model.playing, isTrue);
      expect(h.engine.activeKeys, contains('son:vagues'));
      expect(await h.got<OpenPremiumEvent>(), isEmpty);
      expect(await h.got<OfflineEvent>(), isEmpty);
    });

    test('schedules: unlimited, armed without the network requirement', () async {
      final model = await h.start(demo: true);
      expect(await model.saveSchedule(model.newScheduleDraft()), isTrue);
      expect(await model.saveSchedule(model.newScheduleDraft()), isTrue);
      expect(model.schedules, hasLength(2));
      expect(h.native.lastPayload['requires_network'], isFalse);
      expect((h.native.lastPayload['schedules'] as List), hasLength(2));
    });

    test('a production build (demo off) keeps the normal plan and purchases', () async {
      final model = await h.start();
      expect(model.demoMode, isFalse);
      expect(model.plan, Plan.free);
      await model.buy(PurchaseChoice.annual);
      expect(h.billing.calls, ['initialize', 'buy:annual']);
    });
  });

  group('media card (lock screen, notification shade)', () {
    MediaCardInfo card() => h.model.mediaCard.value!;
    List<MediaAction> actions() => [for (final c in h.handler.playbackState.value.controls) c.action];

    test('free plan: landscape, audible mix (mute included), no neighbour in its theme', () async {
      final model = await h.start();
      expect(card().landscapeId, 'cascade-foret');
      expect(card().title, 'Cascade en forêt');
      expect(card().artist, 'Ambiance de la cascade · Oiseaux · Vent · Piano doux');
      expect(card().previousId, isNull);
      expect(card().nextId, isNull, reason: 'Cascade en forêt is alone in Nature');
      expect(card().favorite, isFalse);
      await model.play();
      final item = h.handler.mediaItem.value!;
      expect(item.title, 'Cascade en forêt');
      expect(item.artist, 'Ambiance de la cascade · Oiseaux · Vent · Piano doux');
      expect(item.album, 'Eventide');
      expect(item.duration, const Duration(hours: 1));
      expect(actions(), [MediaAction.pause, MediaAction.custom, MediaAction.custom]);
      expect(h.handler.playbackState.value.androidCompactActionIndices, [0]);
      model.setCategoryMuted(LayerKind.son, true);
      await settle();
      expect(h.handler.mediaItem.value!.artist, 'Piano doux');
      model.setCategoryMuted(LayerKind.musique, true);
      await settle();
      expect(h.handler.mediaItem.value!.artist, 'Son en sourdine');
    });

    test('free plan at the edge of what it can use: next omitted, a next tap does nothing', () async {
      final model = await h.start();
      model.selectLandscape('foret-lucioles');
      await model.play();
      await settle();
      expect(card().previousId, isNull);
      expect(card().nextId, isNull, reason: 'the other Imaginaire scenes are Premium');
      expect(actions(), [MediaAction.pause, MediaAction.custom, MediaAction.custom]);
      expect(h.handler.playbackState.value.androidCompactActionIndices, [0]);
      await h.handler.skipToNext();
      await settle(150);
      expect(model.scene.landscapeId, 'foret-lucioles');
      expect(model.browsedLandscapeId, 'foret-lucioles');
    });

    for (final demo in [false, true]) {
      test('${demo ? 'demo build' : 'Premium'}: every landscape of the theme, no wrap', () async {
        final model = await h.start(plan: demo ? null : Plan.annual, demo: demo);
        model.selectLandscape('foret-lucioles');
        await settle();
        expect(card().previousId, isNull);
        expect(card().nextId, 'lac-lune');
        model.selectLandscape('ondes');
        await model.play();
        await settle();
        expect(card().previousId, 'mer-nuages');
        expect(card().nextId, isNull);
        expect(actions(), [MediaAction.skipToPrevious, MediaAction.pause, MediaAction.custom, MediaAction.custom]);
        expect(h.handler.playbackState.value.androidCompactActionIndices, [1]);
        model.selectLandscape('pluie-ville');
        await settle();
        expect(card().previousId, isNull);
        expect(card().nextId, 'toits-pluie');
        expect(actions(), [MediaAction.pause, MediaAction.skipToNext, MediaAction.custom, MediaAction.custom]);
      });
    }

    test('next from the card: shown at once, the sound follows after the browse pause (home swipe path)', () async {
      final model = await h.start(plan: Plan.annual);
      model.selectLandscape('foret-lucioles');
      await model.play();
      await settle();
      await h.handler.skipToNext();
      expect(model.browsedLandscapeId, 'lac-lune', reason: 'the home screen (and its scene) follows');
      expect(h.handler.mediaItem.value!.title, 'Lac sous la lune');
      expect(h.handler.mediaItem.value!.artist, 'Ruisseau · Chouette · Harpe');
      expect(model.scene.landscapeId, 'foret-lucioles', reason: 'the sound waits for the browse pause');
      expect(h.engine.activeKeys, contains('son:vent'));
      await settle(150);
      expect(model.scene.landscapeId, 'lac-lune');
      expect(h.engine.activeKeys, {'son:ruisseau', 'son:chouette', 'musique:harpe'});
      expect(h.engine.lastFade, MixRules.crossFade);
      expect(h.engine.entryFades['musique:harpe'], MixRules.musicEntry);
      expect(card().previousId, 'foret-lucioles');
      await h.handler.skipToPrevious();
      await settle(150);
      expect(model.scene.landscapeId, 'foret-lucioles');
      expect(model.playing, isTrue);
    });

    test('quick taps: the card moves at each tap, the sound loads only the last landscape', () async {
      final model = await h.start(plan: Plan.annual);
      model.selectLandscape('foret-lucioles');
      await model.play();
      await settle();
      final updates = h.engine.calls.where((c) => c == 'update').length;
      await h.handler.skipToNext();
      await h.handler.skipToNext();
      expect(h.handler.mediaItem.value!.title, 'Aurore boréale');
      await settle(150);
      expect(model.scene.landscapeId, 'aurore');
      expect(h.engine.calls.where((c) => c == 'update'), hasLength(updates + 1));
    });

    test('heart from the card: quiet toggle; at the free limit nothing happens', () async {
      final model = await h.start();
      await model.play();
      h.events.clear();
      await h.handler.customAction(MediaCardActions.favorite);
      expect(model.favorites, hasLength(1));
      expect(card().favorite, isTrue);
      expect(h.handler.playbackState.value.controls[1].androidIcon, MediaCardIcons.favorite);
      await h.handler.customAction(MediaCardActions.favorite);
      expect(model.favorites, isEmpty);
      expect(card().favorite, isFalse);
      expect(await h.got<ToastEvent>(), isEmpty);
      // Three favourites (the free limit) of other mixes, from the app.
      for (final level in [10, 20, 30]) {
        model.setLayerLevel(LayerKind.son, 'ambiance-cascade-foret', level);
        await model.toggleFavorite();
      }
      model.setLayerLevel(LayerKind.son, 'ambiance-cascade-foret', 45);
      await settle();
      h.events.clear();
      await h.handler.customAction(MediaCardActions.favorite);
      expect(model.favorites, hasLength(3));
      expect(model.isCurrentSceneFavorite, isFalse);
      expect(card().favorite, isFalse);
      expect(await h.got<OpenPremiumEvent>(), isEmpty, reason: 'the app shows Premium when opened');
      expect(await h.got<ToastEvent>(), isEmpty);
    });

    test('heart during a pending next: for the landscape the card shows', () async {
      final model = await h.start(plan: Plan.annual);
      model.selectLandscape('foret-lucioles');
      await model.play();
      await settle();
      await h.handler.skipToNext();
      await h.handler.customAction(MediaCardActions.favorite);
      expect(model.scene.landscapeId, 'lac-lune');
      expect(model.favorites.single.landscapeId, 'lac-lune');
      expect(card().favorite, isTrue);
    });

    test('timer from the card: 1 h → 2 h → night → none → 15 min → 30 min → 1 h, counted from zero', () async {
      final model = await h.start();
      await model.play();
      expect(model.scene.timer, const TimerDuration(60));
      final seen = <(TimerSetting, Duration?, DateTime?)>[];
      for (var i = 0; i < 6; i++) {
        h.now = h.now.add(const Duration(minutes: 3));
        await h.handler.customAction(MediaCardActions.timer);
        seen.add((model.scene.timer, h.handler.mediaItem.value!.duration, model.timerEndsAt));
        expect(h.handler.playbackState.value.updatePosition, Duration.zero);
        expect(h.handler.playbackState.value.controls.last.label, mediaCardTimerLabel(model.scene.timer));
      }
      final t = h.now;
      expect(seen.map((s) => s.$1), const [
        TimerDuration(120),
        TimerNight(),
        TimerNone(),
        TimerDuration(15),
        TimerDuration(30),
        TimerDuration(60),
      ]);
      expect(seen.map((s) => s.$2), const [
        Duration(hours: 2),
        Duration(hours: 10),
        null,
        Duration(minutes: 15),
        Duration(minutes: 30),
        Duration(hours: 1),
      ]);
      expect(seen.last.$3, t.add(const Duration(hours: 1)));
      expect(seen[2].$3, isNull);
    });

    test('picture: card first without it, then the landscape poster; never made while silent', () async {
      final files = MemoryArtworkFiles();
      final slowAsset = Completer<void>();
      final artwork = MediaArtwork(
        files: files,
        bundledAssets: () async => {'assets/landscapes/cascade-foret.jpg'},
        loadAsset: (asset) async {
          await slowAsset.future;
          return Uint8List.fromList([1, 2, 3]);
        },
        downloadedPoster: (id) => '/content/images/paysages/$id.jpg',
      );
      final model = await h.start(plan: Plan.annual, artwork: artwork);
      model.setMoment(Moment.soir);
      await settle();
      expect(files.writes, isEmpty, reason: 'nothing plays: no card, no picture');
      final items = <MediaItem>[];
      final sub = h.handler.mediaItem.where((i) => i != null).cast<MediaItem>().listen(items.add);
      await model.play();
      await settle();
      expect(model.playing, isTrue, reason: 'playback never waits for the picture');
      expect(h.handler.mediaItem.value!.title, 'Cascade en forêt');
      expect(h.handler.mediaItem.value!.artUri, isNull);
      slowAsset.complete();
      await settle();
      expect(items.first.artUri, isNull);
      final poster = items.last.artUri!;
      expect(poster.scheme, 'file');
      expect(poster.path, startsWith('/cache/media_art/cascade-foret-'));
      // A landscape whose poster is not on the phone yet: no picture (nothing is drawn).
      model.selectLandscape('jardin-zen');
      await settle();
      expect(h.handler.mediaItem.value!.title, 'Jardin zen');
      expect(h.handler.mediaItem.value!.artUri, isNull);
      // Downloaded since (Premium): it comes with the next session.
      files.files['/content/images/paysages/jardin-zen.jpg'] = Uint8List(1);
      await model.pause();
      await h.handler.stop();
      await settle();
      await model.play();
      await settle();
      expect(h.handler.mediaItem.value!.artUri, Uri.file('/content/images/paysages/jardin-zen.jpg'));
      await sub.cancel();
    });

    test('pause and play from the card change the sound only', () async {
      final model = await h.start();
      await model.play();
      model.setMoment(Moment.nuit);
      final before = (model.browsedLandscapeId, model.scene);
      await h.handler.click(); // card play/pause
      expect(model.playing, isFalse);
      await h.handler.click();
      expect(model.playing, isTrue);
      expect((model.browsedLandscapeId, model.scene), before);
      expect(h.engine.calls, ['start', 'pause', 'resume']);
    });
  });

  group('living landscapes (videos and posters)', () {
    const pluie = RemoteLandscapeMedia(videos: {'pluie-ville'}, images: {'pluie-ville'});
    const bundledFree = {'assets/landscapes/cascade-foret.mp4', 'assets/landscapes/cascade-foret.jpg'};

    Future<http.Response> Function(http.Request) contentBackend(List<String> asked) => (request) async {
          asked.add(request.url.toString());
          if (request.url.path == '/v1/installations') {
            return http.Response(jsonEncode({'installation_id': 'i', 'token': 't'}), 201);
          }
          if (request.url.path == '/v1/content/urls') {
            final keys = (jsonDecode(request.body) as Map)['keys'] as List;
            return http.Response(jsonEncode({
              'urls': {for (final k in keys) k: 'https://cdn.test/$k?sig=1'},
              'expires_at': '2026-10-28T22:00:00Z',
            }), 200);
          }
          if (request.url.host == 'cdn.test') return http.Response('MEDIA', 200);
          return http.Response(jsonEncode({'error': 'not_found'}), 404);
        };

    test('free plan: the bundled free video; nothing asked for a locked Premium landscape', () async {
      final asked = <String>[];
      final model = await h.start(backend: contentBackend(asked), bundledMedia: bundledFree, remoteMedia: pluie);
      expect(await model.landscapeVideo('cascade-foret'),
          const AssetLandscapeVideo('assets/landscapes/cascade-foret.mp4'));
      expect(await model.landscapeVideo('pluie-ville'), isNull);
      expect(model.landscapePosterFile('pluie-ville'), isNull);
      expect(asked.where((u) => u.contains('content/urls') || u.contains('cdn.test')), isEmpty);
    });

    test('Premium: the poster first (the UI is told), then the video, kept for next time', () async {
      final dir = await Directory.systemTemp.createTemp('eventide_media_');
      addTearDown(() => dir.delete(recursive: true));
      final asked = <String>[];
      final model = await h.start(
        plan: Plan.annual,
        backend: contentBackend(asked),
        bundledMedia: bundledFree,
        remoteMedia: pluie,
        contentDirectory: dir,
      );
      var notified = 0;
      model.addListener(() => notified++);
      final video = await model.landscapeVideo('pluie-ville');
      expect(video, isA<FileLandscapeVideo>());
      expect(File((video as FileLandscapeVideo).path).readAsStringSync(), 'MEDIA');
      expect(model.landscapePosterFile('pluie-ville'), endsWith('/images/paysages/pluie-ville.jpg'));
      expect(notified, greaterThan(0));
      final cdn = asked.where((u) => u.startsWith('https://cdn.test/')).toList();
      expect(cdn, [
        'https://cdn.test/images/paysages/pluie-ville.jpg?sig=1',
        'https://cdn.test/videos/paysages/pluie-ville.mp4?sig=1',
      ]);
      asked.clear();
      expect(await model.landscapeVideo('pluie-ville'), video);
      expect(asked, isEmpty);
    });

    test('« Wi-Fi seulement » on mobile data: no download, the still picture stays', () async {
      final asked = <String>[];
      final model = await h.start(plan: Plan.annual, backend: contentBackend(asked), remoteMedia: pluie);
      await model.updateSettings(model.settings.copyWith(wifiOnly: true));
      h.connectivity.unmetered = false;
      asked.clear();
      expect(await model.landscapeVideo('pluie-ville'), isNull);
      expect(asked, isEmpty);
    });

    test('demo build: Premium videos are bundled and play without any server', () async {
      final model = await h.start(
        demo: true,
        bundledMedia: {...bundledFree, 'assets/landscapes/pluie-ville.mp4', 'assets/landscapes/pluie-ville.jpg'},
      );
      expect(model.plan.isPremium, isTrue);
      expect(await model.landscapeVideo('pluie-ville'),
          const AssetLandscapeVideo('assets/landscapes/pluie-ville.mp4'));
    });

    test('the video never touches the sound', () async {
      final model = await h.start(bundledMedia: bundledFree);
      await model.play();
      await settle();
      expect(model.playing, isTrue);
      final calls = List.of(h.engine.calls);
      await model.landscapeVideo('cascade-foret');
      expect(model.playing, isTrue);
      expect(h.engine.calls, calls);
    });
  });

  group('storm: ambiance and thunder (contract § 11)', () {
    test('pluie-ville plays its ambiance and schedules the thunder, flashes announced to the UI', () async {
      final model = await h.start(plan: Plan.annual);
      model.selectLandscape('pluie-ville');
      await settle();
      await model.play();
      expect(model.playing, isTrue);
      expect(h.engine.activeKeys, {'son:ambiance-pluie-ville', 'musique:piano-doux'},
          reason: 'the thunder is not a loop');
      expect(h.engine.volumeOf('son:ambiance-pluie-ville'), closeTo(0.7, 1e-9));
      final events = h.handler.current!.events;
      expect(events.map((e) => e.key), ['son:tonnerre']);
      expect(events.single.volume, closeTo(0.5, 1e-9));
      expect(events.single.variants.map((v) => v.id), [
        for (var i = 1; i <= 10; i++) 'tonnerre-${i.toString().padLeft(2, '0')}',
      ]);
      expect(events.single.interval, const SecondsRange(70, 170));
      expect(events.single.firstDelay, const SecondsRange(20, 60));
      expect(
        await events.single.variants.first.resolve(),
        const AssetAudioSource('assets/audio/sons/tonnerre-01.ogg'),
      );
      expect(model.lightningStrikes, h.handler.lightningStrikes, reason: "the audio service's strikes");
      expect(model.catalog.hasEventSound(model.scene), isTrue);
    });

    test('muting the sounds or level 0 silences the thunder', () async {
      final model = await h.start(plan: Plan.annual);
      model.selectLandscape('pluie-ville');
      await settle();
      await model.play();
      model.setCategoryMuted(LayerKind.son, true);
      await settle();
      expect(h.handler.current!.events.single.volume, 0);
      expect(h.engine.calls, contains('eventVolume:son:tonnerre:0.00'));
      model.setCategoryMuted(LayerKind.son, false);
      await settle();
      expect(h.handler.current!.events.single.volume, closeTo(0.5, 1e-9));
      model.setLayerLevel(LayerKind.son, 'tonnerre', 0);
      await settle();
      expect(h.handler.current!.events, isEmpty);
    });

    test('the thunder alone still plays: a silent parked voice carries the session', () async {
      final model = await h.start(plan: Plan.annual);
      model.selectLandscape('pluie-ville');
      await settle();
      model.setLayerLevel(LayerKind.son, 'ambiance-pluie-ville', 0);
      model.setLayerLevel(LayerKind.musique, 'piano-doux', 0);
      await settle();
      await model.play();
      expect(model.playing, isTrue);
      expect(h.engine.activeKeys, {'carrier'});
      expect(h.engine.volumeOf('carrier'), 0);
      expect(h.handler.current!.events.single.key, 'son:tonnerre');
    });

    test('an ambiance the server does not have (test material) is left out without a message', () async {
      final model = await h.start(
        plan: Plan.annual,
        notBundled: {
          'assets/audio/sons/ambiance-toits-pluie.ogg',
          for (var i = 4; i <= 10; i++) 'assets/audio/sons/tonnerre-${i.toString().padLeft(2, '0')}.ogg',
        },
        remoteMedia: const RemoteLandscapeMedia(sounds: {'ambiance-pluie-ville', 'tonnerre-01'}),
      );
      model.selectLandscape('toits-pluie');
      await settle();
      h.events.clear();
      await model.play();
      expect(model.playing, isTrue);
      expect(h.engine.activeKeys, {'musique:cordes-lentes'});
      expect(await h.got<ToastEvent>(), isEmpty);
      expect(h.handler.current!.events.single.variants.map((v) => v.id), ['tonnerre-01', 'tonnerre-02', 'tonnerre-03'],
          reason: 'bundled or listed variants are kept, the others are left out');
    });
  });
}
