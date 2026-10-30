// Landscape pictures (contract § 12): every landscape is a poster now (filmed video's frame 0,
// or a 3D scene's frame at t = 0); nothing is drawn by the app. Without its poster on the
// phone, a plain dark placeholder.
import 'package:eventide/ui/landscape/landscape_image.dart';
import 'package:eventide/ui/screens/home/home_menu.dart' show LandscapeThumbnail;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../core/test_helpers.dart';
import 'ui_test_utils.dart';

void main() {
  setUpAll(loadAppFonts);
  final catalog = loadCatalog();

  testWidgets('every landscape shows its poster or the placeholder, full size and as a thumbnail', (tester) async {
    usePhoneView(tester);
    for (final landscape in catalog.landscapes) {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              SizedBox(width: 390, height: 600, child: LandscapeImage(landscapeId: landscape.id, kenBurns: true)),
              SizedBox(width: 169, height: 148, child: LandscapeThumbnail(landscapeId: landscape.id)),
            ],
          ),
        ),
      );
      expect(tester.takeException(), isNull, reason: landscape.id);
      // No asset manifest in this test: no poster, so the placeholder (never a drawing).
      expect(find.byType(LandscapePlaceholder), findsNWidgets(2), reason: landscape.id);
      expect(find.byType(CustomPaint).evaluate().where((e) => (e.widget as CustomPaint).painter != null), isEmpty);
    }
  });

  testWidgets('a poster provided by the resolver is shown, dimmed and blurred like before', (tester) async {
    usePhoneView(tester);
    LandscapeImages.resolver = (id) => id == 'ondes' ? const AssetImage('assets/brand/logo_512.png') : null;
    addTearDown(() => LandscapeImages.resolver = null);
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 390,
          height: 600,
          child: LandscapeImage(landscapeId: 'ondes', brightness: 0.6, saturation: 0.8, blurSigma: 3),
        ),
      ),
    );
    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(ColorFiltered), findsOneWidget);
    expect(find.byType(ImageFiltered), findsOneWidget);
    expect(find.byType(LandscapePlaceholder), findsNothing);
    expect(landscapeMatrix(), hasLength(20));
  });
}
