import 'package:eventide/core/scene.dart';
import 'package:eventide/ui/landscape/decor_layer.dart';
import 'package:eventide/ui/landscape/landscape_image.dart';
import 'package:eventide/ui/landscape/landscape_painter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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

void main() {
  setUpAll(loadAppFonts);

  testWidgets('every landscape style paints without error, at full size and as thumbnail', (tester) async {
    usePhoneView(tester);
    for (final style in _styles) {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(children: [
            SizedBox(width: 390, height: 600, child: LandscapeImage(landscapeId: style, style: style)),
            SizedBox(width: 169, height: 148, child: CustomPaint(painter: LandscapePainter(style: style))),
          ]),
        ),
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('moments and decor effects render', (tester) async {
    usePhoneView(tester, reduceMotion: false);
    for (final moment in Moment.values) {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Stack(children: [
            Positioned.fill(child: LandscapeImage(landscapeId: 'x', style: 'cascade', moment: moment)),
            Positioned.fill(
              child: DecorLayer(effects: [for (final id in kDecorIds) DecorEffect(id, 60)]),
            ),
          ]),
        ),
      );
      await tester.pump(const Duration(seconds: 3));
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('renders a contact sheet of all landscapes', (tester) async {
    usePhoneView(tester);
    tester.view.physicalSize = const Size(4 * 200 * 3, 3 * 433 * 3);
    await tester.pumpWidget(
      RepaintBoundary(
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Wrap(children: [
            for (final style in _styles)
              SizedBox(
                width: 200,
                height: 433,
                child: Stack(children: [
                  Positioned.fill(child: CustomPaint(painter: LandscapePainter(style: style))),
                  Positioned(
                    left: 6,
                    bottom: 6,
                    child: Text(style, style: const TextStyle(fontFamily: 'Manrope', fontSize: 14, color: Colors.white)),
                  ),
                ]),
              ),
          ]),
        ),
      ),
    );
    await saveScreenshot(tester, 'landscapes', finder: find.byType(RepaintBoundary).first);
  });
}
