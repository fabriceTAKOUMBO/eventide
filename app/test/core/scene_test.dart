import 'dart:convert';

import 'package:eventide/core/catalog.dart';
import 'package:eventide/core/scene.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

void main() {
  final catalog = loadCatalog();

  // Contract §1 example.
  const contractJson = '''
{
  "version": 1,
  "paysage": "cascade-foret",
  "moment": "jour",
  "sons":    [{"id": "eau-vive", "niveau": 60}, {"id": "oiseaux", "niveau": 40}],
  "musique": [{"id": "piano-doux", "niveau": 25}],
  "decor":   [{"id": "brume", "niveau": 30}],
  "minuteur": {"mode": "duree", "minutes": 60},
  "sommeil": {"suivi": true}
}''';

  group('JSON', () {
    test('contract example round-trips', () {
      final json = jsonDecode(contractJson) as Map<String, dynamic>;
      final scene = Scene.fromJson(json);
      expect(scene.landscapeId, 'cascade-foret');
      expect(scene.moment, Moment.jour);
      expect(scene.sounds, const [
        Layer(id: 'eau-vive', level: 60),
        Layer(id: 'oiseaux', level: 40),
      ]);
      expect(scene.music, const [Layer(id: 'piano-doux', level: 25)]);
      expect(scene.decor, const [Layer(id: 'brume', level: 30)]);
      expect(scene.timer, const TimerDuration(60));
      expect(scene.sleepTracking, isTrue);
      expect(scene.toJson(), json);
      expect(Scene.fromJson(scene.toJson()), scene);
    });

    test('timer modes', () {
      expect(const TimerDuration(90).toJson(), {
        'mode': 'duree',
        'minutes': 90,
      });
      expect(const TimerNight().toJson(), {'mode': 'nuit'});
      expect(const TimerNone().toJson(), {'mode': 'aucun'});
      expect(
        TimerSetting.fromJson({'mode': 'duree', 'minutes': 15}),
        const TimerDuration(15),
      );
      expect(TimerSetting.fromJson({'mode': 'nuit'}), const TimerNight());
      expect(TimerSetting.fromJson({'mode': 'aucun'}), const TimerNone());
      expect(
        TimerSetting.tryParse({'mode': 'duree', 'minutes': 600}),
        const TimerDuration(600),
      );
      expect(
        TimerSetting.tryParse({'mode': 'duree', 'minutes': 60.0}),
        const TimerDuration(60),
      );
    });

    test('invalid timers', () {
      for (final bad in [
        {'mode': 'duree', 'minutes': 0},
        {'mode': 'duree', 'minutes': 601},
        {'mode': 'duree', 'minutes': 10.5},
        {'mode': 'duree'},
        {'mode': 'jamais'},
        'nuit',
        null,
      ]) {
        expect(TimerSetting.tryParse(bad), isNull, reason: '$bad');
      }
      expect(() => TimerSetting.fromJson({'mode': 'x'}), throwsFormatException);
    });

    test('lenient parsing with defaults', () {
      final scene = Scene.fromJson({
        'paysage': 'sous-bois',
        'sons': [
          {'id': 'vent', 'niveau': 140},
          {'id': 'vent', 'niveau': 10},
          {'niveau': 20},
          {'id': 'pluie-douce', 'niveau': 0},
          'garbage',
        ],
        'minuteur': {'mode': 'bizarre'},
      });
      expect(scene.version, 1);
      expect(scene.moment, Moment.jour);
      expect(scene.sounds, const [Layer(id: 'vent', level: 100)]);
      expect(scene.timer, Scene.defaultTimer);
      expect(scene.sleepTracking, isFalse);
      expect(() => Scene.fromJson({'moment': 'jour'}), throwsFormatException);
    });
  });

  group('fromLandscape', () {
    test('loads the default mix and a 1 h timer', () {
      final scene = Scene.fromLandscape(catalog.landscape('cascade-foret')!);
      expect(scene.landscapeId, 'cascade-foret');
      expect(scene.moment, Moment.jour);
      expect(scene.sounds.map((l) => l.id), ['eau-vive', 'oiseaux', 'vent']);
      expect(scene.decor, const [Layer(id: 'brume', level: 30)]);
      expect(scene.timer, const TimerDuration(60));
      expect(scene.sleepTracking, isFalse);
      expect(scene.audioLayerCount, 3);
    });

    test('options and withLandscape keep moment, timer and tracking', () {
      final scene = Scene.fromLandscape(
        catalog.landscape('cafe-nuit')!,
        moment: Moment.nuit,
        timer: const TimerNight(),
      );
      expect(scene.moment, Moment.nuit);
      expect(scene.music, const [Layer(id: 'piano-doux', level: 30)]);
      final moved = scene
          .copyWith(sleepTracking: true)
          .withLandscape(catalog.landscape('lune-lac')!);
      expect(moved.landscapeId, 'lune-lac');
      expect(moved.moment, Moment.nuit);
      expect(moved.timer, const TimerNight());
      expect(moved.sleepTracking, isTrue);
      expect(moved.music, isEmpty);
      expect(moved.sounds.map((l) => l.id), ['ruisseau', 'chouette']);
    });
  });

  group('withLevel', () {
    final base = Scene.fromLandscape(catalog.landscape('cascade-foret')!);

    test('updates, adds, clamps', () {
      final louder = base.withLevel(LayerKind.son, 'vent', 80);
      expect(louder.levelOf(LayerKind.son, 'vent'), 80);
      expect(louder.sounds.map((l) => l.id), ['eau-vive', 'oiseaux', 'vent']);
      final added = base.withLevel(LayerKind.musique, 'piano-doux', 130);
      expect(added.music, const [Layer(id: 'piano-doux', level: 100)]);
      expect(base.withLevel(LayerKind.son, 'vent', 30), same(base));
      // The original is untouched (undo keeps it).
      expect(base.levelOf(LayerKind.son, 'vent'), 30);
      expect(base.music, isEmpty);
    });

    test('0 or less removes', () {
      final removed = base.withLevel(LayerKind.son, 'oiseaux', 0);
      expect(removed.hasLayer(LayerKind.son, 'oiseaux'), isFalse);
      expect(
        base
            .withLevel(LayerKind.son, 'vent', -5)
            .hasLayer(LayerKind.son, 'vent'),
        isFalse,
      );
      expect(base.withLevel(LayerKind.son, 'tonnerre', 0), same(base));
    });

    test('couches_max counts sounds and music, not decor', () {
      var scene = base; // 3 sounds
      scene = scene.withLevel(LayerKind.son, 'pluie-douce', 50);
      scene = scene.withLevel(LayerKind.musique, 'piano-doux', 50);
      scene = scene.withLevel(LayerKind.musique, 'harpe', 50);
      expect(scene.audioLayerCount, 6);
      final refused = scene.withLevel(LayerKind.son, 'vagues', 50);
      expect(refused, same(scene));
      final refusedMusic = scene.withLevel(LayerKind.musique, 'flute', 50);
      expect(refusedMusic, same(scene));
      // Changing an existing layer is still allowed at the max.
      expect(
        scene
            .withLevel(LayerKind.son, 'vent', 90)
            .levelOf(LayerKind.son, 'vent'),
        90,
      );
      // Decor is not an audio layer.
      final decor = scene.withLevel(LayerKind.decor, 'lucioles', 40);
      expect(decor.decor.map((l) => l.id), ['brume', 'lucioles']);
      // A custom maximum.
      expect(
        base.withLevel(LayerKind.son, 'pluie-douce', 50, maxAudioLayers: 3),
        same(base),
      );
    });

    test('withoutLayer', () {
      expect(base.withoutLayer(LayerKind.son, 'vent').sounds.map((l) => l.id), [
        'eau-vive',
        'oiseaux',
      ]);
      expect(base.withoutLayer(LayerKind.son, '*').sounds, isEmpty);
      expect(base.withoutLayer(LayerKind.musique, '*'), same(base));
      expect(base.withoutLayer(LayerKind.son, 'tonnerre'), same(base));
    });
  });

  test('immutable lists and value equality', () {
    final scene = Scene(
      landscapeId: 'sous-bois',
      sounds: [const Layer(id: 'vent', level: 30)],
    );
    expect(
      () => scene.sounds.add(const Layer(id: 'x', level: 1)),
      throwsUnsupportedError,
    );
    final same = Scene(
      landscapeId: 'sous-bois',
      sounds: [const Layer(id: 'vent', level: 30)],
    );
    expect(scene, same);
    expect(scene.hashCode, same.hashCode);
    expect(scene.copyWith(moment: Moment.soir), isNot(scene));
    expect(scene.layers(LayerKind.son), scene.sounds);
  });

  test('Moment', () {
    expect(Moment.fromName('nuit'), Moment.nuit);
    expect(Moment.fromName('midi'), isNull);
    expect(Moment.values.map((m) => m.label), ['Aube', 'Jour', 'Soir', 'Nuit']);
  });
}
