// Shared helpers for UI widget tests: real fonts, phone-sized view, screenshots.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:eventide/ui/theme/vitre.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Directory where screenshot tests write PNGs (outside the project).
const String kScreenshotDir =
    '/tmp/claude-0/-home-user-eventide/179136f9-1231-5e1d-a040-3d1cfb1ace90/scratchpad/screens';

bool _fontsLoaded = false;

/// Loads Manrope, Cormorant Garamond (upright and italic) and Fraunces so layouts are measured
/// with the real fonts. Call it from `setUpAll` (outside the fake-async zone of `testWidgets`).
Future<void> loadAppFonts() async {
  if (_fontsLoaded) return;
  _fontsLoaded = true;
  Future<void> load(String family, List<String> paths) async {
    final loader = FontLoader(family);
    for (final path in paths) {
      final file = File(path);
      if (!file.existsSync()) continue;
      final bytes = file.readAsBytesSync();
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    }
    await loader.load();
  }

  await load('Manrope', ['assets/fonts/Manrope-Variable.ttf']);
  await load(kDisplayFamily, [
    'assets/fonts/CormorantGaramond-Medium.ttf',
    'assets/fonts/CormorantGaramond-MediumItalic.ttf',
  ]);
  await load('Fraunces', ['assets/fonts/Fraunces-Variable.ttf']);
}

/// A label drawn in spaced capitals (buttons, eyebrows: [CapsText]), found by its words.
Finder findCaps(String text) => find.text(text.toUpperCase());

/// Phone view of the mockup (390 × 844 logical px, 3× density), status bar 44 px,
/// gesture bar 20 px, reduced motion so frames settle.
void usePhoneView(
  WidgetTester tester, {
  double textScale = 1.0,
  bool reduceMotion = true,
}) {
  tester.view.physicalSize = const Size(390 * 3, 844 * 3);
  tester.view.devicePixelRatio = 3;
  tester.view.padding = const FakeViewPadding(top: 44 * 3, bottom: 20 * 3);
  tester.view.viewPadding = const FakeViewPadding(top: 44 * 3, bottom: 20 * 3);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      FakeAccessibilityFeatures(disableAnimations: reduceMotion);
  addTearDown(() {
    tester.view.reset();
    tester.platformDispatcher.clearAllTestValues();
  });
}

/// Writes the current frame of [finder] (default: the whole app) to [name].png.
Future<void> saveScreenshot(
  WidgetTester tester,
  String name, {
  Finder? finder,
}) async {
  final target = finder ?? find.byType(MaterialApp).first;
  RenderObject? render = tester.renderObject(target);
  while (render != null && render is! RenderRepaintBoundary) {
    render = render.parent;
  }
  if (render is! RenderRepaintBoundary) {
    // Walk down to the first boundary.
    RenderRepaintBoundary? found;
    void visit(RenderObject child) {
      if (found != null) return;
      if (child is RenderRepaintBoundary) {
        found = child;
        return;
      }
      child.visitChildren(visit);
    }

    tester.renderObject(target).visitChildren(visit);
    render = found;
  }
  final boundary = render! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1.5);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = Directory(kScreenshotDir)..createSync(recursive: true);
    File('${dir.path}/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
    image.dispose();
  });
}
