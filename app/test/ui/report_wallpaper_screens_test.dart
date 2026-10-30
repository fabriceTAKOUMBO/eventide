// Réglages › « Signaler un problème », and Paysages › « Fond d'écran ».
import 'package:eventide/core/plan.dart';
import 'package:eventide/core/problem_report.dart';
import 'package:eventide/core/wallpaper.dart';
import 'package:eventide/ui/landscape/landscape_image.dart';
import 'package:eventide/ui/navigation.dart';
import 'package:eventide/ui/screens/landscapes_sheet.dart';
import 'package:eventide/ui/screens/settings_screen.dart';
import 'package:eventide/ui/screens/wallpaper_sheet.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart' show RichText;
import 'package:flutter_test/flutter_test.dart';

import 'app_harness.dart';
import 'fake_app_model.dart';
import 'ui_test_utils.dart';

class _Model extends FakeAppModel {
  _Model({super.plan});

  AppExit? exit;
  bool shareOk = true;
  int shares = 0;
  WallpaperSupport support = const WallpaperSupport(liveWallpaper: true);
  WallpaperResult result = WallpaperResult.opened;
  final List<String> wallpapers = [];

  @override
  AppExit? get lastAbnormalExit => exit;

  @override
  Future<bool> shareProblemReport() async {
    shares++;
    return shareOk;
  }

  @override
  WallpaperSupport get wallpaperSupport => support;

  @override
  Future<WallpaperResult> setLandscapeWallpaper(String landscapeId) async {
    wallpapers.add(landscapeId);
    return result;
  }
}

void main() {
  // Real fonts: the one-line check of the wallpaper button measures Manrope, not the test font.
  setUpAll(loadAppFonts);
  setUp(() => LandscapeImages.debugSetVideos(bundled: {'cascade-foret'}));
  tearDown(() => LandscapeImages.debugSetVideos());

  group('Signaler un problème', () {
    testWidgets('no abnormal exit: a plain entry that shares the report', (tester) async {
      usePhoneView(tester);
      final model = _Model();
      await pumpApp(tester, model);
      await openRoute(tester, Routes.settings, (_) => const SettingsScreen());
      await tester.ensureVisible(find.text('Signaler un problème'));
      // A plain entry: no subtitle when Android recorded no abnormal end.
      expect(find.textContaining('Dernier arrêt'), findsNothing);
      await tester.tap(find.text('Signaler un problème'));
      await settle(tester);
      expect(model.shares, 1);
      await tearDownApp(tester);
    });

    testWidgets('the last abnormal exit is summed up; a failure says so', (tester) async {
      usePhoneView(tester);
      final model = _Model()
        ..exit = AppExit(reason: ExitReason.crashNative, at: DateTime(2026, 10, 29, 22, 14), importance: 100)
        ..shareOk = false;
      await pumpApp(tester, model);
      await openRoute(tester, Routes.settings, (_) => const SettingsScreen());
      await tester.ensureVisible(find.text('Signaler un problème'));
      expect(
        find.text('Dernier arrêt : Plantage natif (moteur, son ou vidéo), le 29 octobre à 22 h 14'),
        findsOneWidget,
      );
      await tester.tap(find.text('Signaler un problème'));
      await settle(tester);
      expect(find.text('Rapport impossible. Réessayez.'), findsOneWidget);
      await tearDownApp(tester);
    });
  });

  group('Fond d’écran', () {
    testWidgets('Paysages offers it for the selected landscape, only where the phone allows it', (tester) async {
      usePhoneView(tester);
      final model = _Model()..support = WallpaperSupport.none;
      await pumpApp(tester, model);
      await openRoute(tester, Routes.landscapes, (_) => const LandscapesSheet());
      expect(find.text('Fond d’écran'), findsNothing);
      await tearDownApp(tester);

      final able = _Model();
      await pumpApp(tester, able);
      await openRoute(tester, Routes.landscapes, (_) => const LandscapesSheet());
      await tester.ensureVisible(find.text('Fond d’écran'));
      await tester.tap(find.text('Fond d’écran'));
      await settle(tester);
      expect(find.byType(WallpaperSheet), findsOneWidget);
      await tearDownApp(tester);
    });

    testWidgets('video landscape: the live wallpaper, explained; no Gallery copy any more', (tester) async {
      usePhoneView(tester);
      // Galaxy S24: 1080 × 2340 px at 2.8125, i.e. 384 × 832 dp.
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.8125;
      final model = _Model();
      await pumpApp(tester, model);
      await openRoute(tester, WallpaperSheet.routeName, (_) => const WallpaperSheet(landscapeId: 'cascade-foret'));
      expect(findCaps(WallpaperMessages.liveTitle), findsOneWidget);
      expect(find.text(WallpaperMessages.liveText), findsOneWidget);
      expect(find.textContaining('Galerie'), findsNothing);
      expect(find.textContaining('15 secondes'), findsNothing);
      // The main button's label holds on one line on the S24 (it wrapped on two before).
      final label = tester.renderObject<RenderParagraph>(
        find.descendant(of: findCaps(WallpaperMessages.liveTitle), matching: find.byType(RichText)),
      );
      final oneLine = label.getFullHeightForCaret(const TextPosition(offset: 0));
      expect(label.size.height, lessThan(oneLine * 1.5));
      expect(label.didExceedMaxLines, isFalse);
      await tester.tap(findCaps(WallpaperMessages.liveTitle));
      await settle(tester);
      expect(model.wallpapers, ['cascade-foret']);
      await tearDownApp(tester);
    });

    testWidgets('a refusal from the phone is explained', (tester) async {
      usePhoneView(tester);
      final model = _Model()..result = WallpaperResult.unavailable;
      await pumpApp(tester, model);
      await openRoute(tester, WallpaperSheet.routeName, (_) => const WallpaperSheet(landscapeId: 'cascade-foret'));
      await tester.tap(findCaps(WallpaperMessages.liveTitle));
      await settle(tester);
      expect(find.text(WallpaperMessages.unavailable), findsOneWidget);
      await tearDownApp(tester);
    });

    testWidgets('a landscape without video nor picture: nothing to offer, said plainly', (tester) async {
      usePhoneView(tester);
      final model = _Model(plan: Plan.annual);
      await pumpApp(tester, model);
      // ciel-etoile: test material (demo build only), no video and no poster here.
      await openRoute(tester, WallpaperSheet.routeName, (_) => const WallpaperSheet(landscapeId: 'ciel-etoile'));
      expect(findCaps(WallpaperMessages.liveTitle), findsNothing);
      expect(find.text(WallpaperMessages.nothingText), findsOneWidget);
      await tearDownApp(tester);
    });

    testWidgets('a Premium landscape on the free plan: Premium is offered instead', (tester) async {
      usePhoneView(tester);
      final model = _Model(plan: Plan.free);
      await pumpApp(tester, model);
      await openRoute(tester, WallpaperSheet.routeName, (_) => const WallpaperSheet(landscapeId: 'pluie-ville'));
      expect(find.text(WallpaperMessages.lockedText), findsOneWidget);
      expect(findCaps(WallpaperMessages.liveTitle), findsNothing);
      expect(findCaps('Découvrir Premium'), findsOneWidget);
      await tearDownApp(tester);
    });
  });
}
