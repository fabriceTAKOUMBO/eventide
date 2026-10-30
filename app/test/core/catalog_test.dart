import 'dart:math';

import 'package:eventide/core/catalog.dart';
import 'package:eventide/core/lightning.dart';
import 'package:eventide/core/scene.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

void main() {
  final catalog = loadCatalog();

  test('reads every list of the real catalog', () {
    expect(catalog.version, 1);
    expect(catalog.themes.map((t) => t.id), ['nature', 'urbain', 'imaginaire']);
    expect(catalog.themes.first.name, 'Nature');
    expect(catalog.theme('imaginaire')!.name, 'Imaginaire');
    expect(catalog.landscapes, hasLength(10));
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
    expect(cascade.rendering, LandscapeRendering.video);
    expect(cascade.is3d, isFalse);
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
    // A filmed landscape: its decor is not editable, none by default (contract § 12).
    expect(cascade.defaultMix[LayerKind.decor], isEmpty);
    expect(cascade.decorIds, isEmpty);
    expect(catalog.landscape('nope'), isNull);
  });

  test('only two landscapes are free: Cascade en forêt (filmed) and Forêt aux lucioles (3D)', () {
    final free = catalog.landscapes.where((l) => l.free).map((l) => l.id);
    expect(free, ['cascade-foret', 'foret-lucioles']);
    expect(catalog.freeLandscapeCount, 2);
    expect(catalog.defaultLandscape.id, 'cascade-foret');
  });

  test('landscapesOfTheme keeps the swipe order', () {
    expect(catalog.landscapesOfTheme('nature').map((l) => l.id), ['cascade-foret', 'ciel-etoile']);
    expect(catalog.landscapesOfTheme('urbain').map((l) => l.id), ['pluie-ville', 'toits-pluie']);
    expect(catalog.landscapesOfTheme('imaginaire').map((l) => l.id), [
      'foret-lucioles',
      'lac-lune',
      'aurore',
      'jardin-zen',
      'mer-nuages',
      'ondes',
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
      expect(catalog.ambianceOf('lac-lune'), isNull);
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
      List<String> ids(String part, int n) => [for (var i = 1; i <= n; i++) 'tonnerre-$part-0$i'];
      final parts = {
        StormPart.avant: ids('avant', 3),
        StormPart.coup: ids('coup', 4),
        StormPart.coupProche: ids('proche', 3),
        StormPart.replique: ids('replique', 3),
        StormPart.lointain: ids('lointain', 4),
      };
      expect(events.variants, [for (final l in parts.values) ...l], reason: 'every file of the storm');
      expect(events.interval, const SecondsRange(70, 170));
      expect(events.firstDelay, const SecondsRange(20, 60));
      expect(() => events.variants.add('x'), throwsUnsupportedError);
      // Storm sequences from the real recording (contract § 11, `orage`).
      final storm = events.storm!;
      expect(storm.parts, parts);
      expect(storm.weights, {StormKind.lointain: 25.0, StormKind.orage: 55.0, StormKind.proche: 20.0});
      expect(storm.drawable, storm.weights);
      expect(storm.averse, ['ambiance-pluie-ville', 'ambiance-toits-pluie', 'pluie-douce']);
      expect(storm.rafale, ['vent']);
      for (final id in [...storm.averse, ...storm.rafale]) {
        final loop = catalog.item(LayerKind.son, id);
        expect(loop, isNotNull, reason: id);
        expect(loop!.events, isNull, reason: '$id is a loop');
      }
      expect(() => storm.parts[StormPart.coup]!.add('x'), throwsUnsupportedError);
      for (final s in catalog.sounds) {
        if (s.id != 'tonnerre') expect(s.events, isNull, reason: s.id);
      }
      // The storm landscapes: their ambiance, the thunder, and their own lightning (`eclairs`,
      // no longer a decor of the user, contract § 12).
      for (final id in ['pluie-ville', 'toits-pluie']) {
        final landscape = catalog.landscape(id)!;
        expect(landscape.defaultMix[LayerKind.son]!.map((l) => l.id), ['ambiance-$id', 'tonnerre'], reason: id);
        expect(landscape.defaultMix[LayerKind.decor], isEmpty, reason: id);
        expect(landscape.lightning, isTrue, reason: id);
      }
      expect(catalog.landscapes.where((l) => l.lightning).map((l) => l.id), ['pluie-ville', 'toits-pluie']);
      expect(catalog.item(LayerKind.decor, 'eclairs'), isNull);
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
      expect(odd.storm, isNull, reason: 'no `orage`: one variant per event');
      final storm = parse({
        'lecture': 'evenements',
        'variantes': ['a', 'b', 'c', 'd'],
        'orage': {
          'parties': {
            'coup': ['a', 'zz', 'a', 3],
            'coup-proche': [],
            'avant': 'b',
            'eclair': ['c'],
            'lointain': ['d'],
          },
          'sequences': {'orage': 2, 'proche': 1, 'lointain': 0, 'tempete': 4, 'variante': 1},
          'averse': ['pluie-douce', 7],
          'rafale': 'vent',
        },
      }).events!.storm!;
      expect(storm.parts, {
        StormPart.coup: ['a'],
        StormPart.lointain: ['d'],
      }, reason: 'unknown types, ids outside `variantes`, duplicates and empty lists are left out');
      expect(storm.weights, {StormKind.orage: 2.0, StormKind.proche: 1.0});
      expect(storm.drawable, {StormKind.orage: 2.0}, reason: 'no coup-proche part: proche is never drawn');
      expect(storm.averse, ['pluie-douce']);
      expect(storm.rafale, isEmpty);
      final empty = parse({'lecture': 'evenements', 'variantes': ['a', 'b', 'c'], 'orage': {}}).events!.storm!;
      expect(empty.drawable, isEmpty, reason: 'played as single variants');
      expect(parse({'lecture': 'evenements', 'orage': 'oui'}).events!.storm, isNull);
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

  group('filmed landscapes and 3D scenes (contract § 12)', () {
    test('six 3D scenes in Imaginaire, each with its decor, period and default mix', () {
      final scenes = catalog.landscapes.where((l) => l.is3d).toList();
      expect(scenes.map((l) => l.id), ['foret-lucioles', 'lac-lune', 'aurore', 'jardin-zen', 'mer-nuages', 'ondes']);
      for (final l in scenes) {
        expect(l.themeId, 'imaginaire', reason: l.id);
        expect(l.periodSeconds, 30, reason: l.id);
        expect(l.lightning, isFalse, reason: l.id);
        expect(l.decorIds, isNotEmpty, reason: l.id);
        for (final id in l.decorIds) {
          expect(catalog.item(LayerKind.decor, id), isNotNull, reason: '${l.id}/$id');
        }
        for (final layer in l.defaultMix[LayerKind.decor]!) {
          expect(l.allowsDecor(layer.id), isTrue, reason: '${l.id}/${layer.id}');
        }
      }
      final lucioles = catalog.landscape('foret-lucioles')!;
      expect(lucioles.free, isTrue);
      expect(lucioles.decorIds, ['lucioles', 'brume', 'pluie', 'etoiles']);
      expect(lucioles.defaultMix[LayerKind.son], const [Layer(id: 'ruisseau', level: 40), Layer(id: 'vent', level: 25)]);
      expect(lucioles.defaultMix[LayerKind.musique], const [Layer(id: 'nappes-apaisantes', level: 20)]);
      expect(lucioles.defaultMix[LayerKind.decor], const [Layer(id: 'lucioles', level: 60), Layer(id: 'brume', level: 30)]);
      // The free scene's default mix is free.
      for (final kind in LayerKind.values) {
        for (final layer in lucioles.defaultMix[kind]!) {
          expect(catalog.item(kind, layer.id)!.free, isTrue, reason: layer.id);
        }
      }
      expect(catalog.landscape('ondes')!.decorIds, ['etoiles', 'brume', 'pluie']);
    });

    test('filmed landscapes: no decor, no period', () {
      for (final l in catalog.landscapes.where((l) => !l.is3d)) {
        expect(l.decorIds, isEmpty, reason: l.id);
        expect(l.defaultMix[LayerKind.decor], isEmpty, reason: l.id);
        expect(l.periodSeconds, isNull, reason: l.id);
      }
      expect(catalog.landscapes.where((l) => !l.is3d).map((l) => l.id),
          ['cascade-foret', 'pluie-ville', 'toits-pluie', 'ciel-etoile']);
    });

    test('decor list: two free, Pétales, Pluie and Étoiles filantes added, Éclairs and Pluie sur l’écran gone', () {
      expect(catalog.decors.map((d) => d.id), [
        'brume',
        'lucioles',
        'rayons-soleil',
        'petales',
        'neige',
        'pluie',
        'etoiles',
        'etoiles-filantes',
        'oiseaux-vol',
      ]);
      expect(catalog.decors.where((d) => d.free).map((d) => d.id), ['brume', 'lucioles']);
      expect(catalog.item(LayerKind.decor, 'petales')!.name, 'Pétales');
      expect(catalog.item(LayerKind.decor, 'pluie-ecran'), isNull);
    });

    test('decorApplies and decorsOf: a 3D scene and its own elements only', () {
      expect(catalog.decorApplies('foret-lucioles', 'lucioles'), isTrue);
      expect(catalog.decorApplies('foret-lucioles', 'neige'), isFalse);
      expect(catalog.decorApplies('cascade-foret', 'brume'), isFalse);
      expect(catalog.decorApplies('nope', 'brume'), isFalse);
      expect(catalog.decorsOf('jardin-zen').map((d) => d.name), ['Pétales', 'Rayons de soleil', 'Brume', 'Pluie']);
      expect(catalog.decorsOf('pluie-ville'), isEmpty);
    });

    test('a retired landscape resolves to Cascade en forêt; an unknown one to nothing', () {
      for (final id in Catalog.retiredLandscapeIds) {
        expect(catalog.landscape(id), isNull, reason: id);
        expect(catalog.landscapeFor(id)!.id, 'cascade-foret', reason: id);
      }
      expect(Catalog.retiredLandscapeIds, hasLength(8));
      expect(catalog.landscapeFor('ondes')!.id, 'ondes');
      expect(catalog.landscapeFor('nulle-part'), isNull);
    });

    test('sanitize: retired landscape → default one with its sounds, music and timer; decor that does not apply dropped', () {
      final old = Scene(
        landscapeId: 'cafe-nuit',
        moment: Moment.nuit,
        sounds: const [Layer(id: 'pluie-douce', level: 25)],
        music: const [Layer(id: 'piano-doux', level: 25)],
        decor: const [Layer(id: 'pluie-ecran', level: 40)],
        timer: const TimerDuration(90),
        mutedMusic: true,
      );
      final sanitized = catalog.sanitize(old)!;
      expect(sanitized.landscapeId, 'cascade-foret');
      expect(sanitized.sounds, old.sounds);
      expect(sanitized.music, old.music);
      expect(sanitized.decor, isEmpty);
      expect(sanitized.timer, const TimerDuration(90));
      expect(sanitized.moment, Moment.nuit);
      expect(sanitized.mutedMusic, isTrue);
      // A 3D scene keeps its own decor only.
      final scene = Scene(
        landscapeId: 'lac-lune',
        decor: const [Layer(id: 'etoiles', level: 60), Layer(id: 'petales', level: 20), Layer(id: 'neige', level: 10)],
      );
      expect(catalog.sanitize(scene)!.decor, const [Layer(id: 'etoiles', level: 60), Layer(id: 'neige', level: 10)]);
      // Nothing to change: the same instance.
      final clean = Scene.fromLandscape(catalog.landscape('aurore')!);
      expect(catalog.sanitize(clean), same(clean));
      expect(catalog.sanitize(Scene(landscapeId: 'nulle-part')), isNull);
    });

    test('showing: landscapes the phone cannot show are left out, an empty theme is hidden', () {
      // Production without test material: toits-pluie and ciel-etoile have no media.
      final shown = catalog.showing((l) => l.is3d || {'cascade-foret', 'pluie-ville'}.contains(l.id));
      expect(shown.themes.map((t) => t.id), ['nature', 'urbain', 'imaginaire']);
      expect(shown.landscapesOfTheme('urbain').map((l) => l.id), ['pluie-ville']);
      expect(shown.landscape('ciel-etoile'), isNull);
      // A saved scene on a hidden landscape opens on the default one, like a retired one.
      expect(shown.landscapeFor('ciel-etoile')!.id, 'cascade-foret');
      expect(shown.landscapeFor('lisiere-verte')!.id, 'cascade-foret');
      // The default landscape is always kept; everything showable: the same catalog.
      expect(catalog.showing((l) => false).landscapes.map((l) => l.id), ['cascade-foret']);
      expect(catalog.showing((l) => true), same(catalog));
    });

    test('lenient parsing of the new fields', () {
      final l = Landscape.fromJson({
        'id': 'x',
        'theme': 'imaginaire',
        'nom': 'X',
        'rendu': '3d',
        'decors': ['brume', 'inconnu', 'brume', 3],
        'periode_s': 0,
        'mix': {
          'decor': [
            {'id': 'brume', 'niveau': 30},
            {'id': 'neige', 'niveau': 20},
          ],
        },
      }, knownDecors: {'brume', 'neige'});
      expect(l.is3d, isTrue);
      expect(l.decorIds, ['brume']);
      expect(l.periodSeconds, isNull);
      expect(l.defaultMix[LayerKind.decor], const [Layer(id: 'brume', level: 30)]);
      // A filmed landscape never has decor, whatever the file says.
      final filmed = Landscape.fromJson({
        'id': 'y',
        'theme': 'nature',
        'nom': 'Y',
        'decors': ['brume'],
        'eclairs': 'oui',
        'mix': {
          'decor': [
            {'id': 'brume', 'niveau': 30},
          ],
        },
      });
      expect(filmed.rendering, LandscapeRendering.video);
      expect(filmed.decorIds, isEmpty);
      expect(filmed.defaultMix[LayerKind.decor], isEmpty);
      expect(filmed.lightning, isFalse);
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
