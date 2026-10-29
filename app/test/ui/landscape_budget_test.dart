// GPU budget of the procedural landscapes and the crash guard around their drawing
// (docs/app/architecture.md § 19: crash on the Galaxy S24 when swiping down to lisiere-verte,
// then at every start).
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:eventide/core/crash_guard.dart';
import 'package:eventide/core/plan.dart';
import 'package:eventide/core/scene.dart';
import 'package:eventide/ui/app.dart';
import 'package:eventide/ui/landscape/landscape_artwork.dart';
import 'package:eventide/ui/landscape/landscape_background.dart';
import 'package:eventide/ui/landscape/landscape_image.dart';
import 'package:eventide/ui/landscape/landscape_painter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audit_canvas.dart';
import 'fake_app_model.dart';
import 'ui_test_utils.dart';

const _styles = [
  'cascade',
  'sous-bois',
  'berge',
  'torrent',
  'pierres',
  'lisiere',
  'ville-pluie',
  'cafe',
  'toits',
  'etoiles',
  'aurore',
  'lune-lac',
];

/// What a Galaxy S24 draws (1080 × 2340 px at 2.8125, i.e. 384 × 832 dp; pictures rasterised at
/// 1.75 at most): full screen (current landscape and its neighbours), menu thumbnail (38 dp),
/// wallpaper sheet thumbnail (64 × 88 dp), media card picture (720 px).
const _sizes = [
  ('écran', Size(384, 832), 1.75),
  ('vignette du menu', Size(38, 38), 1.75),
  ('vignette du fond d’écran', Size(64, 88), 1.75),
  ('carte', Size(720, 720), 1.0),
];

CanvasAudit _audit(String style, Size size, double ratio, {bool simplified = false}) {
  final recorder = ui.PictureRecorder();
  final canvas = AuditCanvas(Canvas(recorder))..scale(ratio);
  if (simplified) {
    paintSimplifiedLandscape(canvas, size, style);
  } else {
    paintLandscapeCover(canvas, size, style);
  }
  recorder.endRecording().dispose();
  return canvas.audit;
}

/// Galaxy S24 view.
void _s24(WidgetTester tester) {
  usePhoneView(tester, reduceMotion: false);
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 2.8125;
}

