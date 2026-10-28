// Renders every screen to PNG (scratchpad/screens) with the real fonts, to compare with
// the mockup. Also fails on any layout overflow or exception.
import 'package:eventide/app/app_model.dart';
import 'package:eventide/core/ops.dart' show ChangeLine;
import 'package:eventide/core/plan.dart';
import 'package:eventide/core/schedule.dart';
import 'package:eventide/core/sleep.dart';
import 'package:eventide/ui/navigation.dart';
import 'package:eventide/ui/screens/credits_screen.dart';
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
import 'package:eventide/ui/screens/voice_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_harness.dart';
import 'fake_app_model.dart';
import 'ui_test_utils.dart';

List<Night> sampleNights(DateTime now) {
  final hours = [6.5, 7.2, 5.9, 7.5, 7.0, 8.1, 7.33];
  return [
    for (var i = 0; i < 7; i++)
      Night(
        start: DateTime(now.year, now.month, now.day - (6 - i) - 1, 23, 5),
        end: DateTime(now.year, now.month, now.day - (6 - i) - 1, 23, 5).add(Duration(minutes: (hours[i] * 60).round())),
        listenedMinutes: 95,
      ),
  ];
}

Schedule sampleSchedule() => Schedule(
      id: 'a',
      hour: 22,
      minute: 0,
      days: Schedule.everyDay,
      landscapeId: 'cascade-foret',
    );

void main() {
  setUpAll(loadAppFonts);

  Future<void> shot(WidgetTester tester, String name) => saveScreenshot(tester, name, finder: find.byKey(kAppBoundary));

  testWidgets('preview: welcome, home states, offline', (tester) async {
    usePhoneView(tester);
    final model = FakeAppModel(onboarded: false);
    await pumpApp(tester, model);
    await shot(tester, '01_bienvenue');

    await model.completeOnboarding();
    await settle(tester);
    await shot(tester, '02_accueil');

    await tester.tap(find.bySemanticsLabel('Réduire le menu pour voir plus de paysage'));
    await settle(tester);
    await shot(tester, '02b_accueil_replie');
    await tester.tap(find.bySemanticsLabel('Afficher le menu complet'));
    await settle(tester);

    await model.saveSchedule(sampleSchedule());
    await settle(tester);
    await shot(tester, '02c_accueil_prog');

    await tester.tap(find.bySemanticsLabel(RegExp('^Minuteur')));
    await settle(tester);
    await shot(tester, '02d_minuteur');
    await tester.tap(find.text('30 min'));
    await settle(tester);

    model.browseLandscape('pluie-ville');
    await settle(tester);
    await shot(tester, '02e_accueil_verrouille');

    model.online = false;
    model.browseLandscape('cascade-foret');
    await settle(tester);
    await shot(tester, '13_hors_connexion');
    await tearDownApp(tester);
  });

  testWidgets('preview: sheets', (tester) async {
    usePhoneView(tester);
    final model = FakeAppModel(schedules: [sampleSchedule()], nights: sampleNights(DateTime(2026, 10, 28, 20, 30)));
    model.addFavoriteForTest(model.scene);
    await pumpApp(tester, model);

    await openRoute(tester, Routes.landscapes, (_) => const LandscapesSheet());
    await shot(tester, '03_paysages');
    await tester.tap(find.text('Favoris'));
    await settle(tester);
    await shot(tester, '03b_favoris');
    navigatorOf(tester).pop();
    await settle(tester);

    await openRoute(tester, Routes.mix, (_) => const MixSheet());
    await shot(tester, '04_mon_mix');
    await tester.tap(find.text('Décor'));
    await settle(tester);
    await shot(tester, '04b_mon_mix_decor');
    navigatorOf(tester).pop();
    await settle(tester);

    await openRoute(tester, Routes.share, (_) => const ShareScreen());
    await shot(tester, '06_partage');
    navigatorOf(tester).pop();

    await openRoute(tester, Routes.sleep, (_) => const SleepScreen());
    await shot(tester, '07_sommeil');
    navigatorOf(tester).pop();

    model.setPlaying(true);
    await openRoute(tester, Routes.standby, (_) => const StandbyScreen());
    await shot(tester, '08_veille');
    navigatorOf(tester).pop();

    await openRoute(tester, Routes.schedules, (_) => const SchedulesScreen());
    await shot(tester, '09_programmations');
    navigatorOf(tester).pop();

    await openRoute(tester, Routes.scheduleEditor, (_) => const ScheduleEditorScreen());
    await shot(tester, '10_nouvelle_programmation');
    navigatorOf(tester).pop();

    await openRoute(tester, Routes.premium, (_) => const PremiumScreen());
    await shot(tester, '11_premium');
    navigatorOf(tester).pop();

    await openRoute(tester, Routes.settings, (_) => const SettingsScreen());
    await shot(tester, '12_reglages');
    navigatorOf(tester).pop();

    await openRoute(tester, Routes.privacy, (_) => const PrivacyScreen());
    await shot(tester, '14_confidentialite');
    navigatorOf(tester).pop();

    model.plan = Plan.lifetime;
    await openRoute(tester, Routes.credits, (_) => const CreditsScreen());
    await shot(tester, '15_credits');
    navigatorOf(tester).pop();
    await tearDownApp(tester);
  });

  testWidgets('preview: voice states', (tester) async {
    usePhoneView(tester);
    final model = FakeAppModel(granted: {PermissionKind.microphone});
    await pumpApp(tester, model);
    await openRoute(tester, Routes.voice, (_) => const VoiceScreen());
    model.voiceState = const VoiceListening(
      partialText: 'Mets le minuteur sur 1 h et programme la pluie tous les soirs à 22 h',
      soundLevel: 0.7,
    );
    await settle(tester);
    await shot(tester, '05_voix_ecoute');
    model.voiceState = const VoiceThinking(phrase: 'Mets le minuteur sur 1 h');
    await settle(tester);
    await shot(tester, '05b_voix_reflexion');
    model.voiceState = const VoiceResult(
      phrase: 'Mets le minuteur sur 1 h et programme la pluie tous les soirs à 22 h',
      changes: [
        ChangeLine('Minuteur', 'Arrêt après 1 h'),
        ChangeLine('Programmation', 'Tous les jours à 22 h · pluie douce'),
      ],
      quotaLabel: 'Essai gratuit · 2 demandes restantes',
    );
    await settle(tester);
    await shot(tester, '05c_voix_resultat');
    model.voiceState = const VoiceError(message: 'Sans connexion, je ne peux pas comprendre votre demande.', offline: true);
    await settle(tester);
    await shot(tester, '05d_voix_erreur');
    await tearDownApp(tester);
  });
}
