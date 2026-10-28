import 'package:eventide/core/catalog.dart';
import 'package:eventide/core/french_normalizer.dart';
import 'package:eventide/core/ops.dart';
import 'package:eventide/core/plan.dart';
import 'package:eventide/core/rules_parser.dart';
import 'package:eventide/core/scene.dart';
import 'package:eventide/core/schedule.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

void main() {
  final catalog = loadCatalog();
  final oneSchedule = Schedule(
    id: 'a1b2',
    hour: 22,
    minute: 0,
    days: Schedule.everyDay,
    landscapeId: 'cascade-foret',
  );
  final snapshot = AppSnapshot(
    scene: Scene.fromLandscape(catalog.landscape('cascade-foret')!),
    schedules: [oneSchedule],
    playing: true,
  );

  List<Map<String, dynamic>>? parse(String phrase, [AppSnapshot? state]) =>
      parseWithRules(normalizeFrench(phrase), state ?? snapshot, catalog);

  Map<String, dynamic> layer(
    String op,
    String cible,
    String id, [
    String? key,
    int? value,
  ]) => {'op': op, 'cible': cible, 'id': id, ?key: value};

  Map<String, dynamic> timer(Map<String, dynamic> v) => {
    'op': 'definir',
    'cible': 'minuteur',
    'valeur': v,
  };

  Map<String, dynamic> setting(String key, Object value) => {
    'op': 'definir',
    'cible': 'reglage',
    'cle': key,
    'valeur': value,
  };

  void expectParsed(Map<String, List<Map<String, dynamic>>> cases) {
    cases.forEach((phrase, ops) {
      final parsed = parse(phrase);
      expect(parsed, ops, reason: phrase);
      // Rules output is already canonical for the validator.
      expect(validateOps(parsed!, catalog, Plan.annual), ops, reason: phrase);
    });
  }

  group('annex B', () {
    test('sons, musiques et décors', () {
      expectParsed({
        'Ajoute plus de pluie': [
          layer('ajuster', 'son', 'pluie-douce', 'delta', 20),
        ],
        'Baisse les oiseaux': [
          layer('ajuster', 'son', 'oiseaux', 'delta', -20),
        ],
        'Enlève le vent': [layer('retirer', 'son', 'vent')],
        'Mets l’eau vive à 70 pour cent': [
          layer('regler', 'son', 'eau-vive', 'niveau', 70),
        ],
        'Ajoute du piano doux': [
          layer('ajouter', 'musique', 'piano-doux', 'niveau', 50),
        ],
        // Owner decision (28 Oct. 2026): « coupe » mutes, the settings are kept.
        'Coupe la musique': [
          {'op': 'couper', 'cible': 'musique'},
        ],
        'Enlève la musique': [layer('retirer', 'musique', '*')],
        'Ajoute de la brume': [
          layer('ajouter', 'decor', 'brume', 'niveau', 50),
        ],
        'Mets les lucioles': [
          layer('ajouter', 'decor', 'lucioles', 'niveau', 50),
        ],
      });
    });

    test('paysage et lumière', () {
      expectParsed({
        'Change de paysage': [
          {'op': 'changer', 'cible': 'paysage', 'valeur': 'suivant'},
        ],
        'Mets la cascade en forêt': [
          {'op': 'definir', 'cible': 'paysage', 'valeur': 'cascade-foret'},
        ],
        'Il fait nuit': [
          {'op': 'definir', 'cible': 'moment', 'valeur': 'nuit'},
        ],
        'Mets le soir': [
          {'op': 'definir', 'cible': 'moment', 'valeur': 'soir'},
        ],
      });
    });

    test('lecture et minuteur', () {
      expectParsed({
        'Pause': [
          {'op': 'lecture', 'valeur': 'pause'},
        ],
        'Reprends': [
          {'op': 'lecture', 'valeur': 'reprise'},
        ],
        'Arrête dans une heure': [
          timer({'mode': 'duree', 'minutes': 60}),
        ],
        'Minuteur une heure et demie': [
          timer({'mode': 'duree', 'minutes': 90}),
        ],
        'Toute la nuit': [
          timer({'mode': 'nuit'}),
        ],
        'Sans minuteur': [
          timer({'mode': 'aucun'}),
        ],
      });
    });

    test('programmations', () {
      expectParsed({
        'Désactive ma programmation de vingt-deux heures': [
          {
            'op': 'desactiver',
            'cible': 'programmation',
            'selecteur': {'heure': '22:00'},
          },
        ],
        'Supprime la programmation du matin': [
          {
            'op': 'supprimer',
            'cible': 'programmation',
            'selecteur': {'moment_journee': 'matin'},
          },
        ],
      });
      // « la pluie » is a sound, not a landscape: the model decides.
      expect(
        parse('Programme la pluie tous les soirs à vingt-deux heures'),
        isNull,
      );
      // No verb: left to the model.
      expect(
        parse(
          'Chaque jour de la semaine à treize heures trente, pour me détendre',
        ),
        isNull,
      );
    });

    test('sommeil, réglages et partage', () {
      expectParsed({
        'Active le suivi du sommeil': [
          {'op': 'definir', 'cible': 'sommeil.suivi', 'valeur': true},
        ],
        'Commence la nuit': [
          {'op': 'commencer_nuit'},
        ],
        'Mets le texte plus grand': [setting('taille_texte', 'plus')],
        'Contraste renforcé': [setting('contraste_renforce', true)],
        'Écran noir pendant le minuteur': [
          setting('ecran_noir_minuteur', true),
        ],
        'Partage mon mix avec ma sœur': [
          {'op': 'partager'},
        ],
      });
    });

    test('ce qu’elle refuse poliment', () {
      expectParsed({
        'Passe-moi en Premium': [
          {'op': 'ouvrir', 'cible': 'premium'},
        ],
        'Quelle heure est-il ?': [
          {'op': 'refuser', 'raison': 'hors_catalogue'},
        ],
      });
      expect(parse('Supprime mon compte'), [
        {'op': 'refuser', 'raison': 'interdit'},
      ]);
    });
  });

  group('more phrasings', () {
    test('Belgian numbers', () {
      expectParsed({
        'mets la pluie à septante pour cent': [
          layer('regler', 'son', 'pluie-douce', 'niveau', 70),
        ],
        'mets les oiseaux à nonante pour cent': [
          layer('regler', 'son', 'oiseaux', 'niveau', 90),
        ],
        'règle le vent à huitante': [
          layer('regler', 'son', 'vent', 'niveau', 80),
        ],
        'arrête dans nonante minutes': [
          timer({'mode': 'duree', 'minutes': 90}),
        ],
        'la brume à 40 %': [layer('regler', 'decor', 'brume', 'niveau', 40)],
        'mets le vent à fond': [layer('regler', 'son', 'vent', 'niveau', 100)],
      });
    });

    test('adjustments', () {
      expectParsed({
        'monte le vent': [layer('ajuster', 'son', 'vent', 'delta', 20)],
        'augmente la pluie': [
          layer('ajuster', 'son', 'pluie-douce', 'delta', 20),
        ],
        "un peu plus d'oiseaux": [
          layer('ajuster', 'son', 'oiseaux', 'delta', 10),
        ],
        'encore plus de vent': [layer('ajuster', 'son', 'vent', 'delta', 20)],
        'moins de vent': [layer('ajuster', 'son', 'vent', 'delta', -20)],
        'baisse un peu le piano': [
          layer('ajuster', 'musique', 'piano-doux', 'delta', -10),
        ],
        'le vent plus fort': [layer('ajuster', 'son', 'vent', 'delta', 20)],
        'la pluie moins forte': [
          layer('ajuster', 'son', 'pluie-douce', 'delta', -20),
        ],
        'baisse le volume de la pluie': [
          layer('ajuster', 'son', 'pluie-douce', 'delta', -20),
        ],
      });
    });

    test('add and remove', () {
      expectParsed({
        'Rajoute des grillons': [
          layer('ajouter', 'son', 'grillons', 'niveau', 50),
        ],
        'ajoute la flûte': [layer('ajouter', 'musique', 'flute', 'niveau', 50)],
        'mets de la pluie': [
          layer('ajouter', 'son', 'pluie-douce', 'niveau', 50),
        ],
        'enlève le bruit de la pluie': [layer('retirer', 'son', 'pluie-douce')],
        'retire les étoiles': [layer('retirer', 'decor', 'etoiles')],
        'coupe tous les sons': [
          {'op': 'couper', 'cible': 'son'},
        ],
        'enlève tous les sons': [layer('retirer', 'son', '*')],
        'retire toute la musique': [layer('retirer', 'musique', '*')],
        'enlève le décor': [layer('retirer', 'decor', '*')],
        'arrête le tonnerre': [layer('retirer', 'son', 'tonnerre')],
      });
    });

    test('mute and unmute a whole category (sourdine)', () {
      Map<String, dynamic> mute(String op, String cible) => {
        'op': op,
        'cible': cible,
      };
      expectParsed({
        'coupe la musique': [mute('couper', 'musique')],
        'arrête la musique': [mute('couper', 'musique')],
        'éteins les mélodies': [mute('couper', 'musique')],
        'mets la musique en sourdine': [mute('couper', 'musique')],
        'mets en sourdine la musique': [mute('couper', 'musique')],
        'la musique en sourdine s’il te plaît': [mute('couper', 'musique')],
        'coupe les sons de la nature': [mute('couper', 'son')],
        'coupe les bruits de la nature': [mute('couper', 'son')],
        'mets les sons en sourdine': [mute('couper', 'son')],
        'remets la musique': [mute('remettre', 'musique')],
        'rallume la musique': [mute('remettre', 'musique')],
        'remets les bruits de la nature': [mute('remettre', 'son')],
        'remets les sons de la nature': [mute('remettre', 'son')],
        'enlève la sourdine de la musique': [mute('remettre', 'musique')],
        'coupe la sourdine des sons': [mute('remettre', 'son')],
        // Unchanged: one element is removed, the decor has no mute, « le son »
        // is the playback.
        'coupe la pluie': [layer('retirer', 'son', 'pluie-douce')],
        'coupe le décor': [layer('retirer', 'decor', '*')],
        'coupe le son': [
          {'op': 'lecture', 'valeur': 'pause'},
        ],
        'remets le son': [
          {'op': 'lecture', 'valeur': 'reprise'},
        ],
        'coupe la musique et les sons': [
          mute('couper', 'musique'),
          mute('couper', 'son'),
        ],
      });
    });

    test(
      '« enlève la sourdine » unmutes what is muted; nothing to unmute → model',
      () {
        final musicMuted = AppSnapshot(
          scene: snapshot.scene.withMuted(LayerKind.musique, true),
        );
        final bothMuted = AppSnapshot(
          scene: snapshot.scene
              .withMuted(LayerKind.musique, true)
              .withMuted(LayerKind.son, true),
        );
        expect(parse('enlève la sourdine', musicMuted), [
          {'op': 'remettre', 'cible': 'musique'},
        ]);
        expect(parse('retire la sourdine', bothMuted), [
          {'op': 'remettre', 'cible': 'son'},
          {'op': 'remettre', 'cible': 'musique'},
        ]);
        expect(parse('enlève la sourdine'), isNull);
        // « Remets la musique » with no music in the mix: the model decides.
        final noMusic = AppSnapshot(
          scene: snapshot.scene.withoutLayer(LayerKind.musique, '*'),
        );
        expect(parse('remets la musique', noMusic), isNull);
        // A muted category with a single element named: still that element.
        expect(parse('mets la pluie en sourdine'), isNull);
        expect(parse('mets le décor en sourdine'), isNull);
      },
    );

    test('several commands', () {
      expectParsed({
        'ajoute de la pluie et baisse les oiseaux': [
          layer('ajouter', 'son', 'pluie-douce', 'niveau', 50),
          layer('ajuster', 'son', 'oiseaux', 'delta', -20),
        ],
        'ajoute de la pluie et du vent': [
          layer('ajouter', 'son', 'pluie-douce', 'niveau', 50),
          layer('ajouter', 'son', 'vent', 'niveau', 50),
        ],
        'il fait nuit puis arrête dans vingt minutes': [
          {'op': 'definir', 'cible': 'moment', 'valeur': 'nuit'},
          timer({'mode': 'duree', 'minutes': 20}),
        ],
        // A landscape alias containing « et » is matched whole first.
        'mets pierres et eau': [
          {'op': 'definir', 'cible': 'paysage', 'valeur': 'pierres-eau'},
        ],
      });
      expect(parse('ajoute de la pluie et fais la vaisselle'), isNull);
    });

    test('landscapes and moments', () {
      expectParsed({
        'paysage précédent': [
          {'op': 'changer', 'cible': 'paysage', 'valeur': 'precedent'},
        ],
        'paysage suivant': [
          {'op': 'changer', 'cible': 'paysage', 'valeur': 'suivant'},
        ],
        'un autre paysage': [
          {'op': 'changer', 'cible': 'paysage', 'valeur': 'suivant'},
        ],
        'mets le lac': [
          {'op': 'definir', 'cible': 'paysage', 'valeur': 'lune-lac'},
        ],
        'va sur le torrent de montagne': [
          {'op': 'definir', 'cible': 'paysage', 'valeur': 'torrent-montagne'},
        ],
        'mets le paysage aurore boréale': [
          {'op': 'definir', 'cible': 'paysage', 'valeur': 'aurore-boreale'},
        ],
        'mets le sous-bois': [
          {'op': 'definir', 'cible': 'paysage', 'valeur': 'sous-bois'},
        ],
        "mets l'aube": [
          {'op': 'definir', 'cible': 'moment', 'valeur': 'aube'},
        ],
        'mets le jour': [
          {'op': 'definir', 'cible': 'moment', 'valeur': 'jour'},
        ],
        'il fait jour': [
          {'op': 'definir', 'cible': 'moment', 'valeur': 'jour'},
        ],
      });
    });

    test('timer phrasings', () {
      expectParsed({
        'mets un minuteur de deux heures': [
          timer({'mode': 'duree', 'minutes': 120}),
        ],
        'minuteur trente minutes': [
          timer({'mode': 'duree', 'minutes': 30}),
        ],
        "arrête dans un quart d'heure": [
          timer({'mode': 'duree', 'minutes': 15}),
        ],
        'coupe dans une demi-heure': [
          timer({'mode': 'duree', 'minutes': 30}),
        ],
        'joue toute la nuit': [
          timer({'mode': 'nuit'}),
        ],
        'enlève le minuteur': [
          timer({'mode': 'aucun'}),
        ],
        'pas de minuteur': [
          timer({'mode': 'aucun'}),
        ],
      });
      // Beyond 600 minutes: not for the rules.
      expect(parse('arrête dans douze heures'), isNull);
    });

    test('playback, sleep, settings, schedules', () {
      expectParsed({
        'mets en pause': [
          {'op': 'lecture', 'valeur': 'pause'},
        ],
        'coupe le son': [
          {'op': 'lecture', 'valeur': 'pause'},
        ],
        'continue': [
          {'op': 'lecture', 'valeur': 'reprise'},
        ],
        'désactive le suivi du sommeil': [
          {'op': 'definir', 'cible': 'sommeil.suivi', 'valeur': false},
        ],
        'lance la nuit': [
          {'op': 'commencer_nuit'},
        ],
        'mets le texte plus petit': [setting('taille_texte', 'moins')],
        'agrandis le texte': [setting('taille_texte', 'plus')],
        'désactive le contraste renforcé': [
          setting('contraste_renforce', false),
        ],
        "désactive l'écran noir": [setting('ecran_noir_minuteur', false)],
        'téléchargements en Wi-Fi seulement': [setting('wifi_seulement', true)],
        'active ma programmation': [
          {
            'op': 'activer',
            'cible': 'programmation',
            'selecteur': {'id': 'a1b2'},
          },
        ],
        'supprime la programmation pour me détendre': [
          {
            'op': 'supprimer',
            'cible': 'programmation',
            'selecteur': {'rappel': 'detente'},
          },
        ],
        'désactive la programmation de l’après-midi': [
          {
            'op': 'desactiver',
            'cible': 'programmation',
            'selecteur': {'moment_journee': 'apres-midi'},
          },
        ],
        'Décale ma programmation à vingt-deux heures trente': [
          {
            'op': 'modifier',
            'cible': 'programmation',
            'selecteur': {'id': 'a1b2'},
            'valeur': {'heure': '22:30'},
          },
        ],
        'Décale ma programmation de vingt-deux heures à vingt-trois heures': [
          {
            'op': 'modifier',
            'cible': 'programmation',
            'selecteur': {'heure': '22:00'},
            'valeur': {'heure': '23:00'},
          },
        ],
        'envoie mon mix à mon frère': [
          {'op': 'partager'},
        ],
      });
    });

    test('« ma programmation » is ambiguous with several schedules', () {
      final two = snapshot.copyWith(
        schedules: [
          oneSchedule,
          oneSchedule.copyWith(id: 'b', hour: 7),
        ],
      );
      expect(parse('désactive ma programmation', two), isNull);
      expect(
        parse('active ma programmation', snapshot.copyWith(schedules: [])),
        isNull,
      );
      expect(parse('désactive ma programmation de 7 h', two), [
        {
          'op': 'desactiver',
          'cible': 'programmation',
          'selecteur': {'heure': '07:00'},
        },
      ]);
    });

    test('politeness and fillers', () {
      expectParsed({
        "Eventide, ajoute du vent s'il te plaît": [
          layer('ajouter', 'son', 'vent', 'niveau', 50),
        ],
        'Tu peux mettre la pluie à cinquante pour cent ?': [
          layer('regler', 'son', 'pluie-douce', 'niveau', 50),
        ],
        'est-ce que tu peux baisser les oiseaux, merci': [
          layer('ajuster', 'son', 'oiseaux', 'delta', -20),
        ],
        'ok pause': [
          {'op': 'lecture', 'valeur': 'pause'},
        ],
      });
    });

    test('purchases are always refused', () {
      for (final phrase in [
        'achète le premium',
        'abonne-moi',
        'je veux m’abonner à l’annuel',
        'résilie mon abonnement',
        'annule mon abonnement et mets la pluie',
        'rembourse-moi',
        'efface mon compte',
        'supprime mes données',
      ]) {
        expect(parse(phrase), [
          {'op': 'refuser', 'raison': 'interdit'},
        ], reason: phrase);
      }
    });
  });

  group('conservative: unknown content goes to the model', () {
    for (final phrase in [
      '',
      'merci',
      'mets quelque chose de calme',
      'ajoute un dragon',
      'monte le son',
      'plus fort',
      'baisse',
      'mets les étoiles', // decor or landscape « Ciel étoilé »: ambiguous
      'ajoute la cascade', // a landscape, not an element
      'je n’arrive pas à dormir',
      'mets la pluie à 150 %',
      'mets la pluie à 70 % pendant que je lis',
      'raconte-moi une histoire',
      'arrête à vingt-deux heures',
      'programme la cascade',
      'change la musique',
      'mets le volume à 50 %',
    ]) {
      test(phrase.isEmpty ? '(empty)' : phrase, () {
        expect(parse(phrase), isNull, reason: phrase);
      });
    }
  });

  test('an alias shared by kinds resolves to the playing one', () {
    // « oiseaux » is only a sound; « oiseaux en vol » is the decor.
    expect(parse('enlève les oiseaux en vol'), [
      layer('retirer', 'decor', 'oiseaux-vol'),
    ]);
    expect(parse('enlève les oiseaux'), [layer('retirer', 'son', 'oiseaux')]);
  });

  test('a free user asking for a Premium sound goes through validation', () {
    final ops = parse('ajoute du tonnerre')!;
    expect(ops, [layer('ajouter', 'son', 'tonnerre', 'niveau', 50)]);
    expect(validateOps(ops, catalog, Plan.free), [
      {'op': 'ouvrir', 'cible': 'premium'},
    ]);
  });

  test('every catalog alias is understood after « ajoute »', () {
    for (final kind in LayerKind.values) {
      for (final item in catalog.items(kind)) {
        for (final alias in item.aliases) {
          final ops = parse('ajoute $alias');
          expect(ops, isNotNull, reason: alias);
          expect(ops!.single['id'], item.id, reason: alias);
        }
      }
    }
  });
}