void main() {
  setUpAll(loadAppFonts);

  group('GPU budget of every picture the S24 draws', () {
    for (final style in _styles) {
      test(style, () {
        for (final (label, size, ratio) in _sizes) {
          final a = _audit(style, size, ratio);
          final where = '$style, $label: $a';
          expect(a.nonFinite, isEmpty, reason: where);
          expect(a.clipPaths, 0, reason: 'no clip path (a stencil pass each): $where');
          expect(a.blurCount, lessThanOrEqualTo(kMaxBlurredShapesPerLandscape), reason: where);
          expect(a.blurs.keys.where((k) => k != 'path'), isEmpty, reason: 'only a few large shapes are blurred: $where');
          expect(a.blursUnderClipPath, 0, reason: where);
          expect(a.saveLayers, 0, reason: where);
          expect(a.draws, lessThanOrEqualTo(2200), reason: where);
          expect(a.maxBlurSigma, lessThan(40), reason: where);
          expect(a.maxExtent, lessThan(4096), reason: 'within any GPU texture limit: $where');
        }
      });
    }

    test('lisiere, the picture that crashed: no blur and no clip at all', () {
      for (final (label, size, ratio) in _sizes) {
        final a = _audit('lisiere', size, ratio);
        expect(a.blurCount, 0, reason: '$label: $a');
        expect(a.clipPaths, 0, reason: '$label: $a');
      }
    });

    test('the simplified picture (crash guard): three gradients, for every style', () {
      for (final style in [..._styles, 'inconnu']) {
        final a = _audit(style, const Size(384, 832), 1.75, simplified: true);
        expect(a.draws, 3, reason: style);
        expect(a.blurCount + a.clipPaths + a.saveLayers, 0, reason: style);
        expect(a.nonFinite, isEmpty, reason: style);
      }
    });
  });

  group('rendered for real', () {
    setUp(LandscapeRasterCache.clear);

    testWidgets('raster cache, S24 full screen: every style, opaque and detailed', (tester) async {
      for (final style in _styles) {
        final image = LandscapeRasterCache.obtain(style, const Size(384, 832), 1.75)!;
        expect((image.width, image.height), (672, 1456));
        final bytes = await tester.runAsync(() => image.toByteData());
        final pixels = bytes!.buffer.asUint32List(bytes.offsetInBytes, bytes.lengthInBytes ~/ 4);
        final colours = <int>{};
        var transparent = 0;
        for (var i = 0; i < pixels.length; i += 97) {
          colours.add(pixels[i]);
          if (bytes.getUint8(i * 4 + 3) != 0xFF) transparent++;
        }
        expect(transparent, 0, reason: style);
        expect(colours.length, greaterThan(200), reason: style);
      }
    });

    testWidgets('media card: every style at every moment, a 720 × 720 PNG', (tester) async {
      for (final style in _styles) {
        for (final moment in Moment.values) {
          final png = await tester.runAsync(
            () => renderLandscapeArtwork(style: style, moment: moment, size: 720),
          );
          final header = ByteData.sublistView(png!, 16, 24);
          expect((header.getUint32(0), header.getUint32(4)), (720, 720), reason: '$style ${moment.name}');
        }
      }
    });
  });

  group('crash guard around the drawings', () {
    late MemoryGuardStore store;
    late List<String> log;

    setUp(() {
      store = MemoryGuardStore();
      log = [];
      LandscapeRasterCache.clear();
    });
    tearDown(() {
      CrashGuard.current.dispose();
      CrashGuard.current = CrashGuard();
    });

    List<dynamic> drawing() => jsonDecode(store.content!)['drawing'] as List;

    Widget picture(String style) => Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: SizedBox(width: 384, height: 832, child: ProceduralLandscape(style: style)),
      ),
    );

    testWidgets('a new picture is marked (and noted in the log) before it is drawn, cleared once done', (tester) async {
      _s24(tester);
      CrashGuard.current = CrashGuard(store: store, build: 'b', log: log.add)..load();
      await tester.pumpWidget(picture('lisiere'));
      expect(log, ['dessin : paysage lisiere 672×1456']);
      expect(drawing(), [
        {'what': 'paysage', 'style': 'lisiere', 'detail': '672×1456'},
      ]);
      await tester.pump();
      await tester.pump(LandscapeRasterCache.settleDelay);
      expect(drawing(), isEmpty);
      // Already drawn: nothing new to mark.
      await tester.pumpWidget(picture('lisiere'));
      expect(log, hasLength(1));
    });

    testWidgets('a style whose drawing was interrupted by a crash is shown simplified, nothing drawn offscreen', (tester) async {
      _s24(tester);
      store.content = jsonEncode({
        'build': 'b',
        'starts': 1,
        'dead': [],
        'drawing': [
          {'what': 'paysage', 'style': 'lisiere', 'detail': '672×1456'},
        ],
      });
      CrashGuard.current = CrashGuard(store: store, build: 'b', log: log.add)..load();
      expect(CrashGuard.current.safeStart, isTrue);
      await tester.pumpWidget(picture('lisiere'));
      expect(
        find.byWidgetPredicate((w) => w is CustomPaint && w.painter is SimplifiedLandscapePainter),
        findsOneWidget,
      );
      expect(LandscapeRasterCache.contains('lisiere', const Size(384, 832), 1.75), isFalse);
      expect(log.where((l) => l.startsWith('dessin')), isEmpty);
      // Other styles are drawn as usual.
      await tester.pumpWidget(picture('pierres'));
      expect(log.last, 'dessin : paysage pierres 672×1456');
      await tester.pump();
      await tester.pump(LandscapeRasterCache.settleDelay);
    });

    testWidgets('the start counts as unfinished from the first landscape, until 20 s later', (tester) async {
      _s24(tester);
      CrashGuard.current = CrashGuard(store: store, build: 'b')..load();
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: LandscapeBackground(landscapeId: 'lisiere-verte', style: 'lisiere'),
        ),
      );
      expect(jsonDecode(store.content!)['starts'], 1);
      await tester.pump(const Duration(seconds: 21));
      expect(jsonDecode(store.content!)['starts'], 0);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(LandscapeRasterCache.settleDelay);
    });

    testWidgets('home: the neighbours are drawn one per frame, never together', (tester) async {
      _s24(tester);
      CrashGuard.current = CrashGuard(store: store, build: 'b', log: log.add)..load();
      final model = FakeAppModel(plan: Plan.annual)..hintsSeen.add('home_swipe');
      model.scene = Scene.fromLandscape(model.catalog.landscape('pierres-eau')!);
      await tester.pumpWidget(EventideApp(model: model));
      List<String> full() => [
        for (final l in log)
          if (l.endsWith('672×1456')) l.split(' ')[3],
      ];
      expect(full(), ['pierres']);
      // The next rebuild (any model change, as at every start) knows the screen size.
      model.loadingAudio = false;
      final seen = <int>[full().length];
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        seen.add(full().length);
      }
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i] - seen[i - 1], lessThanOrEqualTo(1), reason: 'frame $i: ${full()}');
      }
      // Pierres et eau: torrent above, lisière below, and Urbain's landscape on the right.
      expect(full().toSet(), {'pierres', 'torrent', 'lisiere', 'ville-pluie'});
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
      CrashGuard.current.dispose(); // its 20-s stable timer
    });
  });
}
