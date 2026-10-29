import 'dart:math';

import 'package:eventide/core/catalog.dart';
import 'package:eventide/core/scene.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

void main() {
  final catalog = loadCatalog();

  test('reads every list of the real catalog', () {
    expect(catalog.version, 1);
    expect(catalog.themes.map((t) => t.id), ['nature', 'urbain', 'astral']);
    expect(catalog.themes.first.name, 'Nature');
    expect(catalog.landscapes, hasLength(12));
    expect(catalog.sounds, hasLength(13));
    expect(catalog.music, hasLength(8));
    expect(catalog.decors, hasLength(9));
  });

  test('limits', () {
    final l = catalog.limits;
    expect(l.layersMax, 6);
    expect(l.freeFavorites, 3);
    expect(l.freeSchedules, 1);
    expect(l.freeAssistantTrials, 3);
    expect(l.rampMinutesMin, 15);
    expect(l.rampMinutesMax, 60);
    expect(l.nightMaxHours, 10);
    expect(Limits.fromJson(l.toJson()).toJson(), l.toJson());
  });

  test('landscape lookup and default mix', () {
    final cascade = catalog.landscape('cascade-foret')!;
    expect(cascade.name, 'Cascade en forêt');
    expect(cascade.themeId, 'nature');
    expect(cascade.free, isTrue);
    expect(cascade.style, 'cascade');
    expect(cascade.aliases, contains('cascade en forêt'));
    // Its ambiance (the sound of its video) first (contract § 11).
    expect(cascade.defaultMix[LayerKind.son], const [
      Layer(id: 'ambiance-cascade-foret', level: 60),
      Layer(id: 'oiseaux', level: 40),
      Layer(id: 'vent', level: 30),
    ]);
    // Every landscape starts with a soft melody (owner decision, 28 Oct. 2026).
    expect(cascade.defaultMix[LayerKind.musique], const [
      Layer(id: 'piano-doux', level: 20),
    ]);
    expect(cascade.defaultMix[LayerKind.decor], const [
      Layer(id: 'brume', level: 30),
    ]);
    expect(catalog.landscape('nope'), isNull);
  });

  test('only two landscapes are free, both in Nature', () {
    final free = catalog.landscapes.where((l) => l.free).map((l) => l.id);
    expect(free, ['cascade-foret', 'sous-bois']);
    expect(catalog.defaultLandscape.id, 'cascade-foret');
  });

  test('landscapesOfTheme keeps the swipe order', () {
    expect(catalog.landscapesOfTheme('nature').map((l) => l.id), [
      'cascade-foret',
      'sous-bois',
      'berge-mousseuse',
      'torrent-montagne',
      'pierres-eau',
      'lisiere-verte',
    ]);
    expect(catalog.landscapesOfTheme('astral').map((l) => l.id), [
      'ciel-etoile',
      'aurore-boreale',
      'lune-lac',
    ]);
    expect(catalog.landscapesOfTheme('unknown'), isEmpty);
    expect(catalog.theme('urbain')!.name, 'Urbain');
    expect(catalog.theme('x'), isNull);
  });

  test('items by kind', () {
    expect(catalog.item(LayerKind.son, 'pluie-douce')!.name, 'Pluie douce');
    expect(catalog.item(LayerKind.son, 'pluie-douce')!.free, isTrue);
    expect(catalog.item(LayerKind.son, 'tonnerre')!.free, isFalse);
    expect(
      catalog.item(LayerKind.musique, 'piano-doux')!.kind,
      LayerKind.musique,
    );
    expect(
      catalog.item(LayerKind.decor, 'brume')!.aliases,
      contains('brouillard'),
    );
    // An id exists only in its own list.
    expect(catalog.item(LayerKind.musique, 'pluie-douce'), isNull);
    expect(catalog.items(LayerKind.son), same(catalog.sounds));
    expect(catalog.items(LayerKind.musique), same(catalog.music));
    expect(catalog.items(LayerKind.decor), same(catalog.decors));
  });

  test('every default mix references catalog items', () {
    for (final l in catalog.landscapes) {
      expect(catalog.theme(l.themeId), isNotNull, reason: l.id);
      for (final kind in LayerKind.values) {
        for (final layer in l.defaultMix[kind]!) {
          expect(
            catalog.item(kind, layer.id),
            isNotNull,
            reason: '${l.id}/${layer.id}',
          );
        }
      }
    }
  });

  test(
    'every landscape starts with one soft melody; free ones use free music',
    () {
      for (final l in catalog.landscapes) {
        final music = l.defaultMix[LayerKind.musique]!;
        expect(music, hasLength(1), reason: l.id);
        final melody = music.single;
        expect(melody.level, inInclusiveRange(10, 30), reason: l.id);
        final item = catalog.item(LayerKind.musique, melody.id)!;
        if (l.free) expect(item.free, isTrue, reason: '${l.id}/${melody.id}');
        final audio = l.defaultMix[LayerKind.son]!.length + music.length;
        expect(
          audio,
          lessThanOrEqualTo(catalog.limits.layersMax),
          reason: l.id,
        );
      }
    },
  );

  group('ambiances and sounds played by events (contract § 11)', () {
    test('each landscape ambiance belongs to its landscape and comes first', () {
      final ambiances = catalog.sounds.where((s) => s.isAmbiance).toList();
      expect(ambiances.map((s) => s.id), [
        'ambiance-cascade-foret',
        'ambiance-pluie-ville',
        'ambiance-toits-pluie',
      ]);
      for (final s in ambiances) {
        final landscape = catalog.landscape(s.landscapeId!)!;
        expect(s.free, landscape.free, reason: s.id);
        expect(s.playback, Playback.loop);
        expect(landscape.defaultMix[LayerKind.son]!.first.id, s.id);
        expect(catalog.ambianceOf(landscape.id), same(s));
      }
      expect(catalog.item(LayerKind.son, 'ambiance-pluie-ville')!.name, 'Ambiance de la ville');
      expect(catalog.ambianceOf('lune-lac'), isNull);
      expect(catalog.item(LayerKind.son, 'vent')!.landscapeId, isNull);
    });

    test('an ambiance is offered with its landscape only', () {
      final pluie = catalog.item(LayerKind.son, 'ambiance-pluie-ville')!;
      expect(pluie.offeredWith('pluie-ville'), isTrue);
      expect(pluie.offeredWith('cascade-foret'), isFalse);
      expect(catalog.item(LayerKind.son, 'vent')!.offeredWith('pluie-ville'), isTrue);
    });

    test('tonnerre is played by events, with its variants and ranges', () {
      final thunder = catalog.item(LayerKind.son, 'tonnerre')!;
      expect(thunder.playback, Playback.events);
      final events = thunder.events!;
      expect(events.variants, [for (var i = 1; i <= 10; i++) 'tonnerre-${i.toString().padLeft(2, '0')}']);
      expect(events.interval, const SecondsRange(120, 300));
      expect(events.firstDelay, const SecondsRange(45, 120));
      expect(() => events.variants.add('x'), throwsUnsupportedError);
      for (final s in catalog.sounds) {
        if (s.id != 'tonnerre') expect(s.events, isNull, reason: s.id);
      }
      // The storm landscapes: their ambiance, the thunder, the lightning decor.
      for (final id in ['pluie-ville', 'toits-pluie']) {
        final mix = catalog.landscape(id)!.defaultMix;
        expect(mix[LayerKind.son]!.map((l) => l.id), ['ambiance-$id', 'tonnerre'], reason: id);
        expect(mix[LayerKind.decor]!.map((l) => l.id), contains('eclairs'), reason: id);
      }
    });

    test('defaults and lenient parsing', () {
      CatalogItem parse(Map<String, dynamic> json) =>
          CatalogItem.fromJson({'id': 'orage', 'nom': 'Orage', 'gratuit': false, ...json}, LayerKind.son);
      expect(parse({}).playback, Playback.loop);
      expect(parse({'lecture': 'boucle'}).events, isNull);
      expect(parse({'paysage': ''}).landscapeId, isNull);
      final bare = parse({'lecture': 'evenements'}).events!;
      expect(bare.variants, ['orage'], reason: 'no variants: its own file');
      expect(bare.interval, EventSound.defaultInterval);
      expect(bare.firstDelay, EventSound.defaultFirstDelay);
      final odd = parse({
        'lecture': 'evenements',
        'variantes': ['a', 3, 'b'],
        'intervalle_s': [300, 120],
        'premier_s': [0, 10],
      }).events!;
      expect(odd.variants, ['a', 'b']);
      expect(odd.interval, EventSound.defaultInterval, reason: 'min > max');
      expect(odd.firstDelay, EventSound.defaultFirstDelay, reason: 'min must be > 0');
      expect(SecondsRange.fromJson([2, 2.5]), const SecondsRange(2, 2.5));
      expect(SecondsRange.fromJson([1]), isNull);
      // Music and decor are never played by events.
      expect(
        CatalogItem.fromJson({'id': 'x', 'nom': 'X', 'lecture': 'evenements'}, LayerKind.musique).events,
        isNull,
      );
    });

    test('SecondsRange.draw stays in the range', () {
      const range = SecondsRange(45, 120);
      final random = Random(3);
      for (var i = 0; i < 200; i++) {
        final d = range.draw(random).inMicroseconds / 1e6;
        expect(d, inInclusiveRange(45, 120));
      }
    });

    test('hasEventSound: thunder above level 0 in the scene', () {
      final pluie = Scene.fromLandscape(catalog.landscape('pluie-ville')!);
      expect(catalog.hasEventSound(pluie), isTrue);
      expect(catalog.hasEventSound(pluie.withoutLayer(LayerKind.son, 'tonnerre')), isFalse);
      expect(catalog.hasEventSound(Scene.fromLandscape(catalog.landscape('cascade-foret')!)), isFalse);
    });
  });

  test('LayerKind mapping', () {
    expect(LayerKind.son.cible, 'son');
    expect(LayerKind.son.sceneKey, 'sons');
    expect(LayerKind.son.catalogKey, 'sons');
    expect(LayerKind.musique.cible, 'musique');
    expect(LayerKind.musique.sceneKey, 'musique');
    expect(LayerKind.musique.catalogKey, 'musiques');
    expect(LayerKind.decor.cible, 'decor');
    expect(LayerKind.decor.catalogKey, 'decors');
    expect(LayerKind.fromCible('musique'), LayerKind.musique);
    expect(LayerKind.fromCible('paysage'), isNull);
    expect(LayerKind.fromCible(null), isNull);
    expect(LayerKind.decor.isAudio, isFalse);
    expect(LayerKind.son.label, 'Sons');
    expect(LayerKind.decor.label, 'Décor');
  });

  test('lists are immutable', () {
    expect(
      () => catalog.sounds.add(catalog.sounds.first),
      throwsUnsupportedError,
    );
    expect(() => catalog.landscapes.clear(), throwsUnsupportedError);
  });

  test('malformed catalog throws FormatException', () {
    expect(() => Catalog.fromJson({'themes': 'x'}), throwsFormatException);
    expect(
      () => Catalog.fromJson({
        'themes': [],
        'paysages': [
          {'id': 1},
        ],
        'sons': [],
        'musiques': [],
        'decors': [],
      }),
      throwsFormatException,
    );
  });
}
