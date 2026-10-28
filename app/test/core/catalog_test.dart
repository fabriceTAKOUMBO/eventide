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
    expect(catalog.sounds, hasLength(10));
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
    expect(cascade.defaultMix[LayerKind.son], const [
      Layer(id: 'eau-vive', level: 60),
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
