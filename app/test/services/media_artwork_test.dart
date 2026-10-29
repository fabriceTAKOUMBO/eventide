// Picture of the media card (lib/services/audio/media_artwork.dart): bundled poster copied to
// a file → downloaded poster → no picture (nothing is drawn any more); never throws.
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:eventide/services/audio/media_artwork.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  final catalog = loadTestCatalog();
  final cascade = catalog.landscape('cascade-foret')!;
  final ville = catalog.landscape('pluie-ville')!;
  final lucioles = catalog.landscape('foret-lucioles')!;
  final ondes = catalog.landscape('ondes')!;
  final poster = Uint8List.fromList(List.generate(64, (i) => i));
  late MemoryArtworkFiles files;
  late Set<String> bundled;
  late List<String> assetLoads;

  MediaArtwork build() => MediaArtwork(
    files: files,
    bundledAssets: () async => bundled,
    loadAsset: (asset) async {
      assetLoads.add(asset);
      return poster;
    },
    downloadedPoster: (id) => '/content/images/paysages/$id.jpg',
  );

  setUp(() {
    files = MemoryArtworkFiles();
    bundled = {
      'assets/landscapes/cascade-foret.jpg',
      'assets/landscapes/cascade-foret.mp4',
      'assets/landscapes/foret-lucioles.jpg',
    };
    assetLoads = [];
  });

  test('bundled poster: copied once to a file named after its content', () async {
    final artwork = build();
    final digest = sha1.convert(poster).toString().substring(0, 12);
    final expected = Uri.file('/cache/media_art/cascade-foret-$digest.jpg');
    expect(artwork.peek('cascade-foret'), isNull);
    expect(await artwork.resolve(cascade), expected);
    expect(files.files[expected.toFilePath()], poster);
    expect(await artwork.resolve(cascade), expected);
    expect(files.writes, [expected.toFilePath()]);
    expect(assetLoads, ['assets/landscapes/cascade-foret.jpg']);
    expect(artwork.peek('cascade-foret'), expected);
    expect(expected.scheme, 'file');
  });

  test('the free 3D scene uses its bundled poster too', () async {
    final uri = await build().resolve(lucioles);
    expect(uri!.toFilePath(), startsWith('/cache/media_art/foret-lucioles-'));
  });

  test('cache emptied by Android: the copy is made again', () async {
    final artwork = build();
    final first = await artwork.resolve(cascade);
    files.files.clear();
    final again = await build().resolve(cascade);
    expect(again, first);
    expect(files.files.keys, [first!.toFilePath()]);
  });

  test('downloaded Premium poster: used as it is, nothing copied', () async {
    files.files['/content/images/paysages/pluie-ville.jpg'] = poster;
    final artwork = build();
    expect(await artwork.resolve(ville), Uri.file('/content/images/paysages/pluie-ville.jpg'));
    expect(files.writes, isEmpty);
  });

  test('no poster on the phone: no picture (never drawn), and a later call tries again', () async {
    final artwork = build();
    expect(await artwork.resolve(ondes), isNull);
    expect(artwork.peek('ondes'), isNull);
    expect(files.writes, isEmpty);
    // Downloaded meanwhile (Premium).
    files.files['/content/images/paysages/ondes.jpg'] = poster;
    expect(await artwork.resolve(ondes), Uri.file('/content/images/paysages/ondes.jpg'));
  });

  test('concurrent requests share one copy', () async {
    final artwork = build();
    final results = await Future.wait([artwork.resolve(cascade), artwork.resolve(cascade)]);
    expect(results[0], results[1]);
    expect(assetLoads, hasLength(1));
  });

  test('an unreadable bundled poster falls back to the downloaded one, or to none', () async {
    final artwork = MediaArtwork(
      files: files,
      bundledAssets: () async => bundled,
      loadAsset: (asset) async => throw StateError('missing asset'),
      downloadedPoster: (id) => '/content/images/paysages/$id.jpg',
    );
    expect(await artwork.resolve(cascade), isNull);
    files.files['/content/images/paysages/cascade-foret.jpg'] = poster;
    expect(await artwork.resolve(cascade), Uri.file('/content/images/paysages/cascade-foret.jpg'));
  });
}
