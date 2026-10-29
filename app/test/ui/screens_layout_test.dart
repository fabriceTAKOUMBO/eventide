// Every screen lays out at 390 × 844 without overflow or exception, at text scale
// 1.0 and 2.0 (and with the in-app « Très grande » size and high contrast).
import 'package:eventide/app/app_model.dart';
import 'package:eventide/core/catalog.dart';
import 'package:eventide/core/plan.dart';
import 'package:eventide/core/settings.dart';
import 'package:eventide/ui/navigation.dart';
import 'package:eventide/ui/screens/battery_guide_screen.dart';
import 'package:eventide/ui/screens/landscapes_sheet.dart';
import 'package:eventide/ui/screens/mix_sheet.dart';
import 'package:eventide/ui/screens/premium_screen.dart';
import 'package:eventide/ui/screens/privacy_screen.dart';
import 'package:eventide/ui/screens/schedule_editor_screen.dart';
import 'package:eventide/ui/screens/schedules_screen.dart';
import 'package:eventide/ui/screens/settings_screen.dart';
import 'package:eventide/ui/screens/share_screen.dart';
import 'package:eventide/ui/screens/sleep_screen.dart';
import 'package:eventide/ui/screens/standby_screen.dart';
import 'package:eventide/ui/widgets/permission_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_harness.dart';
import 'fake_app_model.dart';
import 'screens_preview_test.dart' show sampleNights, sampleSchedule;
import 'ui_test_utils.dart';

typedef _Screen = (String name, WidgetBuilder builder);

final List<_Screen> _sheets = [
  (Routes.landscapes, (_) => const LandscapesSheet()),
  (Routes.mix, (_) => const MixSheet()),
  (Routes.share, (_) => const ShareScreen()),
  (Routes.sleep, (_) => const SleepScreen()),
  (Routes.standby, (_) => const StandbyScreen()),
  (Routes.schedules, (_) => const SchedulesScreen()),
  (Routes.scheduleEditor, (_) => const ScheduleEditorScreen()),
  (Routes.premium, (_) => const PremiumScreen()),
  (Routes.settings, (_) => const SettingsScreen()),
  (Routes.privacy, (_) => const PrivacyScreen()),
  (Routes.batteryGuide, (_) => const BatteryGuideScreen()),
];

