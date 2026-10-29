// Réglages › « Signaler un problème », and Paysages › « Fond d'écran ».
import 'package:eventide/core/plan.dart';
import 'package:eventide/core/problem_report.dart';
import 'package:eventide/core/wallpaper.dart';
import 'package:eventide/ui/landscape/landscape_image.dart';
import 'package:eventide/ui/navigation.dart';
import 'package:eventide/ui/screens/landscapes_sheet.dart';
import 'package:eventide/ui/screens/settings_screen.dart';
import 'package:eventide/ui/screens/wallpaper_sheet.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_harness.dart';
import 'fake_app_model.dart';
import 'ui_test_utils.dart';

class _Model extends FakeAppModel {
  _Model({super.plan});

  AppExit? exit;
  bool shareOk = true;
  int shares = 0;
  WallpaperSupport support = const WallpaperSupport(liveWallpaper: true, gallery: true);
  WallpaperResult result = WallpaperResult.opened;
  final List<String> wallpapers = [];
  final List<String> saved = [];

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

  @override
  Future<bool> saveLandscapeVideoToGallery(String landscapeId) async {
    saved.add(landscapeId);
    return true;
  }
}

void main() {
  setUp(() => LandscapeImages.debugSetVideos(bundled: {'cascade-foret'}));
  tearDown(() => LandscapeImages.debugSetVideos());

  group('Signaler un problème', () {
    testWidgets('no abnormal exit: a plain entry that shares the report', (tester) async {
      usePhoneView(tester);
      final model = _Model();
      await pumpApp(tester, model);
      await openRoute(tester, Routes.settings, (_) => const SettingsScreen());
      await tester.ensureVisible(find.text('Signaler un problème'));
      expect(find.text('Envoyer un rapport technique, sans donnée personnelle'), findsOneWidget);
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
        find.text('Dernier arrêt anormal : Plantage natif (moteur, son ou vidéo), le 29 octobre à 22 h 14'),
        findsOneWidget,
      );
      await tester.tap(find.text('Signaler un problème'));
      await settle(tester);
      expect(find.text('Le rapport n’a pas pu être préparé. Réessayez.'), findsOneWidget);
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
      expect(find.text('Mettre « Cascade en forêt » sur l’écran d’accueil ou verrouillé'), findsOneWidget);
      await tester.tap(find.text('Fond d’écran'));
      await settle(tester);
      expect(find.byType(WallpaperSheet), findsOneWidget);
      await tearDownApp(tester);
    });

    testWidgets('video landscape: live wallpaper and Gallery, each explained', (tester) async {
      usePhoneView(tester);
      final model = _Model();
      await pumpApp(tester, model);
      await openRoute(tester, WallpaperSheet.routeName, (_) => const WallpaperSheet(landscapeId: 'cascade-foret'));
      expect(find.text(WallpaperMessages.liveTitle), findsOneWidget);
      expect(find.text(WallpaperMessages.liveText), findsOneWidget);
      expect(find.text(WallpaperMessages.galleryText), findsOneWidget);
      expect(find.textContaining('15 secondes'), findsOneWidget);
      await tester.tap(find.text(WallpaperMessages.liveTitle));
      await settle(tester);
      expect(model.wallpapers, ['cascade-foret']);
      await tester.ensureVisible(find.text(WallpaperMessages.galleryTitle));
      await tester.tap(find.text(WallpaperMessages.galleryTitle));
      await settle(tester);
      expect(model.saved, ['cascade-foret']);
      expect(find.text(WallpaperMessages.saved), findsOneWidget);
      await tearDownApp(tester);
    });

    testWidgets('a refusal from the phone is explained', (tester) async {
      usePhoneView(tester);
      final model = _Model()..result = WallpaperResult.unavailable;
      await pumpApp(tester, model);
      await openRoute(tester, WallpaperSheet.routeName, (_) => const WallpaperSheet(landscapeId: 'cascade-foret'));
      await tester.tap(find.text(WallpaperMessages.liveTitle));
      await settle(tester);
      expect(find.text(WallpaperMessages.unavailable), findsOneWidget);
      await tearDownApp(tester);
    });

    testWidgets('a landscape without video: still picture only, no Gallery', (tester) async {
      usePhoneView(tester);
      final model = _Model(plan: Plan.annual);
      await pumpApp(tester, model);
      // berge-mousseuse: no video and no poster on this test setup.
      await openRoute(tester, WallpaperSheet.routeName, (_) => const WallpaperSheet(landscapeId: 'berge-mousseuse'));
      expect(find.text(WallpaperMessages.liveTitle), findsNothing);
      expect(find.text(WallpaperMessages.galleryTitle), findsNothing);
      expect(find.text(WallpaperMessages.nothingText), findsOneWidget);
      await tearDownApp(tester);
    });

    testWidgets('a Premium landscape on the free plan: Premium is offered instead', (tester) async {
      usePhoneView(tester);
      final model = _Model(plan: Plan.free);
      await pumpApp(tester, model);
      await openRoute(tester, WallpaperSheet.routeName, (_) => const WallpaperSheet(landscapeId: 'pluie-ville'));
      expect(find.text(WallpaperMessages.lockedText), findsOneWidget);
      expect(find.text(WallpaperMessages.liveTitle), findsNothing);
      expect(find.text('Découvrir Premium'), findsOneWidget);
      await tearDownApp(tester);
    });
  });
}
