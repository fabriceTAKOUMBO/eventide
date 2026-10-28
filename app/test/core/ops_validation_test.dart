import 'dart:convert';
import 'dart:io';

import 'package:eventide/core/ops.dart';
import 'package:eventide/core/plan.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

/// Vectors shared with the API (`shared/test-vectors/ops-validation.json`):
/// a list of `{name, plan, ops_in, ops_out}` (or `{"cases": [...]}`).
final File _vectors = File('../shared/test-vectors/ops-validation.json');

void main() {
  final catalog = loadCatalog();
  List<Map<String, dynamic>> free(List<dynamic> ops) =>
      validateOps(ops, catalog, Plan.free);
  List<Map<String, dynamic>> premium(List<dynamic> ops) =>
      validateOps(ops, catalog, Plan.annual);
  final rephrase = [
    {'op': 'reformuler', 'raison': 'incompris'},
  ];
  final open = [
    {'op': 'ouvrir', 'cible': 'premium'},
  ];
  final forbidden = [
    {'op': 'refuser', 'raison': 'interdit'},
  ];

  group('canonical valid operations pass unchanged', () {
    final valid = <Map<String, dynamic>>[
      {'op': 'definir', 'cible': 'paysage', 'valeur': 'cascade-foret'},
      {'op': 'changer', 'cible': 'paysage', 'valeur': 'suivant'},
      {'op': 'changer', 'cible': 'paysage', 'valeur': 'precedent'},
      {'op': 'definir', 'cible': 'moment', 'valeur': 'nuit'},
      {'op': 'ajouter', 'cible': 'musique', 'id': 'piano-doux', 'niveau': 50},
      {'op': 'ajouter', 'cible': 'decor', 'id': 'brume', 'niveau': 30},
      {'op': 'ajouter', 'cible': 'decor', 'id': 'brume', 'niveau': 0},
      {'op': 'retirer', 'cible': 'son', 'id': 'vent'},
      {'op': 'retirer', 'cible': 'musique', 'id': '*'},
      {'op': 'couper', 'cible': 'musique'},
      {'op': 'couper', 'cible': 'son'},
      {'op': 'remettre', 'cible': 'musique'},
      {'op': 'remettre', 'cible': 'son'},
      {'op': 'regler', 'cible': 'son', 'id': 'eau-vive', 'niveau': 70},
      {'op': 'regler', 'cible': 'son', 'id': 'eau-vive', 'niveau': 0},
      {'op': 'regler', 'cible': 'son', 'id': 'eau-vive', 'niveau': 100},
      {'op': 'ajuster', 'cible': 'son', 'id': 'oiseaux', 'delta': -20},
      {'op': 'ajuster', 'cible': 'son', 'id': 'oiseaux', 'delta': 100},
      {'op': 'ajuster', 'cible': 'son', 'id': 'oiseaux', 'delta': -100},
      {
        'op': 'definir',
        'cible': 'minuteur',
        'valeur': {'mode': 'duree', 'minutes': 60},
      },
      {
        'op': 'definir',
        'cible': 'minuteur',
        'valeur': {'mode': 'duree', 'minutes': 600},
      },
      {
        'op': 'definir',
        'cible': 'minuteur',
        'valeur': {'mode': 'nuit'},
      },
      {
        'op': 'definir',
        'cible': 'minuteur',
        'valeur': {'mode': 'aucun'},
      },
      {'op': 'lecture', 'valeur': 'pause'},
      {'op': 'lecture', 'valeur': 'reprise'},
      {
        'op': 'creer',
        'cible': 'programmation',
        'valeur': {
          'heure': '22:00',
          'jours': [1, 2, 3, 4, 5, 6, 7],
          'montee_minutes': 10,
          'paysage': 'cascade-foret',
          'rappel': 'dormir',
        },
      },
      {
        'op': 'creer',
        'cible': 'programmation',
        'valeur': {
          'heure': '00:00',
          'jours': [6, 7],
          'montee_minutes': 60,
          'rappel': 'detente',
        },
      },
      {
        'op': 'modifier',
        'cible': 'programmation',
        'selecteur': {'heure': '22:00'},
        'valeur': {'heure': '22:30'},
      },
      {
        'op': 'modifier',
        'cible': 'programmation',
        'selecteur': {'id': 'a1b2'},
        'valeur': {
          'jours': [1, 2],
          'montee_minutes': 5,
          'rappel': 'detente',
        },
      },
      {
        'op': 'activer',
        'cible': 'programmation',
        'selecteur': {'id': 'a1b2'},
      },
      {
        'op': 'desactiver',
        'cible': 'programmation',
        'selecteur': {'rappel': 'dormir'},
      },
      {
        'op': 'supprimer',
        'cible': 'programmation',
        'selecteur': {'moment_journee': 'matin'},
      },
      {
        'op': 'supprimer',
        'cible': 'programmation',
        'selecteur': {'moment_journee': 'apres-midi'},
      },
      {'op': 'definir', 'cible': 'sommeil.suivi', 'valeur': true},
      {'op': 'commencer_nuit'},
      {
        'op': 'definir',
        'cible': 'reglage',
        'cle': 'taille_texte',
        'valeur': 'plus',
      },
      {
        'op': 'definir',
        'cible': 'reglage',
        'cle': 'taille_texte',
        'valeur': 'moins',
      },
      {'op': 'definir', 'cible': 'reglage', 'cle': 'taille_texte', 'valeur': 2},
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
        'valeur': false,
      },
      {
        'op': 'definir',
        'cible': 'reglage',
        'cle': 'wifi_seulement',
        'valeur': true,
      },
      {'op': 'partager'},
      {'op': 'ouvrir', 'cible': 'premium'},
      {'op': 'reformuler', 'raison': 'ambigu'},
      {'op': 'reformuler', 'raison': 'incompris'},
      {'op': 'refuser', 'raison': 'hors_catalogue'},
      {'op': 'refuser', 'raison': 'interdit'},
    ];
    for (final op in valid) {
      test(
        '${op['op']} ${op['cible'] ?? ''} ${op['valeur'] ?? op['id'] ?? ''}',
        () {
          expect(premium([op]), [op]);
          // Validation is idempotent.
          expect(premium(premium([op])), [op]);
        },
      );
    }
  });

  group('invalid operations are removed', () {
    final invalid = <Object?>[
      null,
      'pause',
      42,
      {'cible': 'paysage'},
      {'op': 42},
      {'op': 'voler'},
      {'op': 'definir', 'cible': 'paysage', 'valeur': 'plage-tropicale'},
      {'op': 'definir', 'cible': 'paysage'},
      {'op': 'definir', 'cible': 'volume', 'valeur': 50},
      {'op': 'definir', 'cible': 'moment', 'valeur': 'midi'},
      {'op': 'changer', 'cible': 'paysage', 'valeur': 'aleatoire'},
      {'op': 'changer', 'cible': 'moment', 'valeur': 'suivant'},
      {'op': 'ajouter', 'cible': 'son', 'id': 'licorne'},
      {'op': 'ajouter', 'cible': 'son', 'id': 'piano-doux'},
      {'op': 'ajouter', 'cible': 'son', 'id': '*'},
      {'op': 'ajouter', 'cible': 'bruit', 'id': 'vent'},
      {'op': 'ajouter', 'cible': 'son', 'id': 'vent', 'niveau': 101},
      {'op': 'ajouter', 'cible': 'son', 'id': 'vent', 'niveau': -1},
      {'op': 'ajouter', 'cible': 'son', 'id': 'vent', 'niveau': 'fort'},
      {'op': 'ajouter', 'cible': 'son', 'id': 'vent', 'niveau': null},
      {'op': 'retirer', 'cible': 'son', 'id': 'licorne'},
      {'op': 'retirer', 'cible': 'son'},
      {'op': 'regler', 'cible': 'son', 'id': 'vent'},
      {'op': 'regler', 'cible': 'son', 'id': 'vent', 'niveau': 150},
      {'op': 'regler', 'cible': 'son', 'id': 'vent', 'niveau': 50.5},
      {'op': 'regler', 'cible': 'son', 'id': 'vent', 'niveau': 50.0},
      {'op': 'regler', 'cible': 'son', 'id': 'vent', 'niveau': true},
      {'op': 'regler', 'cible': 'son', 'id': 'vent', 'niveau': '50'},
      {'op': 'ajuster', 'cible': 'son', 'id': 'vent'},
      {'op': 'ajuster', 'cible': 'son', 'id': 'vent', 'delta': 101},
      {'op': 'ajuster', 'cible': 'son', 'id': 'vent', 'delta': -101},
      {
        'op': 'definir',
        'cible': 'minuteur',
        'valeur': {'mode': 'duree', 'minutes': 0},
      },
      {
        'op': 'definir',
        'cible': 'minuteur',
        'valeur': {'mode': 'duree', 'minutes': 601},
      },
      {'op': 'definir', 'cible': 'minuteur', 'valeur': 60},
      {'op': 'lecture', 'valeur': 'stop'},
      {
        'op': 'creer',
        'cible': 'programmation',
        'valeur': {
          'jours': [1],
        },
      },
      {
        'op': 'creer',
        'cible': 'programmation',
        'valeur': {'heure': '22:00'},
      },
      for (final patch in <Map<String, dynamic>>[
        {'heure': '24:00'},
        {'heure': '22h'},
        {'heure': '7:30'},
        {'heure': null},
        {'jours': []},
        {
          'jours': [0],
        },
        {
          'jours': [8],
        },
        {
          'jours': [1.0],
        },
        {'jours': 'tous'},
        {'montee_minutes': 12},
        {'montee_minutes': 65},
        {'montee_minutes': 0},
        {'montee_minutes': 10.0},
        {'paysage': 'plage'},
        {'rappel': 'reveil'},
      ])
        {
          'op': 'creer',
          'cible': 'programmation',
          'valeur': {
            'heure': '22:00',
            'jours': [1],
            ...patch,
          },
        },
      {
        'op': 'creer',
        'cible': 'paysage',
        'valeur': {
          'heure': '22:00',
          'jours': [1],
        },
      },
      {
        'op': 'modifier',
        'cible': 'programmation',
        'selecteur': {'heure': '22:00'},
        'valeur': <String, dynamic>{},
      },
      {
        'op': 'modifier',
        'cible': 'programmation',
        'selecteur': {'heure': '22:00'},
        'valeur': {'actif': false},
      },
      {
        'op': 'modifier',
        'cible': 'programmation',
        'selecteur': {'heure': '22:00'},
      },
      {
        'op': 'modifier',
        'cible': 'programmation',
        'valeur': {'heure': '22:30'},
      },
      {'op': 'activer', 'cible': 'programmation'},
      {
        'op': 'activer',
        'cible': 'programmation',
        'selecteur': <String, dynamic>{},
      },
      {
        'op': 'activer',
        'cible': 'programmation',
        'selecteur': {'heure': '22:00', 'rappel': 'dormir'},
      },
      {
        'op': 'activer',
        'cible': 'programmation',
        'selecteur': {'id': 'x' * 65},
      },
      {
        'op': 'desactiver',
        'cible': 'programmation',
        'selecteur': {'heure': '22h'},
      },
      {
        'op': 'supprimer',
        'cible': 'programmation',
        'selecteur': {'moment_journee': 'nuit'},
      },
      {
        'op': 'supprimer',
        'cible': 'programmation',
        'selecteur': {'rappel': 'reveil'},
      },
      {'op': 'definir', 'cible': 'sommeil.suivi', 'valeur': 'oui'},
      {'op': 'definir', 'cible': 'reglage', 'cle': 'taille_texte', 'valeur': 3},
      {
        'op': 'definir',
        'cible': 'reglage',
        'cle': 'contraste_renforce',
        'valeur': 1,
      },
      {
        'op': 'definir',
        'cible': 'reglage',
        'cle': 'luminosite',
        'valeur': true,
      },
      {'op': 'ouvrir', 'cible': 'reglages'},
    ];
    for (final op in invalid) {
      test('$op', () {
        expect(premium([op]), rephrase);
        expect(free([op]), rephrase);
      });
    }
  });

  group('forbidden operations refuse the whole list', () {
    for (final op in <Map<String, dynamic>>[
      {'op': 'acheter', 'cible': 'premium'},
      {'op': 'souscrire'},
      {'op': 'abonner'},
      {'op': 'resilier', 'cible': 'abonnement'},
      {'op': 'supprimer', 'cible': 'compte'},
      {'op': 'supprimer_compte'},
      {'op': 'rembourser'},
      {'op': 'activer', 'cible': 'premium'},
      {'op': 'definir', 'cible': 'paiement', 'valeur': 'carte'},
      {'op': 'partager', 'cible': 'compte'},
    ]) {
      test('$op', () {
        expect(
          premium([
            {'op': 'lecture', 'valeur': 'pause'},
            op,
          ]),
          forbidden,
        );
      });
    }

    test('only within the first 10 operations', () {
      final ops = [
        for (var i = 0; i < 10; i++)
          {'op': 'ajuster', 'cible': 'son', 'id': 'vent', 'delta': i + 1},
        {'op': 'acheter'},
      ];
      expect(premium(ops), hasLength(10));
      expect(
        premium([
          {'op': 'acheter'},
          ...ops,
        ]),
        forbidden,
      );
    });
  });

  test('an empty or non-list input becomes reformuler incompris', () {
    expect(premium(const []), rephrase);
    expect(free(const []), rephrase);
    expect(validateOpsJson({'op': 'partager'}, catalog, Plan.free), rephrase);
    expect(validateOpsJson(null, catalog, Plan.free), rephrase);
    expect(
      validateOpsJson(
        [
          {'op': 'partager'},
        ],
        catalog,
        Plan.free,
      ),
      [
        {'op': 'partager'},
      ],
    );
  });

  test('invalid operations are removed, valid ones kept in order', () {
    expect(
      premium([
        {'op': 'lecture', 'valeur': 'pause'},
        {'op': 'danser'},
        {'op': 'ajouter', 'cible': 'son', 'id': 'pluie-douce', 'niveau': 40},
      ]),
      [
        {'op': 'lecture', 'valeur': 'pause'},
        {'op': 'ajouter', 'cible': 'son', 'id': 'pluie-douce', 'niveau': 40},
      ],
    );
  });

  group('rights of the free plan', () {
    test('a Premium landscape opens Premium', () {
      final op = {'op': 'definir', 'cible': 'paysage', 'valeur': 'lune-lac'};
      expect(free([op]), open);
      expect(premium([op]), [op]);
      expect(validateOps([op], catalog, Plan.lifetime), [op]);
      expect(validateOps([op], catalog, Plan.monthly), [op]);
    });

    test('Premium sounds, music and decor open Premium', () {
      for (final op in [
        {'op': 'ajouter', 'cible': 'son', 'id': 'tonnerre', 'niveau': 50},
        {'op': 'regler', 'cible': 'musique', 'id': 'harpe', 'niveau': 40},
        {'op': 'ajuster', 'cible': 'decor', 'id': 'neige', 'delta': 20},
      ]) {
        expect(free([op]), open, reason: '$op');
        expect(premium([op]), [op], reason: '$op');
      }
    });

    test('an invalid Premium request stays invalid', () {
      expect(
        free([
          {'op': 'regler', 'cible': 'son', 'id': 'tonnerre', 'niveau': 200},
        ]),
        rephrase,
      );
      expect(
        free([
          {
            'op': 'creer',
            'cible': 'programmation',
            'valeur': {'heure': '22:00', 'paysage': 'pluie-ville'},
          },
        ]),
        rephrase,
      );
    });

    test('removing a Premium element is allowed', () {
      final op = {'op': 'retirer', 'cible': 'son', 'id': 'tonnerre'};
      expect(free([op]), [op]);
    });

    test('a schedule on a Premium landscape opens Premium', () {
      final op = {
        'op': 'creer',
        'cible': 'programmation',
        'valeur': {
          'heure': '22:00',
          'jours': [1, 2, 3, 4, 5, 6, 7],
          'paysage': 'pluie-ville',
        },
      };
      expect(free([op]), open);
      expect(premium([op]), [
        {
          'op': 'creer',
          'cible': 'programmation',
          'valeur': {
            'heure': '22:00',
            'jours': [1, 2, 3, 4, 5, 6, 7],
            'paysage': 'pluie-ville',
            'montee_minutes': 10,
            'rappel': 'dormir',
          },
        },
      ]);
      final modify = {
        'op': 'modifier',
        'cible': 'programmation',
        'selecteur': {'id': 'a'},
        'valeur': {'paysage': 'ciel-etoile'},
      };
      expect(free([modify]), open);
      expect(premium([modify]), [modify]);
    });

    test('replacements in place, one « ouvrir » at most', () {
      expect(
        free([
          {'op': 'ajouter', 'cible': 'son', 'id': 'tonnerre'},
          {'op': 'ajouter', 'cible': 'son', 'id': 'pluie-douce'},
          {'op': 'ajouter', 'cible': 'decor', 'id': 'neige'},
          {'op': 'ouvrir', 'cible': 'premium'},
        ]),
        [
          {'op': 'ouvrir', 'cible': 'premium'},
          {'op': 'ajouter', 'cible': 'son', 'id': 'pluie-douce', 'niveau': 50},
        ],
      );
    });
  });

  group('normalization', () {
    test('defaults are filled', () {
      expect(
        premium([
          {'op': 'ajouter', 'cible': 'son', 'id': 'vent'},
          {
            'op': 'creer',
            'cible': 'programmation',
            'valeur': {
              'heure': '13:30',
              'jours': [5, 1, 3, 1],
              'id': 'x',
              'actif': false,
              'couleur': 'bleu',
            },
          },
        ]),
        [
          {'op': 'ajouter', 'cible': 'son', 'id': 'vent', 'niveau': 50},
          {
            'op': 'creer',
            'cible': 'programmation',
            'valeur': {
              'heure': '13:30',
              'jours': [1, 3, 5],
              'montee_minutes': 10,
              'rappel': 'dormir',
            },
          },
        ],
      );
    });

    test('unexpected fields are dropped', () {
      expect(
        premium([
          {
            'op': 'regler',
            'cible': 'son',
            'id': 'vent',
            'niveau': 40,
            'delta': 5,
            'commentaire': 'x',
          },
          {'op': 'lecture', 'cible': 'son', 'valeur': 'pause'},
          {'op': 'commencer_nuit', 'cible': 'minuteur', 'valeur': 'nuit'},
          {
            'op': 'definir',
            'cible': 'minuteur',
            'valeur': {'mode': 'nuit', 'minutes': 30},
          },
          {
            'op': 'supprimer',
            'cible': 'programmation',
            'selecteur': {'id': 'a', 'couleur': 'bleu'},
          },
        ]),
        [
          {'op': 'regler', 'cible': 'son', 'id': 'vent', 'niveau': 40},
          {'op': 'lecture', 'valeur': 'pause'},
          {'op': 'commencer_nuit'},
          {
            'op': 'definir',
            'cible': 'minuteur',
            'valeur': {'mode': 'nuit'},
          },
          {
            'op': 'supprimer',
            'cible': 'programmation',
            'selecteur': {'id': 'a'},
          },
        ],
      );
    });

    test('reasons are coerced', () {
      expect(
        premium([
          {'op': 'reformuler'},
        ]),
        rephrase,
      );
      expect(
        premium([
          {'op': 'reformuler', 'raison': 'bruit'},
        ]),
        rephrase,
      );
      expect(
        premium([
          {'op': 'refuser'},
        ]),
        [
          {'op': 'refuser', 'raison': 'hors_catalogue'},
        ],
      );
      expect(
        premium([
          {'op': 'refuser', 'raison': 'flemme'},
        ]),
        [
          {'op': 'refuser', 'raison': 'hors_catalogue'},
        ],
      );
    });

    test('exact duplicates are removed after normalization', () {
      expect(
        premium([
          {'op': 'ajouter', 'cible': 'son', 'id': 'vent'},
          {'op': 'ajouter', 'cible': 'son', 'id': 'vent', 'niveau': 50},
          {'op': 'lecture', 'valeur': 'pause'},
          {'op': 'lecture', 'cible': 'x', 'valeur': 'pause'},
          {
            'op': 'creer',
            'cible': 'programmation',
            'valeur': {
              'heure': '22:00',
              'jours': [2, 1],
            },
          },
          {
            'op': 'creer',
            'cible': 'programmation',
            'valeur': {
              'rappel': 'dormir',
              'jours': [1, 2],
              'heure': '22:00',
            },
          },
        ]),
        [
          {'op': 'ajouter', 'cible': 'son', 'id': 'vent', 'niveau': 50},
          {'op': 'lecture', 'valeur': 'pause'},
          {
            'op': 'creer',
            'cible': 'programmation',
            'valeur': {
              'heure': '22:00',
              'jours': [1, 2],
              'montee_minutes': 10,
              'rappel': 'dormir',
            },
          },
        ],
      );
    });

    test('only the first 10 operations are read', () {
      final ops = [
        for (var i = 1; i <= 12; i++)
          {'op': 'regler', 'cible': 'son', 'id': 'vent', 'niveau': i},
      ];
      expect(premium(ops).map((o) => o['niveau']), [
        1,
        2,
        3,
        4,
        5,
        6,
        7,
        8,
        9,
        10,
      ]);
    });

    test('the input list is not modified', () {
      final input = [
        {'op': 'ajouter', 'cible': 'son', 'id': 'vent', 'x': 1},
      ];
      premium(input);
      expect(input.single, {
        'op': 'ajouter',
        'cible': 'son',
        'id': 'vent',
        'x': 1,
      });
    });
  });

  group('shared test vectors', () {
    final exists = _vectors.existsSync();
    test(
      'every vector of ops-validation.json',
      () {
        final decoded = jsonDecode(_vectors.readAsStringSync());
        final cases = (decoded is Map ? decoded['cases'] : decoded) as List;
        expect(cases, isNotEmpty);
        for (final raw in cases) {
          final c = raw as Map<String, dynamic>;
          final plan = Plan.fromId(c['plan']);
          final out = validateOpsJson(c['ops_in'], catalog, plan);
          expect(out, c['ops_out'], reason: '${c['name']}');
        }
      },
      skip: exists
          ? false
          : 'shared/test-vectors/ops-validation.json not found',
    );
  });
}