void main() {
  setUpAll(loadAppFonts);

  for (final scale in const [1.0, 2.0]) {
    group('text scale $scale', () {
      testWidgets(
        'welcome, home (expanded, collapsed, locked, schedule), offline',
        (tester) async {
          usePhoneView(tester, textScale: scale);
          final model = FakeAppModel(onboarded: false);
          await pumpApp(tester, model, showHint: true);
          expect(tester.takeException(), isNull);
          expect(find.text('Bienvenue'), findsOneWidget);

          await model.completeOnboarding();
          await settle(tester);
          expect(tester.takeException(), isNull);
          expect(find.text('Cascade en forêt'), findsOneWidget);

          await tester.tap(find.bySemanticsLabel(RegExp('^Minuteur')));
          await settle(tester);
          expect(tester.takeException(), isNull);
          await tester.tap(find.text('Sans minuteur'));
          await settle(tester);

          await tester.tap(
            find.bySemanticsLabel('Réduire le menu pour voir plus de paysage'),
          );
          await settle(tester);
          expect(tester.takeException(), isNull);
          await tester.tap(find.bySemanticsLabel('Afficher le menu complet'));
          await settle(tester);

          await model.saveSchedule(sampleSchedule());
          model.browseLandscape('aurore-boreale');
          await settle(tester);
          expect(tester.takeException(), isNull);
          expect(find.text('Avec Premium'), findsOneWidget);

          model.online = false;
          model.browseLandscape('cascade-foret');
          await settle(tester);
          expect(tester.takeException(), isNull);
          expect(find.text('Pas de connexion'), findsOneWidget);
          await tearDownApp(tester);
        },
      );

      testWidgets('all sheets and pages', (tester) async {
        usePhoneView(tester, textScale: scale);
        final model = FakeAppModel(
          schedules: [sampleSchedule()],
          nights: sampleNights(DateTime(2026, 10, 28, 20, 30)),
        );
        model.addFavoriteForTest(model.scene);
        await pumpApp(tester, model);
        for (final (name, builder) in _sheets) {
          await openRoute(tester, name, builder);
          expect(tester.takeException(), isNull, reason: name);
          navigatorOf(tester).pop();
          await settle(tester);
        }
        // Subscriber variants.
        model.plan = Plan.annual;
        for (final (name, builder) in _sheets.where(
          (s) => const [
            Routes.settings,
            Routes.sleep,
            Routes.premium,
          ].contains(s.$1),
        )) {
          await openRoute(tester, name, builder);
          expect(tester.takeException(), isNull, reason: '$name (annual)');
          navigatorOf(tester).pop();
          await settle(tester);
        }
        await tearDownApp(tester);
      });

      testWidgets('permission dialogs', (tester) async {
        usePhoneView(tester, textScale: scale);
        await pumpApp(tester, FakeAppModel());
        final context = tester.element(find.byType(Navigator).first);
        for (final kind in PermissionKind.values) {
          final model2 = FakeAppModel();
          final result = explainAndRequestPermission(context, model2, kind);
          await settle(tester);
          expect(tester.takeException(), isNull, reason: kind.name);
          expect(find.text('Continuer'), findsOneWidget);
          await tester.ensureVisible(find.text('Plus tard'));
          await tester.tap(find.text('Plus tard'));
          await settle(tester);
          expect(await result, isFalse);
        }
        // Permanently denied: the dialog sends to Android's settings instead.
        for (final kind in const [PermissionKind.notifications]) {
          final model3 = FakeAppModel(deniedForever: {kind});
          final result = explainAndRequestPermission(context, model3, kind);
          await settle(tester);
          expect(tester.takeException(), isNull, reason: '${kind.name} denied');
          expect(find.text('Continuer'), findsNothing);
          await tester.ensureVisible(find.text('Ouvrir les réglages'));
          await tester.tap(find.text('Ouvrir les réglages'));
          await settle(tester);
          expect(await result, isFalse);
          expect(model3.calls, ['openAppSettings']);
        }
        await tearDownApp(tester);
      });
    });
  }

  for (final scale in const [1.0, 2.0]) {
    for (final contrast in const [false, true]) {
      testWidgets('Mon mix with everything muted, text scale $scale, '
          'high contrast $contrast', (tester) async {
        usePhoneView(tester, textScale: scale);
        final model = FakeAppModel();
        await model.updateSettings(
          AppSettings(onboarded: true, highContrast: contrast),
        );
        model.setCategoryMuted(LayerKind.son, true);
        model.setCategoryMuted(LayerKind.musique, true);
        await pumpApp(tester, model);
        await openRoute(tester, Routes.mix, (_) => const MixSheet());
        expect(tester.takeException(), isNull);
        expect(
          find.bySemanticsLabel('Sons de nature en sourdine'),
          findsOneWidget,
        );
        final opacity = contrast ? 0.8 : 0.5;
        expect(
          find.byWidgetPredicate((w) => w is Opacity && w.opacity == opacity),
          findsWidgets,
        );
        await tester.tap(find.text('Musique'));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.bySemanticsLabel('Musique en sourdine'), findsOneWidget);
        await tearDownApp(tester);
      });
    }
  }

  testWidgets('largest in-app text size and high contrast at text scale 1.3', (
    tester,
  ) async {
    usePhoneView(tester, textScale: 1.3);
    final model = FakeAppModel(schedules: [sampleSchedule()]);
    await model.updateSettings(
      const AppSettings(onboarded: true, textSize: 2, highContrast: true),
    );
    await pumpApp(tester, model);
    expect(tester.takeException(), isNull);
    for (final (name, builder) in _sheets) {
      await openRoute(tester, name, builder);
      expect(tester.takeException(), isNull, reason: name);
      navigatorOf(tester).pop();
      await settle(tester);
    }
    await tearDownApp(tester);
  });
}
