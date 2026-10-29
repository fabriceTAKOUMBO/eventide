// Media card rules (lib/core/media_card.dart): subtitle of the audible mix, previous/next
// landscapes of the theme, timer button cycle and its French content descriptions.
import 'package:eventide/core/catalog.dart';
import 'package:eventide/core/media_card.dart';
import 'package:eventide/core/plan.dart';
import 'package:eventide/core/scene.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

void main() {
  final catalog = loadCatalog();
  final rules = ProductRules(catalog);
  Scene sceneOf(String id) => Scene.fromLandscape(catalog.landscape(id)!);
  bool freeUsable(Landscape l) => rules.canUseLandscape(Plan.free, l);
  bool premiumUsable(Landscape l) => rules.canUseLandscape(Plan.annual, l);

  group('mix summary (card subtitle)', () {
    test('sounds then music, in mix order, with the catalog names', () {
      expect(mixSummary(sceneOf('cascade-foret'), catalog), 'Ambiance de la cascade · Oiseaux · Vent · Piano doux');
      expect(mixSummary(sceneOf('sous-bois'), catalog), 'Vent · Oiseaux · Nappes apaisantes');
    });

    test('a muted category is left out; everything muted: « Son en sourdine »', () {
      final scene = sceneOf('cascade-foret');
      expect(mixSummary(scene.withMuted(LayerKind.son, true), catalog), 'Piano doux');
      expect(mixSummary(scene.withMuted(LayerKind.musique, true), catalog), 'Ambiance de la cascade · Oiseaux · Vent');
      final silent = scene.withMuted(LayerKind.son, true).withMuted(LayerKind.musique, true);
      expect(mixSummary(silent, catalog), mediaCardMutedSummary);
      expect(mediaCardMutedSummary, 'Son en sourdine');
    });

    test('music muted and no sound at all: nothing can be heard', () {
      final scene = Scene(
        landscapeId: 'cascade-foret',
        music: const [Layer(id: 'piano-doux', level: 30)],
        mutedMusic: true,
      );
      expect(mixSummary(scene, catalog), mediaCardMutedSummary);
    });

    test('layers at level 0, unknown ids and items locked for the plan are left out', () {
      final scene = Scene(
        landscapeId: 'cascade-foret',
        sounds: const [
          Layer(id: 'eau-vive', level: 0),
          Layer(id: 'vagues', level: 50), // Premium
          Layer(id: 'inconnu', level: 50),
          Layer(id: 'vent', level: 40),
        ],
        music: const [Layer(id: 'harpe', level: 20)], // Premium
      );
      bool free(LayerKind kind, String id) => rules.canUseItem(Plan.free, kind, id);
      expect(mixSummary(scene, catalog, canUse: free), 'Vent');
      expect(mixSummary(scene, catalog), 'Vagues · Vent · Harpe');
    });

    test('an empty mix has no subtitle', () {
      expect(mixSummary(Scene(landscapeId: 'cascade-foret'), catalog), isNull);
    });
  });

  group('previous / next landscape of the theme', () {
    test('free plan: locked landscapes are skipped, no wrap at the edges', () {
      expect(neighbourLandscape(catalog, 'cascade-foret', -1, freeUsable), isNull);
      expect(neighbourLandscape(catalog, 'cascade-foret', 1, freeUsable), 'sous-bois');
      expect(neighbourLandscape(catalog, 'sous-bois', -1, freeUsable), 'cascade-foret');
      // Every landscape after sous-bois in « Nature » is Premium.
      expect(neighbourLandscape(catalog, 'sous-bois', 1, freeUsable), isNull);
    });

    test('Premium: every landscape of the theme, still no wrap and never another theme', () {
      expect(neighbourLandscape(catalog, 'sous-bois', 1, premiumUsable), 'berge-mousseuse');
      expect(neighbourLandscape(catalog, 'lisiere-verte', 1, premiumUsable), isNull);
      expect(neighbourLandscape(catalog, 'lisiere-verte', -1, premiumUsable), 'pierres-eau');
      expect(neighbourLandscape(catalog, 'pluie-ville', -1, premiumUsable), isNull);
      expect(neighbourLandscape(catalog, 'toits-pluie', 1, premiumUsable), isNull);
      expect(neighbourLandscape(catalog, 'ciel-etoile', 1, premiumUsable), 'aurore-boreale');
    });

    test('unknown landscape or no direction: nothing', () {
      expect(neighbourLandscape(catalog, 'inconnu', 1, premiumUsable), isNull);
      expect(neighbourLandscape(catalog, 'cascade-foret', 0, premiumUsable), isNull);
    });
  });

  group('timer button', () {
    test('cycle: 15 min → 30 min → 1 h → 2 h → Toute la nuit → Sans minuteur → 15 min', () {
      var timer = mediaCardTimerCycle.last;
      final seen = <TimerSetting>[];
      for (var i = 0; i < mediaCardTimerCycle.length; i++) {
        timer = nextMediaCardTimer(timer);
        seen.add(timer);
      }
      expect(seen, mediaCardTimerCycle);
      expect(mediaCardTimerCycle, const [
        TimerDuration(15),
        TimerDuration(30),
        TimerDuration(60),
        TimerDuration(120),
        TimerNight(),
        TimerNone(),
      ]);
    });

    test('a duration outside the cycle goes to the next longer step', () {
      expect(nextMediaCardTimer(const TimerDuration(5)), const TimerDuration(15));
      expect(nextMediaCardTimer(const TimerDuration(45)), const TimerDuration(60));
      expect(nextMediaCardTimer(const TimerDuration(90)), const TimerDuration(120));
      expect(nextMediaCardTimer(const TimerDuration(180)), const TimerNight());
    });

    test('content descriptions in French: current state, then what a tap does', () {
      expect(mediaCardTimerLabel(const TimerDuration(15)), 'Minuteur 15 min. Toucher pour 30 min');
      expect(mediaCardTimerLabel(const TimerDuration(60)), 'Minuteur 1 h. Toucher pour 2 h');
      expect(mediaCardTimerLabel(const TimerDuration(120)), 'Minuteur 2 h. Toucher pour toute la nuit');
      expect(mediaCardTimerLabel(const TimerDuration(45)), 'Minuteur 45 min. Toucher pour 1 h');
      expect(mediaCardTimerLabel(const TimerNight()), 'Minuteur toute la nuit. Toucher pour l’enlever');
      expect(mediaCardTimerLabel(const TimerNone()), 'Sans minuteur. Toucher pour 15 min');
    });
  });

  test('card info: value equality, picture added without touching the rest', () {
    const card = MediaCardInfo(
      landscapeId: 'cascade-foret',
      title: 'Cascade en forêt',
      artist: 'Eau vive',
      nextId: 'sous-bois',
    );
    final art = Uri.file('/cache/media_art/cascade-foret.jpg');
    expect(card.hasPrevious, isFalse);
    expect(card.hasNext, isTrue);
    expect(card.withArt(art).artUri, art);
    expect(card.withArt(art).withArt(null), card);
    expect(card.withArt(art) == card, isFalse);
  });
}
