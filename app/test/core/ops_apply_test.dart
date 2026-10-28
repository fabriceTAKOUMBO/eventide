import 'package:eventide/core/catalog.dart';
import 'package:eventide/core/ops.dart';
import 'package:eventide/core/plan.dart';
import 'package:eventide/core/scene.dart';
import 'package:eventide/core/schedule.dart';
import 'package:eventide/core/settings.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

void main() {
  final catalog = loadCatalog();
  final now = DateTime(2026, 10, 28, 21, 0);

  AppSnapshot snapshot({
    String landscape = 'cascade-foret',
    List<Schedule> schedules = const [],
    AppSettings settings = const AppSettings(),
    bool playing = true,
  }) => AppSnapshot(
    scene: Scene.fromLandscape(catalog.landscape(landscape)!),
    schedules: schedules,
    settings: settings,
    playing: playing,
  );

  Schedule schedule(
    String id,
    int hour, {
    int minute = 0,
    Reminder reminder = Reminder.dormir,
    bool active = true,
  }) => Schedule(
    id: id,
    hour: hour,
    minute: minute,
    days: Schedule.everyDay,
    landscapeId: 'cascade-foret',
    reminder: reminder,
    active: active,
  );

  var counter = 0;
  String newId() => 'n${++counter}';

  ApplyResult apply(
    AppSnapshot before,
    List<Map<String, dynamic>> ops, {
    Plan? plan,
  }) => applyOps(before, ops, catalog, newId: newId, now: now, plan: plan);

  group('layers', () {
    test('ajouter with the default level, then regler', () {
      final before = snapshot();
      final r = apply(before, [
        {'op': 'ajouter', 'cible': 'son', 'id': 'pluie-douce'},
      ]);
      expect(r.snapshot.scene.levelOf(LayerKind.son, 'pluie-douce'), 50);
      expect(r.changes, const [ChangeLine('Pluie douce', '50 %')]);
      expect(r.effects, isEmpty);

      final r2 = apply(before, [
        {'op': 'ajouter', 'cible': 'son', 'id': 'pluie-douce'},
        {'op': 'regler', 'cible': 'son', 'id': 'pluie-douce', 'niveau': 70},
      ]);
      expect(r2.snapshot.scene.levelOf(LayerKind.son, 'pluie-douce'), 70);
      expect(r2.changes, const [ChangeLine('Pluie douce', '70 %')]);
    });

    test('ajouter an element already playing never lowers it', () {
      // Cascade en forêt: eau-vive 60, vent 30.
      final r = apply(snapshot(), [
        {'op': 'ajouter', 'cible': 'son', 'id': 'eau-vive', 'niveau': 50},
        {'op': 'ajouter', 'cible': 'son', 'id': 'vent', 'niveau': 50},
      ]);
      expect(r.snapshot.scene.levelOf(LayerKind.son, 'eau-vive'), 60);
      expect(r.snapshot.scene.levelOf(LayerKind.son, 'vent'), 50);
      expect(r.changes, const [
        ChangeLine('Eau vive', '60 %'),
        ChangeLine('Vent', '50 %'),
      ]);
      final r2 = apply(snapshot(), [
        {'op': 'ajouter', 'cible': 'son', 'id': 'vent', 'niveau': 45},
        {'op': 'ajouter', 'cible': 'son', 'id': 'oiseaux', 'niveau': 20},
      ]);
      expect(r2.snapshot.scene.levelOf(LayerKind.son, 'vent'), 45);
      expect(r2.snapshot.scene.levelOf(LayerKind.son, 'oiseaux'), 40);
    });

    test('regler to 0 removes', () {
      final r = apply(snapshot(), [
        {'op': 'regler', 'cible': 'son', 'id': 'oiseaux', 'niveau': 0},
      ]);
      expect(r.snapshot.scene.hasLayer(LayerKind.son, 'oiseaux'), isFalse);
      expect(r.changes, const [ChangeLine('Oiseaux', 'Hors du mix')]);
    });

    test('ajuster clamps, removes at 0 and adds an absent element at 50', () {
      final r = apply(snapshot(), [
        {'op': 'ajuster', 'cible': 'son', 'id': 'eau-vive', 'delta': 60},
        {'op': 'ajuster', 'cible': 'son', 'id': 'vent', 'delta': -40},
        {'op': 'ajuster', 'cible': 'son', 'id': 'pluie-douce', 'delta': 20},
        {'op': 'ajuster', 'cible': 'son', 'id': 'ruisseau', 'delta': -20},
      ]);
      final scene = r.snapshot.scene;
      expect(scene.levelOf(LayerKind.son, 'eau-vive'), 100);
      expect(scene.hasLayer(LayerKind.son, 'vent'), isFalse);
      expect(scene.levelOf(LayerKind.son, 'pluie-douce'), 50);
      expect(scene.hasLayer(LayerKind.son, 'ruisseau'), isFalse);
      expect(r.changes, const [
        ChangeLine('Eau vive', '100 %'),
        ChangeLine('Vent', 'Hors du mix'),
        ChangeLine('Pluie douce', '50 %'),
      ]);
    });

    test('retirer one element or all of a kind', () {
      final before = snapshot(landscape: 'cafe-nuit');
      final r = apply(before, [
        {'op': 'retirer', 'cible': 'musique', 'id': '*'},
        {'op': 'retirer', 'cible': 'son', 'id': 'pluie-douce'},
        {'op': 'retirer', 'cible': 'son', 'id': 'vent'}, // not playing
        {'op': 'retirer', 'cible': 'decor', 'id': '*'}, // nothing to remove
      ]);
      expect(r.snapshot.scene.music, isEmpty);
      expect(r.snapshot.scene.sounds, isEmpty);
      expect(r.changes, const [
        ChangeLine('Musique', 'Aucune'),
        ChangeLine('Pluie douce', 'Hors du mix'),
      ]);
    });

    test('couches_max refuses a seventh audio layer', () {
      var before = snapshot(); // 3 sounds
      before = before.copyWith(
        scene: before.scene
            .withLevel(LayerKind.son, 'pluie-douce', 40)
            .withLevel(LayerKind.son, 'ruisseau', 40)
            .withLevel(LayerKind.musique, 'piano-doux', 40),
      );
      expect(before.scene.audioLayerCount, 6);
      final r = apply(before, [
        {'op': 'ajouter', 'cible': 'musique', 'id': 'nappes-apaisantes'},
        {'op': 'ajuster', 'cible': 'son', 'id': 'vagues', 'delta': 20},
        {'op': 'ajouter', 'cible': 'decor', 'id': 'lucioles'},
        {'op': 'regler', 'cible': 'son', 'id': 'vent', 'niveau': 80},
      ]);
      expect(r.snapshot.scene.audioLayerCount, 6);
      expect(r.snapshot.scene.hasLayer(LayerKind.decor, 'lucioles'), isTrue);
      expect(r.snapshot.scene.levelOf(LayerKind.son, 'vent'), 80);
      expect(r.effects, const [RefuseEffect('couches_max')]);
      expect(r.changes, const [
        ChangeLine('Lucioles', '50 %'),
        ChangeLine('Vent', '80 %'),
      ]);
    });
  });

  group('landscape and moment', () {
    test('definir paysage loads the default mix, keeps moment and timer', () {
      final before = snapshot().copyWith(
        scene: snapshot().scene.copyWith(
          moment: Moment.nuit,
          timer: const TimerNight(),
        ),
      );
      final r = apply(before, [
        {'op': 'definir', 'cible': 'paysage', 'valeur': 'lune-lac'},
      ]);
      final scene = r.snapshot.scene;
      expect(scene.landscapeId, 'lune-lac');
      expect(scene.sounds.map((l) => l.id), ['ruisseau', 'chouette']);
      expect(scene.moment, Moment.nuit);
      expect(scene.timer, const TimerNight());
      expect(r.changes, const [ChangeLine('Paysage', 'Lune sur le lac')]);
    });

    test('definir the current landscape keeps a customized mix', () {
      final before = snapshot();
      final custom = before.copyWith(
        scene: before.scene.withLevel(LayerKind.son, 'vent', 90),
      );
      final r = apply(custom, [
        {'op': 'definir', 'cible': 'paysage', 'valeur': 'cascade-foret'},
      ]);
      expect(r.snapshot.scene, custom.scene);
      expect(r.changes, const [ChangeLine('Paysage', 'Cascade en forêt')]);
    });

    test('changer moves within the theme without wrapping', () {
      final next = apply(snapshot(), [
        {'op': 'changer', 'cible': 'paysage', 'valeur': 'suivant'},
      ]);
      expect(next.snapshot.scene.landscapeId, 'sous-bois');
      expect(next.changes, const [
        ChangeLine('Paysage', 'Sous-bois ensoleillé'),
      ]);

      final first = apply(snapshot(), [
        {'op': 'changer', 'cible': 'paysage', 'valeur': 'precedent'},
      ]);
      expect(first.snapshot.scene.landscapeId, 'cascade-foret');
      expect(first.changes, isEmpty);

      final last = apply(snapshot(landscape: 'lisiere-verte'), [
        {'op': 'changer', 'cible': 'paysage', 'valeur': 'suivant'},
      ]);
      expect(last.snapshot.scene.landscapeId, 'lisiere-verte');

      final astral = apply(snapshot(landscape: 'lune-lac'), [
        {'op': 'changer', 'cible': 'paysage', 'valeur': 'precedent'},
      ]);
      expect(astral.snapshot.scene.landscapeId, 'aurore-boreale');
    });

    test('with a free plan, a locked landscape opens Premium', () {
      final r = apply(snapshot(landscape: 'sous-bois'), [
        {'op': 'changer', 'cible': 'paysage', 'valeur': 'suivant'},
      ], plan: Plan.free);
      expect(r.snapshot.scene.landscapeId, 'sous-bois');
      expect(r.effects, const [OpenPremiumEffect()]);
      final premium = apply(snapshot(landscape: 'sous-bois'), [
        {'op': 'changer', 'cible': 'paysage', 'valeur': 'suivant'},
      ], plan: Plan.annual);
      expect(premium.snapshot.scene.landscapeId, 'berge-mousseuse');
    });

    test('definir moment', () {
      final r = apply(snapshot(), [
        {'op': 'definir', 'cible': 'moment', 'valeur': 'nuit'},
      ]);
      expect(r.snapshot.scene.moment, Moment.nuit);
      expect(r.changes, const [ChangeLine('Moment de la journée', 'Nuit')]);
    });
  });

  group('timer, playback, sleep, settings', () {
    test('timer lines', () {
      ApplyResult timer(Map<String, dynamic> v) => apply(snapshot(), [
        {'op': 'definir', 'cible': 'minuteur', 'valeur': v},
      ]);
      final hour = timer({'mode': 'duree', 'minutes': 60});
      expect(hour.snapshot.scene.timer, const TimerDuration(60));
      expect(hour.changes, const [ChangeLine('Minuteur', 'Arrêt après 1 h')]);
      expect(timer({'mode': 'duree', 'minutes': 90}).changes, const [
        ChangeLine('Minuteur', 'Arrêt après 1 h 30'),
      ]);
      expect(timer({'mode': 'duree', 'minutes': 15}).changes, const [
        ChangeLine('Minuteur', 'Arrêt après 15 min'),
      ]);
      expect(timer({'mode': 'nuit'}).changes, const [
        ChangeLine('Minuteur', 'Toute la nuit'),
      ]);
      expect(timer({'mode': 'aucun'}).snapshot.scene.timer, const TimerNone());
      expect(timer({'mode': 'aucun'}).changes, const [
        ChangeLine('Minuteur', 'Sans minuteur'),
      ]);
    });

    test('pause and resume', () {
      final paused = apply(snapshot(playing: true), [
        {'op': 'lecture', 'valeur': 'pause'},
      ]);
      expect(paused.snapshot.playing, isFalse);
      expect(paused.effects, const [PauseEffect()]);
      final resumed = apply(snapshot(playing: false), [
        {'op': 'lecture', 'valeur': 'reprise'},
      ]);
      expect(resumed.snapshot.playing, isTrue);
      expect(resumed.effects, const [ResumeEffect()]);
    });

    test('sleep tracking and night', () {
      final r = apply(snapshot(), [
        {'op': 'definir', 'cible': 'sommeil.suivi', 'valeur': true},
        {'op': 'commencer_nuit'},
      ]);
      expect(r.snapshot.scene.sleepTracking, isTrue);
      expect(r.effects, const [StartNightEffect()]);
      expect(r.changes.first, const ChangeLine('Suivi du sommeil', 'Activé'));
    });

    test('settings', () {
      final r = apply(snapshot(), [
        {
          'op': 'definir',
          'cible': 'reglage',
          'cle': 'taille_texte',
          'valeur': 'plus',
        },
        {
          'op': 'definir',
          'cible': 'reglage',
          'cle': 'contraste_renforce',
          'valeur': true,
        },
        {
          'op': 'definir',
          'cible': 'reglage',
          'cle': 'ecran_noir_minuteur',
          'valeur': true,
        },
        {
          'op': 'definir',
          'cible': 'reglage',
          'cle': 'wifi_seulement',
          'valeur': true,
        },
      ]);
      expect(
        r.snapshot.settings,
        const AppSettings(
          textSize: 1,
          highContrast: true,
          blackScreenDuringTimer: true,
          wifiOnly: true,
        ),
      );
      expect(r.changes, const [
        ChangeLine('Taille du texte', 'Grande'),
        ChangeLine('Contraste renforcé', 'Activé'),
        ChangeLine('Écran noir pendant le minuteur', 'Activé'),
        ChangeLine('Téléchargements en Wi-Fi seulement', 'Activé'),
      ]);
      final max = apply(snapshot(settings: const AppSettings(textSize: 2)), [
        {
          'op': 'definir',
          'cible': 'reglage',
          'cle': 'taille_texte',
          'valeur': 'plus',
        },
      ]);
      expect(max.snapshot.settings.textSize, 2);
      final min = apply(snapshot(), [
        {
          'op': 'definir',
          'cible': 'reglage',
          'cle': 'taille_texte',
          'valeur': 'moins',
        },
      ]);
      expect(min.snapshot.settings.textSize, 0);
      final set = apply(snapshot(), [
        {
          'op': 'definir',
          'cible': 'reglage',
          'cle': 'taille_texte',
          'valeur': 2,
        },
      ]);
      expect(set.changes, const [ChangeLine('Taille du texte', 'Très grande')]);
    });

    test('navigation effects, deduplicated', () {
      final r = apply(snapshot(), [
        {'op': 'partager'},
        {'op': 'ouvrir', 'cible': 'premium'},
        {'op': 'ouvrir', 'cible': 'premium'},
        {'op': 'reformuler', 'raison': 'incompris'},
        {'op': 'refuser', 'raison': 'interdit'},
      ]);
      expect(r.effects, const [
        ShareEffect(),
        OpenPremiumEffect(),
        RephraseEffect('incompris'),
        RefuseEffect('interdit'),
      ]);
      expect(r.changes, isEmpty);
      expect(r.snapshot, snapshot());
    });
  });

  group('schedules', () {
    test('creer with all fields', () {
      final r = apply(snapshot(), [
        {
          'op': 'creer',
          'cible': 'programmation',
          'valeur': {
            'heure': '22:00',
            'jours': [1, 2, 3, 4, 5, 6, 7],
            'paysage': 'cascade-foret',
            'montee_minutes': 10,
            'rappel': 'dormir',
          },
        },
      ]);
      final created = r.snapshot.schedules.single;
      expect(created.id, startsWith('n'));
      expect(created.time, '22:00');
      expect(created.active, isTrue);
      expect(r.changes, const [
        ChangeLine('Programmation', 'Tous les jours à 22 h · Cascade en forêt'),
      ]);
    });

    test('creer fills defaults from the current state', () {
      final r = apply(snapshot(landscape: 'sous-bois'), [
        {
          'op': 'creer',
          'cible': 'programmation',
          'valeur': {
            'heure': '13:30',
            'jours': [1, 2, 3, 4, 5],
            'rappel': 'detente',
          },
        },
      ]);
      final s = r.snapshot.schedules.single;
      expect(s.landscapeId, 'sous-bois');
      expect(s.rampMinutes, 10);
      expect(s.reminder, Reminder.detente);
      expect(
        r.changes.single.value,
        'Du lundi au vendredi à 13 h 30 · Sous-bois ensoleillé',
      );
      final minimal = apply(snapshot(), [
        {
          'op': 'creer',
          'cible': 'programmation',
          'valeur': {'heure': '07:15'},
        },
      ]);
      expect(minimal.snapshot.schedules.single.days, Schedule.everyDay);
      expect(minimal.snapshot.schedules.single.reminder, Reminder.dormir);
    });

    test('free plan: one schedule, then Premium', () {
      final op = {
        'op': 'creer',
        'cible': 'programmation',
        'valeur': {'heure': '22:00'},
      };
      final first = apply(snapshot(), [op], plan: Plan.free);
      expect(first.snapshot.schedules, hasLength(1));
      final second = apply(first.snapshot, [op], plan: Plan.free);
      expect(second.snapshot.schedules, hasLength(1));
      expect(second.effects, const [OpenPremiumEffect()]);
      final premium = apply(first.snapshot, [op], plan: Plan.monthly);
      expect(premium.snapshot.schedules, hasLength(2));
    });

    final three = [
      schedule('a', 22),
      schedule('b', 7, minute: 30, reminder: Reminder.detente),
      schedule('c', 13, minute: 30, reminder: Reminder.detente),
    ];

    test('selectors', () {
      expect(matchSchedules(three, {'id': 'b'}).map((s) => s.id), ['b']);
      expect(matchSchedules(three, {'heure': '22:00'}).map((s) => s.id), ['a']);
      expect(matchSchedules(three, {'heure': '7:30'}).map((s) => s.id), ['b']);
      expect(matchSchedules(three, {'rappel': 'detente'}).map((s) => s.id), [
        'b',
        'c',
      ]);
      expect(
        matchSchedules(three, {'moment_journee': 'matin'}).map((s) => s.id),
        ['b'],
      );
      expect(
        matchSchedules(three, {
          'moment_journee': 'apres-midi',
        }).map((s) => s.id),
        ['c'],
      );
      expect(
        matchSchedules(three, {'moment_journee': 'soir'}).map((s) => s.id),
        ['a'],
      );
      expect(matchSchedules(three, {'heure': '23:00'}), isEmpty);
    });

    test('desactiver applies to every match', () {
      final r = apply(snapshot(schedules: three), [
        {
          'op': 'desactiver',
          'cible': 'programmation',
          'selecteur': {'rappel': 'detente'},
        },
      ]);
      expect(r.snapshot.schedules.map((s) => s.active), [true, false, false]);
      expect(r.changes, const [
        ChangeLine(
          'Programmation désactivée',
          'Tous les jours à 7 h 30 · Cascade en forêt',
        ),
        ChangeLine(
          'Programmation désactivée',
          'Tous les jours à 13 h 30 · Cascade en forêt',
        ),
      ]);
      final again = apply(r.snapshot, [
        {
          'op': 'activer',
          'cible': 'programmation',
          'selecteur': {'id': 'c'},
        },
      ]);
      expect(again.snapshot.schedules.map((s) => s.active), [
        true,
        false,
        true,
      ]);
    });

    test('modifier and supprimer need a single match', () {
      final modify = apply(snapshot(schedules: three), [
        {
          'op': 'modifier',
          'cible': 'programmation',
          'selecteur': {'rappel': 'detente'},
          'valeur': {'heure': '14:00'},
        },
      ]);
      expect(modify.effects, const [RephraseEffect('ambigu')]);
      expect(modify.snapshot.schedules, three);

      final delete = apply(snapshot(schedules: three), [
        {
          'op': 'supprimer',
          'cible': 'programmation',
          'selecteur': {'rappel': 'detente'},
        },
      ]);
      expect(delete.effects, const [RephraseEffect('ambigu')]);
      expect(delete.snapshot.schedules, hasLength(3));
    });

    test('modifier one schedule', () {
      final r = apply(snapshot(schedules: three), [
        {
          'op': 'modifier',
          'cible': 'programmation',
          'selecteur': {'heure': '22:00'},
          'valeur': {
            'heure': '22:30',
            'jours': [6, 7],
            'montee_minutes': 20,
            'paysage': 'lune-lac',
            'rappel': 'detente',
          },
        },
      ]);
      final s = r.snapshot.schedules.first;
      expect(s.id, 'a');
      expect(s.time, '22:30');
      expect(s.days, {6, 7});
      expect(s.rampMinutes, 20);
      expect(s.landscapeId, 'lune-lac');
      expect(s.reminder, Reminder.detente);
      expect(r.changes, const [
        ChangeLine(
          'Programmation modifiée',
          'Le week-end à 22 h 30 · Lune sur le lac',
        ),
      ]);
    });

    test('supprimer the morning schedule', () {
      final r = apply(snapshot(schedules: three), [
        {
          'op': 'supprimer',
          'cible': 'programmation',
          'selecteur': {'moment_journee': 'matin'},
        },
      ]);
      expect(r.snapshot.schedules.map((s) => s.id), ['a', 'c']);
      expect(r.changes.single.label, 'Programmation supprimée');
    });

    test('no match asks to rephrase', () {
      final r = apply(snapshot(schedules: three), [
        {
          'op': 'activer',
          'cible': 'programmation',
          'selecteur': {'heure': '06:00'},
        },
      ]);
      expect(r.effects, const [RephraseEffect('introuvable')]);
    });
  });

  group('undo', () {
    test('the before snapshot is never modified', () {
      final before = snapshot(schedules: [schedule('a', 22)]);
      final copy = AppSnapshot(
        scene: before.scene,
        schedules: [...before.schedules],
        settings: before.settings,
        playing: before.playing,
      );
      final r = apply(before, [
        {'op': 'definir', 'cible': 'paysage', 'valeur': 'sous-bois'},
        {'op': 'ajouter', 'cible': 'musique', 'id': 'piano-doux'},
        {'op': 'retirer', 'cible': 'decor', 'id': '*'},
        {
          'op': 'definir',
          'cible': 'minuteur',
          'valeur': {'mode': 'nuit'},
        },
        {'op': 'lecture', 'valeur': 'pause'},
        {
          'op': 'supprimer',
          'cible': 'programmation',
          'selecteur': {'id': 'a'},
        },
        {
          'op': 'creer',
          'cible': 'programmation',
          'valeur': {'heure': '21:00'},
        },
        {
          'op': 'definir',
          'cible': 'reglage',
          'cle': 'contraste_renforce',
          'valeur': true,
        },
      ]);
      expect(r.snapshot, isNot(before));
      expect(before, copy);
      expect(before.scene.landscapeId, 'cascade-foret');
      expect(before.schedules.single.id, 'a');
      expect(before.playing, isTrue);
      // Undo = reinstall `before`.
      expect(r.snapshot.schedules.single.time, '21:00');
    });

    test('immutable result lists', () {
      final r = apply(snapshot(), [
        {'op': 'partager'},
      ]);
      expect(() => r.effects.add(const PauseEffect()), throwsUnsupportedError);
      expect(
        () => r.snapshot.schedules.add(schedule('x', 1)),
        throwsUnsupportedError,
      );
    });
  });

  test('validated then applied: a free user asking for a Premium sound', () {
    final ops = validateOps(
      [
        {'op': 'ajouter', 'cible': 'son', 'id': 'tonnerre'},
        {'op': 'ajouter', 'cible': 'son', 'id': 'pluie-douce', 'niveau': 60},
      ],
      catalog,
      Plan.free,
    );
    final r = apply(snapshot(), ops);
    expect(r.effects, const [OpenPremiumEffect()]);
    expect(r.snapshot.scene.hasLayer(LayerKind.son, 'tonnerre'), isFalse);
    expect(r.snapshot.scene.levelOf(LayerKind.son, 'pluie-douce'), 60);
  });

  test('voice state (contract §7)', () {
    final state = snapshot(schedules: [schedule('a', 22)]).toVoiceState();
    expect(state.keys, ['scene', 'programmations', 'lecture', 'reglages']);
    expect(state['lecture'], 'en_cours');
    expect(
      (state['programmations'] as List).single,
      containsPair('heure', '22:00'),
    );
    expect(state['reglages'], const AppSettings().toVoiceStateJson());
    expect(snapshot(playing: false).toVoiceState()['lecture'], 'en_pause');
  });
}
