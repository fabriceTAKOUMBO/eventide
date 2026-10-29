// Picture of the media card (lib/services/audio/media_artwork.dart): bundled poster copied to
// a file → downloaded poster → procedural picture rendered once; never throws.
import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:eventide/core/crash_guard.dart';
import 'package:eventide/core/scene.dart';
import 'package:eventide/services/audio/media_artwork.dart';
import 'package:eventide/ui/landscape/landscape_artwork.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

class _Renderer {
  final List<(String, Moment, int)> calls = [];
  bool fails = false;
  Completer<Uint8List>? hang;

  Future<Uint8List> call({required String style, required Moment moment, required int size}) async {
    calls.add((style, moment, size));
    if (hang != null) return hang!.future;
    if (fails) throw StateError('no GPU');
    return Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, moment.index]);
  }
}

void main() {
  final catalog = loadTestCatalog();
  final cascade = catalog.landscape('cascade-foret')!;
  final berge = catalog.landscape('berge-mousseuse')!;
  final poster = Uint8List.fromList(List.generate(64, (i) => i));
  late MemoryArtworkFiles files;
  late _Renderer renderer;
  late Set<String> bundled;
  late List<String> assetLoads;

  MediaArtwork build({Duration renderTimeout = const Duration(seconds: 10)}) => MediaArtwork(
    files: files,
    bundledAssets: () async => bundled,
    loadAsset: (asset) async {
      assetLoads.add(asset);
      return poster;
    },
    downloadedPoster: (id) => '/content/images/paysages/$id.jpg',
    render: renderer.call,
    renderTimeout: renderTimeout,
  );

  setUp(() {
    files = MemoryArtworkFiles();
    renderer = _Renderer();
    bundled = {'assets/landscapes/cascade-foret.jpg', 'assets/landscapes/cascade-foret.mp4'};
    assetLoads = [];
  });

  test('bundled poster: copied once to a file named after its content, for every moment', () async {
    final artwork = build();
    final digest = sha1.convert(poster).toString().substring(0, 12);
    final expected = Uri.file('/cache/media_art/cascade-foret-$digest.jpg');
    expect(artwork.peek('cascade-foret', Moment.jour), isNull);
    expect(await artwork.resolve(cascade, Moment.jour), expected);
    expect(files.files[expected.toFilePath()], poster);
    expect(await artwork.resolve(cascade, Moment.nuit), expected);
    expect(files.writes, [expected.toFilePath()]);
    expect(assetLoads, ['assets/landscapes/cascade-foret.jpg']);
    expect(renderer.calls, isEmpty);
    expect(artwork.peek('cascade-foret', Moment.jour), expected);
    expect(expected.scheme, 'file');
  });

  test('cache emptied by Android: the copy is made again', () async {
    final artwork = build();
    final first = await artwork.resolve(cascade, Moment.jour);
    files.files.clear();
    final again = await build().resolve(cascade, Moment.jour);
    expect(again, first);
    expect(files.files.keys, [first!.toFilePath()]);
  });

  test('downloaded Premium poster: used as it is, nothing copied or drawn', () async {
    files.files['/content/images/paysages/berge-mousseuse.jpg'] = poster;
    final artwork = build();
    expect(await artwork.resolve(berge, Moment.soir), Uri.file('/content/images/paysages/berge-mousseuse.jpg'));
    expect(files.writes, isEmpty);
    expect(renderer.calls, isEmpty);
  });

  test('no poster: the procedural picture, rendered once per landscape and moment', () async {
    final artwork = build();
    final night = await artwork.resolve(berge, Moment.nuit);
    expect(night, Uri.file('/cache/media_art/berge-mousseuse-nuit-v${MediaArtwork.renderVersion}.png'));
    expect(renderer.calls, [('berge', Moment.nuit, 720)]);
    expect(files.files[night!.toFilePath()]!.last, Moment.nuit.index);
    // Same key: memorised. Another moment: another picture.
    expect(await artwork.resolve(berge, Moment.nuit), night);
    final day = await artwork.resolve(berge, Moment.jour);
    expect(day, isNot(night));
    expect(renderer.calls, hasLength(2));
    // Already on disk (earlier run of the app): not drawn again.
    final fresh = build();
    expect(await fresh.resolve(berge, Moment.nuit), night);
    expect(renderer.calls, hasLength(2));
  });

  test('concurrent requests share one render', () async {
    final artwork = build();
    final results = await Future.wait([
      artwork.resolve(berge, Moment.aube),
      artwork.resolve(berge, Moment.aube),
    ]);
    expect(results[0], results[1]);
    expect(renderer.calls, hasLength(1));
  });

  test('a failing render gives no picture (never throws), and a later call tries again', () async {
    renderer.fails = true;
    final artwork = build();
    expect(await artwork.resolve(berge, Moment.jour), isNull);
    expect(artwork.peek('berge-mousseuse', Moment.jour), isNull);
    renderer.fails = false;
    expect(await artwork.resolve(berge, Moment.jour), isNotNull);
    expect(renderer.calls, hasLength(2));
  });

  test('a render that never answers is given up', () async {
    renderer.hang = Completer<Uint8List>();
    final artwork = build(renderTimeout: const Duration(milliseconds: 20));
    expect(await artwork.resolve(berge, Moment.jour), isNull);
    expect(files.writes, isEmpty);
  });

  test('an unreadable bundled poster falls back to the next source', () async {
    final artwork = MediaArtwork(
      files: files,
      bundledAssets: () async => bundled,
      loadAsset: (asset) async => throw StateError('missing asset'),
      downloadedPoster: (id) => '/content/images/paysages/$id.jpg',
      render: renderer.call,
    );
    expect(await artwork.resolve(cascade, Moment.jour), Uri.file('/cache/media_art/cascade-foret-jour-v${MediaArtwork.renderVersion}.png'));
    expect(renderer.calls.single.$1, 'cascade');
  });

  test('two pictures asked together are drawn one after the other, never at once', () async {
    final gate = Completer<void>();
    var running = 0, most = 0;
    final artwork = MediaArtwork(
      files: files,
      bundledAssets: () async => const {},
      loadAsset: (asset) async => poster,
      downloadedPoster: (id) => '/content/images/paysages/$id.jpg',
      render: ({required String style, required Moment moment, required int size}) async {
        running++;
        most = running > most ? running : most;
        if (style == 'berge') await gate.future;
        running--;
        return Uint8List.fromList([1]);
      },
    );
    final first = artwork.resolve(berge, Moment.jour);
    final second = artwork.resolve(catalog.landscape('lisiere-verte')!, Moment.jour);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(running, 1);
    gate.complete();
    expect(await first, isNotNull);
    expect(await second, isNotNull);
    expect(most, 1);
  });

  test('a style drawn simplified (crash guard) gets its own file name', () async {
    final artwork = MediaArtwork(
      files: files,
      bundledAssets: () async => const {},
      loadAsset: (asset) async => poster,
      downloadedPoster: (id) => '/content/images/paysages/$id.jpg',
      render: renderer.call,
      simplified: (style) => style == 'berge',
    );
    expect(
      await artwork.resolve(berge, Moment.nuit),
      Uri.file('/cache/media_art/berge-mousseuse-nuit-v${MediaArtwork.renderVersion}-s.png'),
    );
  });

  group('guarded renderer (crash guard, § 19)', () {
    late MemoryGuardStore store;
    late List<String> log;
    setUp(() {
      store = MemoryGuardStore();
      log = [];
    });
    tearDown(() => CrashGuard.current = CrashGuard());

    testWidgets('marked and noted before drawing, cleared once the PNG is ready', (tester) async {
      CrashGuard.current = CrashGuard(store: store, build: 'b', log: log.add)..load();
      final png = await tester.runAsync(
        () => renderGuardedLandscapeArtwork(style: 'lisiere', moment: Moment.nuit, size: 64),
      );
      expect(png!.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
      expect(log, ['dessin : image de la carte lisiere 64×64 nuit']);
      expect(store.writes, 3, reason: 'load, mark, clear');
      expect(CrashGuard(store: store, build: 'b').deadStyles, isEmpty);
    });

    testWidgets('a style interrupted by a crash before is drawn simplified', (tester) async {
      store.content = '{"build":"b","starts":0,"dead":[],"drawing":[{"what":"paysage","style":"lisiere","detail":"672×1456"}]}';
      CrashGuard.current = CrashGuard(store: store, build: 'b', log: log.add)..load();
      final png = await tester.runAsync(
        () => renderGuardedLandscapeArtwork(style: 'lisiere', moment: Moment.jour, size: 64),
      );
      expect(png, isNotNull);
      expect(log.last, 'dessin : image de la carte lisiere 64×64 jour simplifiée');
    });
  });

  testWidgets('the real renderer draws a square PNG of the landscape at its moment', (tester) async {
    final png = await tester.runAsync(
      () => renderLandscapeArtwork(style: 'cascade', moment: Moment.nuit, size: 96),
    );
    expect(png, isNotNull);
    expect(png!.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
    final header = ByteData.sublistView(png, 16, 24);
    expect(header.getUint32(0), 96);
    expect(header.getUint32(4), 96);
  });
}
