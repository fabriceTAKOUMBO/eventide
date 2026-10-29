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
  "sourdine": {"sons": false, "musique": false},
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
      expect(scene.mutedSounds, isFalse);
      expect(scene.mutedMusic, isFalse);
      expect(scene.toJson(), json);
      expect(Scene.fromJson(scene.toJson()), scene);
    });

    test('sourdine: optional when reading, always written, round-trips', () {
      // A document written before `sourdine` existed stays valid (version 1).
      final old = jsonDecode(contractJson) as Map<String, dynamic>
        ..remove('sourdine');
      final scene = Scene.fromJson(old);
      expect(scene.mutedSounds, isFalse);
      expect(scene.mutedMusic, isFalse);
      expect(scene.version, 1);
      expect(scene.toJson()['sourdine'], {'sons': false, 'musique': false});

      final muted = Scene.fromJson({
        ...old,
        'sourdine': {'musique': true},
      });
      expect(muted.mutedMusic, isTrue);
      expect(muted.mutedSounds, isFalse);
      expect(muted.music, const [Layer(id: 'piano-doux', level: 25)]);
      expect(Scene.fromJson(muted.toJson()), muted);
      expect(muted, isNot(scene));

      // Anything but a JSON boolean true is « not muted ».
      for (final bad in [
        'oui',
        1,
        [true],
        {'sons': 'true', 'musique': 1},
      ]) {
        final parsed = Scene.fromJson({...old, 'sourdine': bad});
        expect(
          parsed.mutedSounds || parsed.mutedMusic,
          isFalse,
          reason: '$bad',
        );
      }
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
        'paysage': 'foret-lucioles',
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
      expect(scene.sounds.map((l) => l.id), ['ambiance-cascade-foret', 'oiseaux', 'vent']);
      expect(scene.music, const [Layer(id: 'piano-doux', level: 20)]);
      expect(scene.decor, isEmpty, reason: 'a filmed landscape has no decor');
      expect(Scene.fromLandscape(catalog.landscape('foret-lucioles')!).decor, const [
        Layer(id: 'lucioles', level: 60),
        Layer(id: 'brume', level: 30),
      ]);
      expect(scene.timer, const TimerDuration(60));
      expect(scene.sleepTracking, isFalse);
      expect(scene.audioLayerCount, 4);
      expect(scene.mutedSounds || scene.mutedMusic, isFalse);
    });

    test('options and withLandscape keep moment, timer, tracking and mute', () {
      final scene = Scene.fromLandscape(
        catalog.landscape('pluie-ville')!,
        moment: Moment.nuit,
        timer: const TimerNight(),
      );
      expect(scene.moment, Moment.nuit);
      expect(scene.music, const [Layer(id: 'piano-doux', level: 20)]);
      final moved = scene
          .copyWith(sleepTracking: true, mutedMusic: true)
          .withLandscape(catalog.landscape('lac-lune')!);
      expect(moved.landscapeId, 'lac-lune');
      expect(moved.moment, Moment.nuit);
      expect(moved.timer, const TimerNight());
      expect(moved.sleepTracking, isTrue);
      expect(moved.music, const [Layer(id: 'harpe', level: 15)]);
      expect(moved.mutedMusic, isTrue, reason: 'the mute is a listening state');
      expect(moved.mutedSounds, isFalse);
      expect(moved.sounds.map((l) => l.id), ['ruisseau', 'chouette']);
    });
  });

  group('withLevel', () {
    final base = Scene.fromLandscape(catalog.landscape('cascade-foret')!);

    test('updates, adds, clamps', () {
      final louder = base.withLevel(LayerKind.son, 'vent', 80);
      expect(louder.levelOf(LayerKind.son, 'vent'), 80);
      expect(louder.sounds.map((l) => l.id), ['ambiance-cascade-foret', 'oiseaux', 'vent']);
      final added = base.withLevel(LayerKind.musique, 'piano-doux', 130);
      expect(added.music, const [Layer(id: 'piano-doux', level: 100)]);
      expect(base.withLevel(LayerKind.son, 'vent', 30), same(base));
      // The original is untouched (undo keeps it).
      expect(base.levelOf(LayerKind.son, 'vent'), 30);
      expect(base.music, const [Layer(id: 'piano-doux', level: 20)]);
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
      expect(decor.decor.map((l) => l.id), ['lucioles']);
      // A custom maximum.
      expect(
        base.withLevel(LayerKind.son, 'pluie-douce', 50, maxAudioLayers: 3),
        same(base),
      );
    });

    test('withoutLayer', () {
      expect(base.withoutLayer(LayerKind.son, 'vent').sounds.map((l) => l.id), [
        'ambiance-cascade-foret',
        'oiseaux',
      ]);
      expect(base.withoutLayer(LayerKind.son, '*').sounds, isEmpty);
      final silent = base.withoutLayer(LayerKind.musique, '*');
      expect(silent.music, isEmpty);
      expect(silent.withoutLayer(LayerKind.musique, '*'), same(silent));
      expect(base.withoutLayer(LayerKind.son, 'tonnerre'), same(base));
    });
  });

  group('sourdine (mute)', () {
    final base = Scene.fromLandscape(catalog.landscape('cascade-foret')!);

    test(
      'muting keeps every layer and its level; unmuting restores the mix',
      () {
        final muted = base.withMuted(LayerKind.musique, true);
        expect(muted.mutedMusic, isTrue);
        expect(muted.isMuted(LayerKind.musique), isTrue);
        expect(muted.isMuted(LayerKind.son), isFalse);
        expect(muted.music, base.music);
        expect(muted.levelOf(LayerKind.musique, 'piano-doux'), 20);
        expect(muted.effectiveLevelOf(LayerKind.musique, 'piano-doux'), 0);
        expect(muted.effectiveLevelOf(LayerKind.son, 'ambiance-cascade-foret'), 60);
        expect(muted.withMuted(LayerKind.musique, false), base);
        expect(muted.withMuted(LayerKind.musique, true), same(muted));
        expect(base.withMuted(LayerKind.musique, false), same(base));
      },
    );

    test('the decor has no mute', () {
      expect(base.withMuted(LayerKind.decor, true), same(base));
      expect(base.isMuted(LayerKind.decor), isFalse);
      expect(base.effectiveLevel(LayerKind.decor, 30), 30);
    });

    test('audible layers and a fully muted mix', () {
      expect(base.audibleLayerCount, 4);
      expect(base.fullyMuted, isFalse);
      final noMusic = base.withMuted(LayerKind.musique, true);
      expect(noMusic.audibleLayerCount, 3);
      expect(noMusic.fullyMuted, isFalse);
      final silent = noMusic.withMuted(LayerKind.son, true);
      expect(silent.audibleLayerCount, 0);
      expect(silent.fullyMuted, isTrue);
      expect(silent.withoutMute(), base);
      expect(base.withoutMute(), same(base));
      // Sounds muted and no music at all: nothing to hear either.
      final soundsOnly = base
          .withoutLayer(LayerKind.musique, '*')
          .withMuted(LayerKind.son, true);
      expect(soundsOnly.fullyMuted, isTrue);
      // An empty mix is not « muted »: there is nothing to play.
      final empty = Scene(landscapeId: 'cascade-foret', mutedMusic: true);
      expect(empty.fullyMuted, isFalse);
    });

    test(
      'changing levels keeps the mute flags (the caller decides to unmute)',
      () {
        final muted = base.withMuted(LayerKind.son, true);
        final louder = muted.withLevel(LayerKind.son, 'vent', 80);
        expect(louder.mutedSounds, isTrue);
        expect(louder.levelOf(LayerKind.son, 'vent'), 80);
        expect(louder.effectiveLevelOf(LayerKind.son, 'vent'), 0);
      },
    );
  });

  test('immutable lists and value equality', () {
    final scene = Scene(
      landscapeId: 'foret-lucioles',
      sounds: [const Layer(id: 'vent', level: 30)],
    );
    expect(
      () => scene.sounds.add(const Layer(id: 'x', level: 1)),
      throwsUnsupportedError,
    );
    final same = Scene(
      landscapeId: 'foret-lucioles',
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
