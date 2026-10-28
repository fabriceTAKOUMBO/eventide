import 'package:eventide/core/french_normalizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  void expectNormalized(Map<String, String> cases) {
    cases.forEach((input, expected) {
      expect(normalizeFrench(input), expected, reason: input);
    });
  }

  group('cleanup', () {
    test('lowercase, apostrophes, spaces and punctuation', () {
      expectNormalized({
        'Mets l’eau vive, STP !': "mets l'eau vive stp",
        '  Pause.  ': 'pause',
        'Quelle heure est-il ?': 'quelle heure est-il',
        'Ajoute du   piano « doux »': 'ajoute du piano doux',
        'Passe-moi en Premium': 'passe-moi en premium',
        '': '',
        '   ': '',
      });
    });

    test('keeps hyphenated words that are not numbers', () {
      expectNormalized({
        'mets le sous-bois': 'mets le sous-bois',
        'le week-end': 'le week-end',
        "l'après-midi": "l'après-midi",
      });
    });
  });

  group('numbers', () {
    test('standard French', () {
      expectNormalized({
        'zéro': '0',
        'deux': '2',
        'dix-sept': '17',
        'vingt et un': '21',
        'vingt-et-un': '21',
        'vingt-deux': '22',
        'vingt deux': '22',
        'trente-et-une': '31',
        'quarante-cinq': '45',
        'soixante': '60',
        'soixante-dix': '70',
        'soixante et onze': '71',
        'soixante-douze': '72',
        'soixante-dix-neuf': '79',
        'quatre-vingts': '80',
        'quatre-vingt': '80',
        'quatre vingt': '80',
        'quatre-vingt-un': '81',
        'quatre-vingt-dix': '90',
        'quatre-vingt-onze': '91',
        'quatre-vingt-dix-neuf': '99',
        'cent': '100',
        'cent un': '101',
        'cent vingt': '120',
        'deux cents': '200',
        'trois cent quatre-vingt-dix-neuf': '399',
        'neuf cent quatre-vingt-dix-neuf': '999',
        'mille': '1000',
        'deux mille vingt-six': '2026',
      });
    });

    test('Belgian and Swiss numbers', () {
      expectNormalized({
        'septante': '70',
        'septante et un': '71',
        'septante-deux': '72',
        'septante-cinq': '75',
        'huitante': '80',
        'octante': '80',
        'huitante-deux': '82',
        'nonante': '90',
        'nonante et un': '91',
        'nonante-neuf': '99',
        'cent septante': '170',
        'neuf cent nonante-neuf': '999',
      });
    });

    test('adjacent numbers stay separate', () {
      expectNormalized({'vingt-deux trente': '22 30', 'deux trois': '2 3'});
    });

    test('« un » and « une » are articles unless a unit follows', () {
      expectNormalized({
        'ajoute un peu de pluie': 'ajoute un peu de pluie',
        'mets une ambiance': 'mets une ambiance',
        'un %': '1 %',
      });
    });
  });

  group('percentages', () {
    test('pour cent, pour 100, %', () {
      expectNormalized({
        "mets l'eau vive à 70 pour cent": "mets l'eau vive à 70 %",
        'mets la pluie à septante pour cent': 'mets la pluie à 70 %',
        'mets la pluie à 70 pour 100': 'mets la pluie à 70 %',
        'mets la pluie à 70%': 'mets la pluie à 70 %',
        'mets la pluie à 70 %': 'mets la pluie à 70 %',
        'nonante pourcent': '90 %',
        'cent pour cent': '100 %',
        'quatre-vingts pour cent': '80 %',
      });
    });
  });

  group('clock times', () {
    test('spoken hours', () {
      expectNormalized({
        'vingt-deux heures': '22:00',
        'à vingt-deux heures': 'à 22:00',
        'dix heures et demie': '10:30',
        'une heure et quart': '1:15',
        'à une heure et demie': 'à 1:30',
        'sept heures moins le quart': '6:45',
        'sept heures moins quart': '6:45',
        'sept heures moins dix': '6:50',
        'treize heures trente': '13:30',
        '13 heures trente': '13:30',
        'dix-neuf heures quarante-cinq': '19:45',
        'vingt-deux heures quinze minutes': '22:15',
        'deux heures': '2:00',
        'une heure moins le quart': '0:45',
      });
    });

    test('written forms produced by speech recognition', () {
      expectNormalized({
        '22 h 30': '22:30',
        '22h30': '22:30',
        '22h': '22:00',
        'à 22 h': 'à 22:00',
        '22:30': '22:30',
        '07:30': '7:30',
        'à 7 h moins 10': 'à 6:50',
      });
    });

    test('midi and minuit', () {
      expectNormalized({
        'midi': '12:00',
        'à midi et demi': 'à 12:30',
        'midi et quart': '12:15',
        'midi moins le quart': '11:45',
        'minuit': '0:00',
        'minuit et demie': '0:30',
        'minuit moins le quart': '23:45',
        "l'après midi": "l'après midi",
      });
    });

    test('annex B schedule phrases', () {
      expectNormalized({
        'Programme la pluie tous les soirs à vingt-deux heures':
            'programme la pluie tous les soirs à 22:00',
        'Chaque jour de la semaine à treize heures trente, pour me détendre':
            'chaque jour de la semaine à 13:30 pour me détendre',
        'Désactive ma programmation de vingt-deux heures':
            'désactive ma programmation de 22:00',
        'Décale ma programmation à vingt-deux heures trente':
            'décale ma programmation à 22:30',
      });
    });
  });

  group('durations', () {
    test('after dans / pendant / minuteur', () {
      expectNormalized({
        'Arrête dans une heure': 'arrête dans 60 min',
        'Minuteur une heure et demie': 'minuteur 90 min',
        'arrête dans deux heures': 'arrête dans 120 min',
        'pendant deux heures': 'pendant 120 min',
        'minuteur deux heures': 'minuteur 120 min',
        'un minuteur de deux heures': 'un minuteur de 120 min',
        "un minuteur d'une heure": 'un minuteur de 60 min',
        'mets le minuteur à une heure': 'mets le minuteur à 60 min',
        'dans 1 h 30': 'dans 90 min',
        'dans une heure et quart': 'dans 75 min',
        'dans 1h30': 'dans 90 min',
        'pendant trois heures moins le quart': 'pendant 165 min',
        'encore une heure': 'encore 60 min',
      });
    });

    test('bare « une heure (et demie) » is a duration', () {
      expectNormalized({
        'une heure et demie': '90 min',
        'une heure': '60 min',
        'pour une heure': 'pour 60 min',
      });
    });

    test('minutes, half and quarter hours', () {
      expectNormalized({
        'dans vingt minutes': 'dans 20 min',
        'une minute': '1 min',
        'arrête dans quarante-cinq minutes': 'arrête dans 45 min',
        'dans 10min': 'dans 10 min',
        'une demi-heure': '30 min',
        'pendant une demi heure': 'pendant 30 min',
        "un quart d'heure": '15 min',
        "dans un quart d'heure": 'dans 15 min',
        "trois quarts d'heure": '45 min',
        'dans nonante minutes': 'dans 90 min',
      });
    });
  });

  test('normalization is idempotent', () {
    for (final input in [
      'Arrête dans une heure',
      'à vingt-deux heures trente',
      'mets la pluie à septante pour cent',
      'une heure et quart',
      'minuit moins le quart',
      'pendant une demi-heure',
      'tous les soirs à 22 h',
    ]) {
      final once = normalizeFrench(input);
      expect(normalizeFrench(once), once, reason: input);
    }
  });

  group('parseDurationMinutes', () {
    test('reads the first duration', () {
      expect(
        parseDurationMinutes(normalizeFrench('arrête dans une heure')),
        60,
      );
      expect(
        parseDurationMinutes(normalizeFrench('minuteur une heure et demie')),
        90,
      );
      expect(
        parseDurationMinutes(normalizeFrench('pendant une demi-heure')),
        30,
      );
      expect(parseDurationMinutes(normalizeFrench("un quart d'heure")), 15);
      expect(parseDurationMinutes(normalizeFrench('dans deux heures')), 120);
    });

    test('null without a duration', () {
      expect(parseDurationMinutes(normalizeFrench('toute la nuit')), isNull);
      expect(
        parseDurationMinutes(normalizeFrench('à vingt-deux heures')),
        isNull,
      );
      expect(parseDurationMinutes(''), isNull);
    });
  });

  group('parseClockTime', () {
    test('reads the first clock time', () {
      expect(parseClockTime(normalizeFrench('à vingt-deux heures')), (
        hour: 22,
        minute: 0,
      ));
      expect(parseClockTime(normalizeFrench('dix heures et demie')), (
        hour: 10,
        minute: 30,
      ));
      expect(parseClockTime(normalizeFrench('une heure et quart')), (
        hour: 1,
        minute: 15,
      ));
      expect(parseClockTime(normalizeFrench('sept heures moins le quart')), (
        hour: 6,
        minute: 45,
      ));
      expect(parseClockTime(normalizeFrench('à minuit')), (hour: 0, minute: 0));
      expect(parseClockTime(normalizeFrench('à midi')), (hour: 12, minute: 0));
    });

    test('null without a clock time or out of range', () {
      expect(parseClockTime(normalizeFrench('arrête dans une heure')), isNull);
      expect(parseClockTime('25:00'), isNull);
      expect(parseClockTime('22:75'), isNull);
    });
  });

  group('parseDays', () {
    Set<int>? days(String s) => parseDays(normalizeFrench(s));

    test('every day', () {
      for (final s in [
        'tous les jours',
        'tous les soirs à 22 h',
        'chaque soir',
        'chaque jour',
        'toutes les nuits',
      ]) {
        expect(days(s), {1, 2, 3, 4, 5, 6, 7}, reason: s);
      }
    });

    test('weekdays', () {
      for (final s in [
        'en semaine',
        'chaque jour de la semaine à treize heures trente',
        'tous les jours de la semaine',
        'du lundi au vendredi',
      ]) {
        expect(days(s), {1, 2, 3, 4, 5}, reason: s);
      }
    });

    test('week-end', () {
      for (final s in [
        'le week-end',
        'le weekend',
        'les week-ends',
        'samedi et dimanche',
      ]) {
        expect(days(s), {6, 7}, reason: s);
      }
    });

    test('named days, ranges and exceptions', () {
      expect(days('le lundi et le jeudi'), {1, 4});
      expect(days('les mardis'), {2});
      expect(days('du vendredi au lundi'), {5, 6, 7, 1});
      expect(days('du mardi au jeudi'), {2, 3, 4});
      expect(days('tous les jours sauf le dimanche'), {1, 2, 3, 4, 5, 6});
      expect(days('tous les jours sauf le week-end'), {1, 2, 3, 4, 5});
      expect(days('sauf le mercredi'), {1, 2, 4, 5, 6, 7});
    });

    test('null when no day is named', () {
      expect(days('à vingt-deux heures'), isNull);
      expect(days('mets la pluie'), isNull);
    });
  });

  test('foldFrench removes diacritics', () {
    expect(
      foldFrench('Forêt Étoilée, Boîte à musique, sœur, Flûte, ça'),
      'foret etoilee, boite a musique, soeur, flute, ca',
    );
  });
}
