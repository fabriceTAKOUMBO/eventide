import 'dart:convert';

import 'package:eventide/core/catalog.dart';
import 'package:eventide/core/scene.dart';
import 'package:eventide/core/share_codec.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

void main() {
  final catalog = loadCatalog();

  String encodeJson(Object json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');

  final scene = Scene(
    landscapeId: 'lac-lune',
    moment: Moment.nuit,
    sounds: const [
      Layer(id: 'ruisseau', level: 25),
      Layer(id: 'chouette', level: 35),
    ],
    music: const [Layer(id: 'harpe', level: 20)],
    decor: const [Layer(id: 'brume', level: 25)],
    timer: const TimerNight(),
    sleepTracking: true,
  );

  test('round trip keeps landscape, layers and moment only', () {
    final data = encodeSceneForLink(scene);
    final decoded = decodeSceneFromLink(data, catalog)!;
    expect(decoded.landscapeId, 'lac-lune');
    expect(decoded.moment, Moment.nuit);
    expect(decoded.sounds, scene.sounds);
    expect(decoded.music, scene.music);
    expect(decoded.decor, scene.decor);
    // Not shared: the recipient gets the defaults.
    expect(decoded.timer, Scene.defaultTimer);
    expect(decoded.sleepTracking, isFalse);
    expect(
      decoded,
      scene.copyWith(timer: Scene.defaultTimer, sleepTracking: false),
    );
  });

  test(
    'payload is compact base64url JSON without padding or private fields',
    () {
      final data = encodeSceneForLink(scene);
      expect(data, isNot(contains('=')));
      expect(data, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
      final json = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(data))),
      ) as Map<String, dynamic>;
      expect(json.keys, [
        'version',
        'paysage',
        'moment',
        'sons',
        'musique',
        'decor',
      ]);
      expect(json.containsKey('minuteur'), isFalse);
      expect(json.containsKey('sommeil'), isFalse);
      expect(
        utf8.decode(base64Url.decode(base64Url.normalize(data))),
        isNot(contains(' ')),
      );
    },
  );

  test('the mute (sourdine) is never shared: the recipient hears the mix', () {
    final muted = scene
        .withMuted(LayerKind.musique, true)
        .withMuted(LayerKind.son, true);
    expect(shareableSceneJson(muted).containsKey('sourdine'), isFalse);
    expect(shareableSceneJson(muted), shareableSceneJson(scene));
    final decoded = decodeSceneFromLink(encodeSceneForLink(muted), catalog)!;
    expect(decoded.mutedSounds, isFalse);
    expect(decoded.mutedMusic, isFalse);
    expect(decoded.music, scene.music, reason: 'levels kept, all audible');
    // A payload that carries one anyway (another client) is ignored.
    final forged = encodeJson({
      ...shareableSceneJson(scene),
      'sourdine': {'sons': true, 'musique': true},
    });
    expect(decodeSceneFromLink(forged, catalog)!.fullyMuted, isFalse);
    expect(
      sceneFromSharedJson({
        ...shareableSceneJson(scene),
        'sourdine': {'musique': true},
      }, catalog)!.mutedMusic,
      isFalse,
    );
  });

  test('every landscape default mix round-trips', () {
    for (final l in catalog.landscapes) {
      final s = Scene.fromLandscape(l);
      expect(
        decodeSceneFromLink(encodeSceneForLink(s), catalog),
        s,
        reason: l.id,
      );
    }
  });

  test('a retired landscape opens on Cascade en forêt, sounds and music kept, decor dropped (contract § 12)', () {
    final data = encodeJson({
      'version': 1,
      'paysage': 'berge-mousseuse',
      'moment': 'soir',
      'sons': [
        {'id': 'ruisseau', 'niveau': 55},
      ],
      'musique': [
        {'id': 'harpe', 'niveau': 20},
      ],
      'decor': [
        {'id': 'lucioles', 'niveau': 30},
      ],
    });
    final decoded = decodeSceneFromLink(data, catalog)!;
    expect(decoded.landscapeId, 'cascade-foret');
    expect(decoded.moment, Moment.soir);
    expect(decoded.sounds, const [Layer(id: 'ruisseau', level: 55)]);
    expect(decoded.music, const [Layer(id: 'harpe', level: 20)]);
    expect(decoded.decor, isEmpty);
  });

  test('decor only where it applies: a 3D scene and its own elements (contract § 12)', () {
    Scene? decode(String landscape) => decodeSceneFromLink(
      encodeJson({
        'version': 1,
        'paysage': landscape,
        'decor': [
          {'id': 'etoiles', 'niveau': 40},
          {'id': 'petales', 'niveau': 30},
          {'id': 'eclairs', 'niveau': 50},
        ],
      }),
      catalog,
    );
    expect(decode('ondes')!.decor, const [Layer(id: 'etoiles', level: 40)]);
    expect(decode('jardin-zen')!.decor, const [Layer(id: 'petales', level: 30)]);
    expect(decode('pluie-ville')!.decor, isEmpty);
  });

  test('unknown items are dropped, levels clamped, duplicates removed', () {
    final data = encodeJson({
      'version': 1,
      'paysage': 'foret-lucioles',
      'moment': 'crepuscule',
      'sons': [
        {'id': 'eau-vive', 'niveau': 150},
        {'id': 'eau-vive', 'niveau': 10},
        {'id': 'klaxon', 'niveau': 50},
        {'id': 'piano-doux', 'niveau': 50}, // music id in the sounds list
        {'id': 'vent', 'niveau': 0},
        {'id': 'oiseaux', 'niveau': '40'},
        {'id': 'pluie-douce', 'niveau': 33.6},
        'garbage',
      ],
      'musique': 'nope',
      'decor': [
        {'id': 'brume', 'niveau': -5},
        {'id': 'lucioles', 'niveau': 20},
      ],
      'minuteur': {'mode': 'nuit'},
      'sommeil': {'suivi': true},
    });
    final decoded = decodeSceneFromLink(data, catalog)!;
    expect(decoded.moment, Moment.jour);
    expect(decoded.sounds, const [
      Layer(id: 'eau-vive', level: 100),
      Layer(id: 'pluie-douce', level: 34),
    ]);
    expect(decoded.music, isEmpty);
    expect(decoded.decor, const [Layer(id: 'lucioles', level: 20)]);
    expect(decoded.timer, Scene.defaultTimer);
    expect(decoded.sleepTracking, isFalse);
  });

  test('audio layers are capped at couches_max', () {
    final data = encodeJson({
      'paysage': 'cascade-foret',
      'sons': [
        for (final id in [
          'eau-vive',
          'oiseaux',
          'vent',
          'tonnerre',
          'pluie-douce',
          'ruisseau',
          'vagues',
        ])
          {'id': id, 'niveau': 50},
      ],
      'musique': [
        {'id': 'piano-doux', 'niveau': 50},
      ],
    });
    final decoded = decodeSceneFromLink(data, catalog)!;
    expect(decoded.audioLayerCount, catalog.limits.layersMax);
    expect(decoded.music, isEmpty);
  });

  test('invalid payloads return null and never throw', () {
    for (final bad in [
      '',
      '   ',
      '!!!',
      'a',
      'abcde',
      encodeJson([1, 2, 3]),
      encodeJson('scene'),
      encodeJson({'paysage': 'plage-tropicale'}),
      encodeJson({'paysage': 42}),
      encodeJson({'sons': []}),
      base64Url.encode([0xff, 0xfe, 0xfd]),
      'x' * 10000,
    ]) {
      expect(decodeSceneFromLink(bad, catalog), isNull, reason: bad);
    }
  });

  test('padding, standard base64 and percent-encoding are tolerated', () {
    final data = encodeSceneForLink(scene);
    final padded = base64Url.normalize(data);
    expect(decodeSceneFromLink(padded, catalog), isNotNull);
    final standard = padded.replaceAll('-', '+').replaceAll('_', '/');
    expect(decodeSceneFromLink(standard, catalog), isNotNull);
    expect(
      decodeSceneFromLink(Uri.encodeComponent(padded), catalog),
      isNotNull,
    );
  });

  test('sceneFromSharedJson validates a server scene', () {
    expect(
      sceneFromSharedJson(scene.toJson(), catalog)!.landscapeId,
      'lac-lune',
    );
    expect(sceneFromSharedJson({'paysage': 'x'}, catalog), isNull);
    expect(sceneFromSharedJson(null, catalog), isNull);
  });

  group('URIs', () {
    test('offline link /s#data', () {
      final uri = shareLinkFor(scene, 'eventide.example');
      expect(uri.toString(), startsWith('https://eventide.example/s#'));
      final parsed = Uri.parse(uri.toString());
      expect(sceneFromShareUri(parsed, catalog)!.landscapeId, 'lac-lune');
      expect(
        sceneFromShareUri(
          Uri.parse('https://eventide.example/s/#${encodeSceneForLink(scene)}'),
          catalog,
        ),
        isNotNull,
      );
    });

    test('offline link rejections', () {
      final data = encodeSceneForLink(scene);
      for (final s in [
        'https://eventide.example/s',
        'https://eventide.example/s#',
        'https://eventide.example/m#$data',
        'https://eventide.example/s/x#$data',
        'ftp://eventide.example/s#$data',
        'https://eventide.example/s#garbage',
      ]) {
        expect(sceneFromShareUri(Uri.parse(s), catalog), isNull, reason: s);
      }
    });

    test('server link /m/<code>', () {
      expect(
        shareCodeFromUri(Uri.parse('https://eventide.example/m/k7Fq2xPa')),
        'k7Fq2xPa',
      );
      expect(
        shareCodeFromUri(Uri.parse('https://eventide.example/m/k7Fq2xPa/')),
        'k7Fq2xPa',
      );
      for (final s in [
        'https://eventide.example/m/',
        'https://eventide.example/m/k7F-2xPa',
        'https://eventide.example/m/k7Fq2xPa/extra',
        'https://eventide.example/x/k7Fq2xPa',
        'https://eventide.example/s#abc',
        'mailto:someone@example.com',
      ]) {
        expect(shareCodeFromUri(Uri.parse(s)), isNull, reason: s);
      }
    });
  });

  test('a Premium item reaches a free recipient (shown locked by the UI)', () {
    final s = Scene.fromLandscape(catalog.landscape('toits-pluie')!);
    final decoded = decodeSceneFromLink(encodeSceneForLink(s), catalog)!;
    expect(decoded.hasLayer(LayerKind.son, 'tonnerre'), isTrue);
  });
}
