// Published catalog (contract § 13): checking a `GET /catalog` answer against the bundled base,
// merging, withdrawn items, items kept for the scene being played, content keys.
import 'package:eventide/core/catalog.dart';
import 'package:eventide/core/landscape_media.dart';
import 'package:eventide/core/published_catalog.dart';
import 'package:eventide/core/scene.dart';
import 'package:eventide/core/share_codec.dart';
import 'package:eventide/services/content_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../services/published_fixtures.dart';
import 'test_helpers.dart';

void main() {
  final base = loadCatalog();

  PublishedCatalog parse(Map<String, dynamic> json) => PublishedCatalog.parse(json, base);

  Matcher rejected(String reason) =>
      throwsA(isA<CatalogRejected>().having((e) => e.reason, 'reason', contains(reason)));

  group('media_rev', () {
    test('an integer >= 1 on landscapes, sounds and music; absent for the base', () {
      final published = parse(catalogResponse());
      final catalog = published.catalog;
      expect(catalog.landscape('lac-brume')!.mediaRev, 2);
      expect(catalog.landscape('lac-brume')!.isPublished, isTrue);
      expect(catalog.item(LayerKind.son, 'ambiance-lac-brume')!.mediaRev, 2);
      expect(catalog.item(LayerKind.musique, 'harpe-celeste')!.mediaRev, 1);
      expect(catalog.landscape('cascade-foret')!.mediaRev, isNull);
      expect(catalog.item(LayerKind.son, 'vent')!.isPublished, isFalse);
      expect(published.revision, 7);
      expect(published.landscapeIds, {'lac-brume'});
      expect(published.itemIds(LayerKind.son), {'ambiance-lac-brume'});
      expect(published.itemIds(LayerKind.musique), {'harpe-celeste'});
    });

    test('anything but an integer >= 1 is no media_rev', () {
      for (final value in [0, -1, '2', 2.5, null, true]) {
        final item = CatalogItem.fromJson({'id': 'x', 'nom': 'X', 'media_rev': value}, LayerKind.son);
        expect(item.mediaRev, isNull, reason: '$value');
      }
      expect(CatalogItem.fromJson({'id': 'x', 'nom': 'X', 'media_rev': 3}, LayerKind.son).mediaRev, 3);
    });
  });

  group('merge', () {
    test('published items come after the base items of their list; the base keeps its order', () {
      final catalog = parse(catalogResponse()).catalog;
      expect(catalog.landscapes.map((l) => l.id).take(base.landscapes.length), base.landscapes.map((l) => l.id));
      expect(catalog.landscapes.last.id, 'lac-brume');
      expect(catalog.landscapesOfTheme('nature').last.id, 'lac-brume');
      expect(catalog.sounds.last.id, 'ambiance-lac-brume');
      expect(catalog.music.last.id, 'harpe-celeste');
      expect(catalog.defaultLandscape.id, 'cascade-foret');
    });

    test('the base is fixed: themes, decors, limits and base items keep the bundled definition', () {
      final json = catalogResponse();
      final received = json['catalog'] as Map<String, dynamic>;
      (received['sons'] as List).firstWhere((s) => s['id'] == 'vent')['nom'] = 'Autre nom';
      (received['sons'] as List).firstWhere((s) => s['id'] == 'vent')['gratuit'] = false;
      (received['themes'] as List).add({'id': 'astral', 'nom': 'Astral'});
      (received['decors'] as List).add({'id': 'nouveau-decor', 'nom': 'Nouveau', 'gratuit': true, 'alias': []});
      received['limites'] = {'couches_max': 12};
      final catalog = parse(json).catalog;
      expect(catalog.item(LayerKind.son, 'vent')!.name, base.item(LayerKind.son, 'vent')!.name);
      expect(catalog.item(LayerKind.son, 'vent')!.free, isTrue);
      expect(catalog.themes.map((t) => t.id), base.themes.map((t) => t.id));
      expect(catalog.item(LayerKind.decor, 'nouveau-decor'), isNull);
      expect(catalog.limits.layersMax, base.limits.layersMax);
    });

    test('the default mix of a published landscape keeps known sounds and music, never a decor', () {
      final lac = parse(catalogResponse()).catalog.landscape('lac-brume')!;
      expect(lac.rendering, LandscapeRendering.video);
      expect(lac.defaultMix[LayerKind.son]!.map((l) => l.id), ['ambiance-lac-brume', 'vent']);
      expect(lac.defaultMix[LayerKind.musique]!.map((l) => l.id), ['harpe-celeste']);
      expect(lac.defaultMix[LayerKind.decor], isEmpty);
      expect(lac.decorIds, isEmpty);
    });

    test('« Mon mix » offers the ambiance of a published landscape with that landscape only', () {
      final catalog = parse(catalogResponse()).catalog;
      final ambiance = catalog.item(LayerKind.son, 'ambiance-lac-brume')!;
      expect(ambiance.isAmbiance, isTrue);
      expect(ambiance.offeredWith('lac-brume'), isTrue);
      expect(ambiance.offeredWith('cascade-foret'), isFalse);
      expect(catalog.ambianceOf('lac-brume'), ambiance);
      expect(Scene.fromLandscape(catalog.landscape('lac-brume')!).sounds.first.id, 'ambiance-lac-brume');
    });
  });

  group('a whole answer is refused', () {
    test('not an object, or revision / catalog / distant missing or of the wrong type', () {
      expect(() => PublishedCatalog.parse('nope', base), rejected('illisible'));
      expect(() => PublishedCatalog.parse(null, base), rejected('illisible'));
      expect(() => parse(catalogResponse()..['revision'] = -1), rejected('révision'));
      expect(() => parse(catalogResponse()..['revision'] = '7'), rejected('révision'));
      expect(() => parse(catalogResponse()..remove('catalog')), rejected('catalogue absent'));
      expect(() => parse(catalogResponse()..['distant'] = []), rejected('distants'));
    });

    test('catalog.version other than 1', () {
      for (final version in [2, 0, '1', null]) {
        final json = catalogResponse();
        (json['catalog'] as Map<String, dynamic>)['version'] = version;
        expect(() => parse(json), rejected('version'), reason: '$version');
      }
    });

    test('a catalog the bundled parser refuses', () {
      final notAList = catalogResponse();
      (notAList['catalog'] as Map<String, dynamic>)['paysages'] = {'id': 'x'};
      expect(() => parse(notAList), rejected('catalogue invalide'));
      final noName = catalogResponse(landscapes: [lacBrume()..remove('nom')]);
      expect(() => parse(noName), rejected('catalogue invalide'));
      final badEntry = catalogResponse();
      ((badEntry['catalog'] as Map<String, dynamic>)['sons'] as List).add('vent');
      expect(() => parse(badEntry), rejected('catalogue invalide'));
    });

    test('an id of the base missing (a withdrawal only concerns published items)', () {
      void without(String list, String id) {
        final json = catalogResponse();
        ((json['catalog'] as Map<String, dynamic>)[list] as List).removeWhere((e) => (e as Map)['id'] == id);
        expect(() => parse(json), rejected('$list:$id'), reason: '$list:$id');
      }

      without('paysages', 'pluie-ville');
      without('sons', 'tonnerre');
      without('musiques', 'harpe');
      without('decors', 'brume');
      without('themes', 'urbain');
    });
  });

  group('a single published item is left out', () {
    List<String> dropped(Map<String, dynamic> json) => parse(json).dropped;

    test('a 3D landscape (only filmed landscapes are published)', () {
      final json = catalogResponse(landscapes: [lacBrume(rendu: '3d')]);
      expect(parse(json).catalog.landscape('lac-brume'), isNull);
      expect(dropped(json).single, contains('paysage lac-brume'));
      // The rest of the answer is used.
      expect(parse(json).catalog.item(LayerKind.musique, 'harpe-celeste'), isNotNull);
    });

    test('a theme that is not a base theme of filmed landscapes (never « Imaginaire »)', () {
      final json = catalogResponse(landscapes: [lacBrume(theme: 'astral')]);
      expect(parse(json).catalog.landscape('lac-brume'), isNull);
      expect(dropped(json).single, contains('astral'));
      final imaginary = catalogResponse(landscapes: [lacBrume(theme: 'imaginaire')]);
      expect(parse(imaginary).catalog.landscape('lac-brume'), isNull);
      expect(dropped(imaginary).single, contains('imaginaire'));
      final city = catalogResponse(landscapes: [lacBrume(theme: 'urbain')]);
      expect(parse(city).catalog.landscapesOfTheme('urbain').last.id, 'lac-brume');
    });

    test('no valid media_rev: an item unknown to this base (a newer app\'s base)', () {
      final json = catalogResponse(sounds: [ambianceLacBrume()..remove('media_rev')]);
      expect(parse(json).catalog.item(LayerKind.son, 'ambiance-lac-brume'), isNull);
      expect(dropped(json).single, contains('media_rev'));
      // The mix of the landscape forgets it.
      expect(parse(json).catalog.landscape('lac-brume')!.defaultMix[LayerKind.son]!.map((l) => l.id), ['vent']);
    });

    test('an id that is not a dashboard id (it names files on the phone)', () {
      final json = catalogResponse(
        landscapes: [],
        sounds: [
          ambianceLacBrume()..['id'] = '../../eventide/scene',
          ambianceLacBrume()..['id'] = 'Majuscule',
          ambianceLacBrume()..['id'] = 'a' * 65,
        ],
        music: [],
      );
      expect(parse(json).catalog.sounds.length, base.sounds.length);
      expect(dropped(json), hasLength(3));
    });

    test('a sound played by events (its variant files have no published key)', () {
      final json = catalogResponse(sounds: [
        ambianceLacBrume()
          ..['lecture'] = 'evenements'
          ..['variantes'] = ['a', 'b', 'c'],
      ]);
      expect(parse(json).catalog.item(LayerKind.son, 'ambiance-lac-brume'), isNull);
      expect(dropped(json).single, contains('événements'));
    });

    test('a repeated id keeps its first occurrence', () {
      final json = catalogResponse(music: [harpeCeleste(), harpeCeleste()..['nom'] = 'Doublon']);
      expect(parse(json).catalog.item(LayerKind.musique, 'harpe-celeste')!.name, 'Harpe céleste');
      expect(dropped(json).single, contains('en double'));
    });
  });

  group('withdrawn items', () {
    final first = parse(catalogResponse(revision: 7));
    final second = parse(catalogResponse(revision: 8, landscapes: [], sounds: [], music: []));

    test('what was published and is no longer is withdrawn; published again, it is not', () {
      final withdrawn = WithdrawnItems.none.after(first, second);
      expect(withdrawn.landscapes, {'lac-brume'});
      expect(withdrawn.sounds, {'ambiance-lac-brume'});
      expect(withdrawn.music, {'harpe-celeste'});
      final again = withdrawn.after(second, first);
      expect(again.isEmpty, isTrue);
      expect(WithdrawnItems.fromJson(withdrawn.toJson()).landscapes, {'lac-brume'});
      expect(WithdrawnItems.fromJson('nope').isEmpty, isTrue);
    });

    test('a withdrawn landscape opens on cascade-foret; a withdrawn sound or music leaves the mix', () {
      final withdrawn = WithdrawnItems.none.after(first, second);
      final catalog = withdrawn.applyTo(second.catalog);
      expect(catalog.landscape('lac-brume'), isNull);
      expect(catalog.landscapeFor('lac-brume')!.id, 'cascade-foret');
      expect(catalog.landscapeFor('jamais-vu'), isNull, reason: 'an unknown id stays unknown');
      final favourite = Scene.fromLandscape(first.catalog.landscape('lac-brume')!, timer: const TimerDuration(30));
      final sanitized = catalog.sanitize(favourite)!;
      expect(sanitized.landscapeId, 'cascade-foret');
      expect(sanitized.sounds.map((l) => l.id), ['vent']);
      expect(sanitized.music, isEmpty);
      expect(sanitized.timer, const TimerDuration(30));
      // A link naming it opens on cascade-foret too, without the withdrawn items.
      final link = decodeSceneFromLink(encodeSceneForLink(favourite), catalog)!;
      expect(link.landscapeId, 'cascade-foret');
      expect(link.sounds.map((l) => l.id), ['vent']);
    });
  });

  group('items kept for the scene being played', () {
    final first = parse(catalogResponse(revision: 7)).catalog;
    final second = parse(catalogResponse(revision: 8, landscapes: [], sounds: [], music: [])).catalog;
    final playing = Scene.fromLandscape(first.landscape('lac-brume')!);

    test('found by id, never listed; a stored or shared id still opens on cascade-foret', () {
      final kept = second.keeping(first, playing);
      expect(kept.hasLingering, isTrue);
      expect(kept.landscape('lac-brume')!.name, 'Lac de brume');
      expect(kept.item(LayerKind.son, 'ambiance-lac-brume'), isNotNull);
      expect(kept.item(LayerKind.musique, 'harpe-celeste'), isNotNull);
      expect(kept.landscapes.map((l) => l.id), isNot(contains('lac-brume')));
      expect(kept.landscapesOfTheme('nature').map((l) => l.id), isNot(contains('lac-brume')));
      expect(kept.sounds.map((s) => s.id), isNot(contains('ambiance-lac-brume')));
      expect(kept.lists('lac-brume'), isFalse);
      expect(kept.listsItem(LayerKind.son, 'ambiance-lac-brume'), isFalse);
      expect(kept.listsItem(LayerKind.son, 'vent'), isTrue);
      expect(kept.landscapeFor('lac-brume')!.id, 'cascade-foret');
      expect(sceneFromSharedJson({'paysage': 'lac-brume', 'sons': [{'id': 'ambiance-lac-brume', 'niveau': 50}]}, kept)!
          .sounds, isEmpty);
    });

    test('nothing withdrawn in the scene: the same catalog', () {
      final cascade = Scene.fromLandscape(second.defaultLandscape);
      expect(identical(second.keeping(first, cascade), second), isTrue);
      expect(second.hasLingering, isFalse);
    });
  });

  group('what the phone can show', () {
    test('a published landscape needs its video or poster on the content server', () {
      final json = catalogResponse(withMedia: false);
      final published = parse(json);
      final hidden = showableCatalog(published.catalog, bundledAssets: const {}, remote: published.distant);
      expect(hidden.landscape('lac-brume'), isNull);
      expect(hidden.landscapeFor('lac-brume')!.id, 'cascade-foret');
      final withMedia = parse(catalogResponse());
      final shown = showableCatalog(withMedia.catalog, bundledAssets: const {}, remote: withMedia.distant);
      expect(shown.landscape('lac-brume'), isNotNull);
      expect(shown.theme('nature'), isNotNull);
    });
  });

  group('content keys', () {
    test('with media_rev: <id>.v<rev>; without: today\'s keys', () {
      expect(LandscapeMediaKeys.video('lac-brume', rev: 2), 'videos/paysages/lac-brume.v2.mp4');
      expect(LandscapeMediaKeys.image('lac-brume', rev: 2), 'images/paysages/lac-brume.v2.jpg');
      expect(ContentRepository.contentKey(LayerKind.son, 'ambiance-lac-brume', rev: 2),
          'audio/sons/ambiance-lac-brume.v2.ogg');
      expect(ContentRepository.contentKey(LayerKind.musique, 'harpe-celeste', rev: 1),
          'audio/musiques/harpe-celeste.v1.ogg');
      expect(LandscapeMediaKeys.video('pluie-ville'), 'videos/paysages/pluie-ville.mp4');
      expect(LandscapeMediaKeys.image('pluie-ville'), 'images/paysages/pluie-ville.jpg');
      expect(ContentRepository.contentKey(LayerKind.son, 'vagues'), 'audio/sons/vagues.ogg');
      expect(ContentRepository.contentKey(LayerKind.musique, 'harpe'), 'audio/musiques/harpe.ogg');
    });
  });
}
