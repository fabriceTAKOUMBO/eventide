// Key user flows of the UI, against the in-memory FakeAppModel.
import 'package:eventide/app/app_model.dart';
import 'package:eventide/core/catalog.dart';
import 'package:eventide/core/plan.dart';
import 'package:eventide/core/scene.dart';
import 'package:eventide/ui/navigation.dart';
import 'package:eventide/ui/screens/battery_guide_screen.dart';
import 'package:eventide/ui/screens/credits_screen.dart';
import 'package:eventide/ui/screens/home/home_screen.dart';
import 'package:eventide/ui/screens/privacy_screen.dart';
import 'package:eventide/ui/screens/mix_sheet.dart';
import 'package:eventide/ui/screens/premium_screen.dart';
import 'package:eventide/ui/screens/schedule_editor_screen.dart';
import 'package:eventide/ui/screens/schedules_screen.dart';
import 'package:eventide/ui/screens/settings_screen.dart';
import 'package:eventide/ui/screens/standby_screen.dart';
import 'package:eventide/ui/screens/voice_screen.dart';
import 'package:eventide/ui/screens/landscapes_sheet.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show Opacity;
import 'package:flutter_test/flutter_test.dart';

import 'app_harness.dart';
import 'fake_app_model.dart';
import 'screens_preview_test.dart' show sampleSchedule;
import 'ui_test_utils.dart';

Finder label(Pattern text) => find.bySemanticsLabel(text);

Future<void> tapLabel(WidgetTester tester, Pattern text) async {
  final finder = label(text);
  await tester.ensureVisible(finder.first);
  await tester.tap(finder.first);
  await settle(tester);
}

Future<void> tapText(WidgetTester tester, String text) async {
  final finder = find.text(text);
  await tester.ensureVisible(finder.first);
  await tester.tap(finder.first);
  await settle(tester);
}

/// Drags on the landscape area (above the menu) by [delta].
Future<void> swipe(
  WidgetTester tester,
  Offset delta, {
  Offset from = const Offset(180, 420),
}) async {
  final gesture = await tester.startGesture(from);
  const steps = 8;
  for (var i = 1; i <= steps; i++) {
    await gesture.moveTo(from + delta * (i / steps));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  await settle(tester);
}

void main() {
  setUpAll(loadAppFonts);

  group('Bienvenue', () {
    testWidgets('« Commencer » completes onboarding and shows home', (
      tester,
    ) async {
      usePhoneView(tester);
      final model = FakeAppModel(onboarded: false);
      await pumpApp(tester, model);
      expect(
        find.text('Gratuit pour commencer, sans carte bancaire.'),
        findsOneWidget,
      );
      await tapText(tester, 'Commencer');
      expect(model.calls, contains('completeOnboarding'));
      expect(find.text('Cascade en forêt'), findsOneWidget);
      await tearDownApp(tester);
    });

    testWidgets('« J’ai déjà un compte » signs in with Google', (tester) async {
      usePhoneView(tester);
      final model = FakeAppModel(onboarded: false);
      await pumpApp(tester, model);
      await tapText(tester, 'J’ai déjà un compte');
      expect(model.calls, contains('signInWithGoogle'));
      expect(find.text('Cascade en forêt'), findsOneWidget);
      await tearDownApp(tester);
    });
  });

  group('Accueil', () {
    testWidgets('play / pause toggles', (tester) async {
      usePhoneView(tester);
      final model = FakeAppModel();
      await pumpApp(tester, model);
      await tapLabel(tester, 'Lancer la lecture');
      expect(model.playing, isTrue);
      expect(label('Mettre en pause'), findsOneWidget);
      await tapLabel(tester, 'Mettre en pause');
      expect(model.playing, isFalse);
      expect(model.calls.where((c) => c == 'togglePlay'), hasLength(2));
      await tearDownApp(tester);
    });

    testWidgets('timer chip opens the menu and sets the timer', (tester) async {
      usePhoneView(tester);
      final model = FakeAppModel();
      await pumpApp(tester, model);
      expect(find.text('Arrêt 1 h'), findsOneWidget);
      await tapLabel(tester, RegExp('^Minuteur 1 h'));
      for (final option in [
        '15 min',
        '30 min',
        '1 h',
        '2 h',
        'Toute la nuit',
        'Sans minuteur',
      ]) {
        expect(find.text(option), findsOneWidget);
      }
      await tapText(tester, '2 h');
      expect(model.scene.timer, const TimerDuration(120));
      expect(find.text('Arrêt 2 h'), findsOneWidget);
      expect(find.text('Toute la nuit'), findsNothing);

      await tapLabel(tester, RegExp('^Minuteur'));
      await tapText(tester, 'Sans minuteur');
      expect(model.scene.timer, const TimerNone());
      expect(find.text('Minuteur'), findsOneWidget);
      await tearDownApp(tester);
    });

    testWidgets(
      'vertical swipe changes landscape within the theme, without wrap',
      (tester) async {
        usePhoneView(tester);
        final model = FakeAppModel();
        await pumpApp(tester, model);
        expect(model.browsedLandscapeId, 'cascade-foret');
        // Swipe down on the first landscape: nothing before it (no wrap).
        await swipe(tester, const Offset(0, 220));
        expect(model.browsedLandscapeId, 'cascade-foret');
        // Swipe up: next landscape.
        await swipe(tester, const Offset(0, -220));
        expect(model.browsedLandscapeId, 'sous-bois');
        expect(find.text('Sous-bois ensoleillé'), findsOneWidget);
        // Too short (< 50 px): ignored.
        await swipe(tester, const Offset(0, -40));
        expect(model.browsedLandscapeId, 'sous-bois');
        // Diagonal (no dominant axis): ignored.
        await swipe(tester, const Offset(110, -120));
        expect(model.browsedLandscapeId, 'sous-bois');
        // Back with the arrow button.
        await tapLabel(tester, 'Paysage précédent');
        expect(model.browsedLandscapeId, 'cascade-foret');
        await tapLabel(tester, 'Paysage suivant');
        expect(model.browsedLandscapeId, 'sous-bois');
        await tearDownApp(tester);
      },
    );

    testWidgets('horizontal swipe and theme buttons change theme', (
      tester,
    ) async {
      usePhoneView(tester);
      final model = FakeAppModel();
      await pumpApp(tester, model);
      await swipe(tester, const Offset(-220, 0));
      expect(
        model.catalog.landscape(model.browsedLandscapeId)!.themeId,
        'urbain',
      );
      await tapText(tester, 'Astral');
      expect(
        model.catalog.landscape(model.browsedLandscapeId)!.themeId,
        'astral',
      );
      await swipe(tester, const Offset(220, 0));
      expect(
        model.catalog.landscape(model.browsedLandscapeId)!.themeId,
        'urbain',
      );
      await tapText(tester, 'Nature');
      expect(model.browsedLandscapeId, 'cascade-foret');
      await tearDownApp(tester);
    });

    testWidgets('vertical swipe on the menu collapses and expands it', (
      tester,
    ) async {
      usePhoneView(tester);
      final model = FakeAppModel();
      await pumpApp(tester, model);
      expect(find.text('Mon mix'), findsOneWidget);
      await swipe(tester, const Offset(0, 160), from: const Offset(200, 690));
      expect(find.text('Mon mix'), findsNothing);
      expect(label('Afficher le menu complet'), findsOneWidget);
      expect(model.browsedLandscapeId, 'cascade-foret');
      await swipe(tester, const Offset(0, -160), from: const Offset(200, 770));
      expect(find.text('Mon mix'), findsOneWidget);
      await tearDownApp(tester);
    });

    testWidgets('locked landscape shows the padlock and opens Premium', (
      tester,
    ) async {
      usePhoneView(tester);
      final model = FakeAppModel();
      await pumpApp(tester, model);
      await tapLabel(tester, 'Paysage suivant');
      await tapLabel(tester, 'Paysage suivant');
      expect(model.browsedLandscapeId, 'berge-mousseuse');
      expect(model.browsedLandscapeLocked, isTrue);
      expect(find.text('Avec Premium'), findsOneWidget);
      expect(label('Lancer la lecture'), findsNothing);
      await tapLabel(tester, 'Débloquer ce paysage avec Premium');
      expect(find.byType(PremiumScreen), findsOneWidget);
      await tapLabel(tester, 'Fermer');
      expect(find.byType(PremiumScreen), findsNothing);
      expect(find.text('Berge mousseuse'), findsOneWidget);
      await tearDownApp(tester);
    });

    testWidgets('heart adds a favorite with a toast', (tester) async {
      usePhoneView(tester);
      final model = FakeAppModel();
      await pumpApp(tester, model);
      await tapLabel(tester, 'Ajouter aux favoris');
      expect(model.favorites, hasLength(1));
      expect(find.text('Ajouté aux favoris'), findsOneWidget);
      expect(label('Retirer des favoris'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('Ajouté aux favoris'), findsNothing);
      await tearDownApp(tester);
    });

    testWidgets(
      'schedule tile: « Programmer » opens the editor, then shows the next start',
      (tester) async {
        usePhoneView(tester);
        final model = FakeAppModel();
        await pumpApp(tester, model);
        expect(find.text('Programmer'), findsOneWidget);
        await tapText(tester, 'Programmer');
        expect(find.byType(ScheduleEditorScreen), findsOneWidget);
        navigatorOf(tester).pop();
        await settle(tester);
        await model.saveSchedule(sampleSchedule());
        await settle(tester);
        expect(find.textContaining('22 h 00'), findsOneWidget);
        await tapText(tester, '22 h 00');
        expect(find.byType(SchedulesScreen), findsOneWidget);
        await tearDownApp(tester);
      },
    );

    testWidgets(
      'free plan without network shows « Hors connexion », retry calls the model',
      (tester) async {
        usePhoneView(tester);
        final model = FakeAppModel(online: false);
        await pumpApp(tester, model);
        expect(find.text('Pas de connexion'), findsOneWidget);
        await tapText(tester, 'Réessayer');
        expect(model.calls, contains('retryConnection'));
        expect(find.text('Toujours pas de connexion'), findsOneWidget);
        model.online = true;
        model.setPlaying(false);
        await settle(tester);
        expect(find.text('Cascade en forêt'), findsOneWidget);
        await tearDownApp(tester);
      },
    );

    testWidgets('Premium plan stays on home without network', (tester) async {
      usePhoneView(tester);
      final model = FakeAppModel(online: false, plan: Plan.annual);
      await pumpApp(tester, model);
      expect(find.text('Pas de connexion'), findsNothing);
      expect(find.text('Cascade en forêt'), findsOneWidget);
      await tearDownApp(tester);
    });
  });

  group('Paysages', () {
    testWidgets('free landscape is applied, locked one opens Premium', (
      tester,
    ) async {
      usePhoneView(tester);
      final model = FakeAppModel();
      await pumpApp(tester, model);
      await tapLabel(tester, 'Choisir un paysage');
      expect(find.byType(LandscapesSheet), findsOneWidget);
      expect(find.text('Version gratuite : 2 paysages'), findsOneWidget);
      await tapLabel(tester, RegExp('^Torrent de montagne, Premium'));
      expect(find.byType(PremiumScreen), findsOneWidget);
      navigatorOf(tester).pop();
      await settle(tester);
      await tapLabel(tester, 'Sous-bois ensoleillé');
      expect(model.calls, contains('selectLandscape:sous-bois'));
      expect(model.scene.landscapeId, 'sous-bois');
      expect(find.byType(LandscapesSheet), findsNothing);
      await tearDownApp(tester);
    });

    testWidgets(
      'picker mode returns the chosen landscape to the schedule editor',
      (tester) async {
        usePhoneView(tester);
        final model = FakeAppModel(plan: Plan.annual);
        await pumpApp(tester, model);
        await openRoute(
          tester,
          Routes.scheduleEditor,
          (_) => const ScheduleEditorScreen(),
        );
        await tapLabel(tester, RegExp('^Ambiance : Cascade en forêt'));
        expect(find.text('Ambiance'), findsWidgets);
        await tapText(tester, 'Astral');
        await tapLabel(tester, 'Lune sur le lac');
        expect(find.byType(LandscapesSheet), findsNothing);
        expect(label(RegExp('^Ambiance : Lune sur le lac')), findsOneWidget);
        await tearDownApp(tester);
      },
    );

    testWidgets('Favoris tab applies and removes a favorite', (tester) async {
      usePhoneView(tester);
      final model = FakeAppModel();
      model.addFavoriteForTest(model.scene);
      await pumpApp(tester, model);
      await openRoute(
        tester,
        Routes.landscapes,
        (_) => const LandscapesSheet(),
      );
      await tapText(tester, 'Favoris');
      expect(label(RegExp('^Écouter Cascade en forêt')), findsOneWidget);
      await tapLabel(tester, 'Retirer Cascade en forêt des favoris');
      expect(model.favorites, isEmpty);
      expect(find.text('Aucun favori pour l’instant'), findsOneWidget);
      await tearDownApp(tester);
    });
  });

  group('Mon mix', () {
    testWidgets('add a layer, change it by steps, remove it at 0 %', (
      tester,
    ) async {
      usePhoneView(tester);
      // A taller phone: the rows added below the sheet's first screen stay on screen.
      tester.view.physicalSize = const Size(390 * 3, 1200 * 3);
      final model = FakeAppModel();
      await pumpApp(tester, model);
      await openRoute(tester, Routes.mix, (_) => const MixSheet());
      expect(find.text('Dans mon mix'), findsOneWidget);
      await tapLabel(tester, 'Ajouter pluie douce');
      expect(model.scene.levelOf(LayerKind.son, 'pluie-douce'), 30);
      expect(find.text('30 %'), findsWidgets);
      await tapLabel(tester, 'Augmenter pluie douce');
      expect(model.scene.levelOf(LayerKind.son, 'pluie-douce'), 40);
      for (var i = 0; i < 4; i++) {
        await tapLabel(tester, 'Baisser pluie douce');
      }
      expect(model.scene.hasLayer(LayerKind.son, 'pluie-douce'), isFalse);
      expect(label('Ajouter pluie douce'), findsOneWidget);
      await tearDownApp(tester);
    });

    testWidgets(
      'mute switches keep every level; muted rows dimmed, a level change unmutes',
      (tester) async {
        usePhoneView(tester);
        final model = FakeAppModel();
        await pumpApp(tester, model);
        await openRoute(tester, Routes.mix, (_) => const MixSheet());
        // Sons tab: the switch is on (heard).
        expect(label('Sons de nature activés'), findsOneWidget);
        expect(
          tester.getSemantics(label('Sons de nature activés')),
          isSemantics(
            hasToggledState: true,
            isToggled: true,
            hasTapAction: true,
          ),
        );
        expect(
          tester.getSize(label('Sons de nature activés')).height,
          greaterThanOrEqualTo(48),
        );
        await tapLabel(tester, 'Sons de nature activés');
        expect(model.calls, contains('setCategoryMuted:son:true'));
        expect(model.soundsMuted, isTrue);
        expect(label('Sons de nature en sourdine'), findsOneWidget);
        expect(find.text('En sourdine, niveaux gardés'), findsOneWidget);
        // Rows stay, dimmed, with their level.
        expect(model.scene.levelOf(LayerKind.son, 'ambiance-cascade-foret'), 60);
        expect(find.text('60 %'), findsOneWidget);
        expect(
          find.byWidgetPredicate((w) => w is Opacity && w.opacity == 0.5),
          findsNWidgets(3),
        );
        expect(label(RegExp('Ambiance de la cascade, en sourdine')), findsOneWidget);
        // Still adjustable: a step unmutes the category.
        await tapLabel(tester, 'Augmenter ambiance de la cascade');
        expect(model.scene.levelOf(LayerKind.son, 'ambiance-cascade-foret'), 70);
        expect(model.soundsMuted, isFalse);
        // (The header may have scrolled off while reaching the row.)
        expect(find.text('Activés', skipOffstage: false), findsOneWidget);

        // Musique tab: « Musique activée » / « Musique en sourdine ».
        await tapText(tester, 'Musique');
        expect(find.text('Piano doux'), findsOneWidget);
        await tapLabel(tester, 'Musique activée');
        expect(model.musicMuted, isTrue);
        expect(label('Musique en sourdine'), findsOneWidget);
        expect(find.text('20 %'), findsOneWidget);
        await tapLabel(tester, 'Musique en sourdine');
        expect(model.musicMuted, isFalse);
        expect(model.scene.levelOf(LayerKind.musique, 'piano-doux'), 20);

        // The decor has no mute switch.
        await tapText(tester, 'Décor');
        expect(label(RegExp('sourdine|activée|activés')), findsNothing);
        await tearDownApp(tester);
      },
    );

    testWidgets('slider drag changes the level', (tester) async {
      usePhoneView(tester);
      final model = FakeAppModel();
      await pumpApp(tester, model);
      await openRoute(tester, Routes.mix, (_) => const MixSheet());
      final slider = find.byType(LevelSlider).first;
      final box = tester.getRect(slider);
      await tester.dragFrom(
        Offset(box.left + 20, box.center.dy),
        Offset(box.width - 20, 0),
      );
      await settle(tester);
      expect(model.scene.levelOf(LayerKind.son, 'ambiance-cascade-foret'), 100);
      await tearDownApp(tester);
    });

    testWidgets(
      'locked item asks the model (Premium opens), moment changes light',
      (tester) async {
        usePhoneView(tester);
        final model = FakeAppModel();
        await pumpApp(tester, model);
        await openRoute(tester, Routes.mix, (_) => const MixSheet());
        await tapLabel(tester, 'Ajouter tonnerre, avec Premium');
        expect(find.byType(PremiumScreen), findsOneWidget);
        navigatorOf(tester).pop();
        await settle(tester);
        await tapText(tester, 'Décor');
        expect(find.text('Moment de la journée'), findsOneWidget);
        await tapText(tester, 'Nuit');
        expect(model.scene.moment, Moment.nuit);
        await tapText(tester, 'Musique');
        expect(find.text('Ajouter une musique'), findsOneWidget);
        await tearDownApp(tester);
      },
    );

    testWidgets('share icon opens Partage; copy changes the label', (
      tester,
    ) async {
      usePhoneView(tester);
      final model = FakeAppModel();
      await pumpApp(tester, model);
      await openRoute(tester, Routes.mix, (_) => const MixSheet());
      await tapLabel(tester, 'Partager mon ambiance');
      expect(
        find.text('Votre proche retrouve exactement vos sons et vos réglages.'),
        findsOneWidget,
      );
      await tapText(tester, 'Envoyer à un proche');
      expect(model.calls, contains('shareMix'));
      await tapText(tester, 'Copier le lien');
      expect(model.calls, contains('copyShareLink'));
      expect(find.text('Lien copié'), findsOneWidget);
      await tearDownApp(tester);
    });
  });

  group('Voix', () {
    testWidgets('explains the microphone first, then listens at once', (
      tester,
    ) async {
      usePhoneView(tester);
      final model = FakeAppModel();
      await pumpApp(tester, model);
      await tapLabel(tester, 'Régler à la voix');
      expect(find.text('Le micro'), findsOneWidget);
      expect(model.calls, isNot(contains('startVoice')));
      await tapText(tester, 'Continuer');
      expect(
        model.calls,
        containsAllInOrder(['requestPermission:microphone', 'startVoice']),
      );
      expect(find.text('Touchez pour arrêter'), findsOneWidget);
      await tapLabel(tester, 'Arrêter l’enregistrement');
      expect(find.text('C’est fait'), findsOneWidget);
      expect(find.text('Essai gratuit · 2 demandes restantes'), findsOneWidget);
      await tapText(tester, 'Garder');
      expect(model.calls, contains('keepVoice'));
      expect(find.byType(VoiceScreen), findsNothing);
      await tearDownApp(tester);
    });

    testWidgets('all states render; Annuler undoes', (tester) async {
      usePhoneView(tester);
      final model = FakeAppModel(granted: {PermissionKind.microphone});
      await pumpApp(tester, model);
      await openRoute(tester, Routes.voice, (_) => const VoiceScreen());
      expect(model.calls, contains('startVoice'));
      model.voiceState = const VoiceListening(
        partialText: 'Ajoute du piano',
        soundLevel: 0.4,
      );
      await settle(tester);
      expect(find.text('« Ajoute du piano »'), findsOneWidget);
      expect(find.text('Vous pouvez aussi dire'), findsOneWidget);
      model.voiceState = const VoiceThinking(phrase: 'Ajoute du piano');
      await settle(tester);
      expect(find.text('Je prépare vos réglages'), findsOneWidget);
      model.voiceState = const VoiceRephrase(
        phrase: 'Mets le truc',
        message: 'Je n’ai pas bien compris.',
      );
      await settle(tester);
      expect(find.text('Pouvez-vous reformuler ?'), findsOneWidget);
      expect(find.text('Je n’ai pas bien compris.'), findsOneWidget);
      model.voiceState = const VoiceRefused(
        phrase: 'Achète Premium',
        message: 'Je ne peux pas acheter à votre place.',
      );
      await settle(tester);
      expect(
        find.text('Je ne peux pas acheter à votre place.'),
        findsOneWidget,
      );
      model.voiceState = const VoiceError(
        message: 'Pas de réseau.',
        offline: true,
      );
      await settle(tester);
      expect(find.text('Pas de connexion'), findsOneWidget);
      await tapText(tester, 'Réessayer');
      expect(model.calls.where((c) => c == 'startVoice'), hasLength(2));
      model.voiceState = const VoiceResult(
        phrase: 'Ajoute du piano',
        changes: [],
      );
      await settle(tester);
      expect(find.text('Rien n’a changé.'), findsOneWidget);
      await tapText(tester, 'Annuler');
      expect(model.calls, contains('undoVoice'));
      expect(find.byType(VoiceScreen), findsNothing);
      await tearDownApp(tester);
    });
  });

  group('Programmations', () {
    testWidgets('editor saves a new schedule after explaining notifications', (
      tester,
    ) async {
      usePhoneView(tester);
      final model = FakeAppModel();
      await pumpApp(tester, model);
      await openRoute(tester, Routes.schedules, (_) => const SchedulesScreen());
      expect(
        find.text(
          'Pour démarrer à l’heure, Android demande votre autorisation.',
        ),
        findsOneWidget,
      );
      await tapText(tester, 'Autoriser');
      expect(model.exactAlarmAllowed, isTrue);
      expect(find.text('Autoriser'), findsNothing);

      await tapText(tester, 'Ajouter une programmation');
      expect(find.text('Nouvelle programmation'), findsOneWidget);
      await tapLabel(tester, 'Une heure plus tard');
      await tapLabel(tester, 'Cinq minutes plus tard');
      await tapLabel(tester, 'Samedi');
      await tapLabel(tester, 'Dimanche');
      expect(find.text('Du lundi au vendredi'), findsOneWidget);
      await tapText(tester, 'Personnalisé');
      await tapLabel(tester, 'Allonger la durée');
      expect(find.text('20 min'), findsOneWidget);
      await tapText(tester, 'Pour se détendre');
      expect(find.text('« C’est l’heure de vous détendre »'), findsOneWidget);
      await tapText(tester, 'Enregistrer');
      expect(find.text('Les notifications'), findsOneWidget);
      await tapText(tester, 'Continuer');
      expect(model.schedules, hasLength(1));
      final s = model.schedules.single;
      expect((s.hour, s.minute), (23, 5));
      expect(s.days, {1, 2, 3, 4, 5});
      expect(s.rampMinutes, 20);
      expect(s.reminder.name, 'detente');
      expect(find.byType(ScheduleEditorScreen), findsNothing);
      expect(find.text('23 h 05'), findsOneWidget);

      // Free limit reached: the add button now opens Premium.
      expect(
        find.text(
          'Version gratuite : 1 programmation. Premium n’a pas de limite.',
        ),
        findsOneWidget,
      );
      await tapLabel(tester, 'Ajouter une programmation, avec Premium');
      expect(find.byType(PremiumScreen), findsOneWidget);
      await tearDownApp(tester);
    });

    testWidgets('switch toggles, row opens edit mode with delete', (
      tester,
    ) async {
      usePhoneView(tester);
      final model = FakeAppModel(
        schedules: [sampleSchedule()],
        exactAlarmAllowed: true,
      );
      await pumpApp(tester, model);
      await openRoute(tester, Routes.schedules, (_) => const SchedulesScreen());
      await tapLabel(tester, 'Programmation de 22 h 00');
      expect(model.schedules.single.active, isFalse);
      await tapLabel(tester, RegExp('^Modifier la programmation de 22 h 00'));
      expect(find.text('Modifier la programmation'), findsOneWidget);
      await tapText(tester, 'Supprimer la programmation');
      await tapText(tester, 'Supprimer');
      expect(model.schedules, isEmpty);
      await tearDownApp(tester);
    });
  });

  group('Premium', () {
    testWidgets('CTA text and note follow the chosen plan', (tester) async {
      usePhoneView(tester);
      final model = FakeAppModel();
      await pumpApp(tester, model);
      await openRoute(tester, Routes.premium, (_) => const PremiumScreen());
      expect(find.text('Essayer 3 jours gratuits'), findsOneWidget);
      expect(
        find.text(
          'Rien à payer aujourd’hui. Ensuite 59,99 € par an, annulable à tout moment.',
        ),
        findsOneWidget,
      );
      expect(find.text('−37 %'), findsOneWidget);
      await tapLabel(tester, RegExp('^Mensuel'));
      expect(find.text('S’abonner'), findsOneWidget);
      expect(
        find.text('7,99 € par mois, annulable à tout moment.'),
        findsOneWidget,
      );
      await tapLabel(tester, RegExp('^À vie'));
      expect(find.text('Acheter une fois'), findsOneWidget);
      expect(
        find.text('79,99 € en une seule fois, sans abonnement.'),
        findsOneWidget,
      );
      await tapText(tester, 'Acheter une fois');
      expect(model.calls, contains('buy:lifetime'));
      await tapText(tester, 'Restaurer mes achats');
      expect(model.calls, contains('restorePurchases'));
      await tearDownApp(tester);
    });
  });

  group('Réglages', () {
    testWidgets('toggles and text size call the model', (tester) async {
      usePhoneView(tester);
      final model = FakeAppModel();
      await pumpApp(tester, model);
      await tapLabel(tester, 'Réglages');
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(find.text('Mon abonnement · Version gratuite'), findsOneWidget);
      expect(
        find.text('Puis 59,99 € par an. Annulable à tout moment.'),
        findsOneWidget,
      );
      await tapLabel(tester, 'Écran noir pendant le minuteur');
      expect(model.settings.blackScreenDuringTimer, isTrue);
      await tapLabel(tester, 'Agrandir le texte');
      expect(model.settings.textSize, 1);
      expect(find.text('Grande'), findsOneWidget);
      await tapLabel(tester, 'Réduire le texte');
      expect(model.settings.textSize, 0);
      await tapLabel(tester, 'Contraste renforcé');
      expect(model.settings.highContrast, isTrue);
      // Wi-Fi only is Premium: opens Premium for the free plan.
      await tapLabel(
        tester,
        'Téléchargements en Wi-Fi seulement, avec Premium',
      );
      expect(find.byType(PremiumScreen), findsOneWidget);
      navigatorOf(tester).pop();
      await settle(tester);
      await tapLabel(tester, 'Se connecter avec Google');
      expect(model.calls, contains('signInWithGoogle'));
      await tapLabel(tester, 'Confidentialité et données');
      expect(find.text('Exporter mes données'), findsOneWidget);
      await tapText(tester, 'Supprimer mes données');
      await tapText(tester, 'Supprimer');
      expect(model.calls, contains('deleteAccountData'));
      await tearDownApp(tester);
    });

    testWidgets('subscriber sees the plan and renewal', (tester) async {
      usePhoneView(tester);
      final model = FakeAppModel(plan: Plan.annual);
      await pumpApp(tester, model);
      await openRoute(tester, Routes.settings, (_) => const SettingsScreen());
      expect(find.text('Mon abonnement · Annuel'), findsOneWidget);
      expect(find.text('Renouvelé le 28 octobre 2027.'), findsOneWidget);
      await tapText(tester, 'Gérer mon abonnement sur Google Play');
      expect(model.calls, contains('openManageSubscription'));
      await tapLabel(tester, 'Téléchargements en Wi-Fi seulement');
      expect(model.settings.wifiOnly, isTrue);
      await tearDownApp(tester);
    });
  });

  group('Events and night', () {
    testWidgets('model events open Premium, credits, share and toasts', (
      tester,
    ) async {
      usePhoneView(tester);
      final model = FakeAppModel();
      await pumpApp(tester, model);
      model.emit(const ToastEvent('6 sons au maximum en même temps'));
      await settle(tester);
      expect(find.text('6 sons au maximum en même temps'), findsOneWidget);
      model.emit(const OpenPremiumEvent());
      await settle(tester);
      expect(find.byType(PremiumScreen), findsOneWidget);
      model.emit(const OpenPremiumEvent());
      await settle(tester);
      expect(find.byType(PremiumScreen), findsOneWidget);
      model.emit(const OpenCreditsEvent());
      await settle(tester);
      expect(find.text('Crédits d’assistant'), findsOneWidget);
      model.emit(const SharedMixOpenedEvent(lockedItems: 2));
      await settle(tester);
      expect(
        find.text('Mix reçu · 2 éléments réservés à Premium'),
        findsOneWidget,
      );
      expect(find.byType(PremiumScreen), findsNothing);
      await tearDownApp(tester);
    });

    testWidgets('« Commencer la nuit » opens Veille; a touch wakes it', (
      tester,
    ) async {
      usePhoneView(tester);
      final model = FakeAppModel();
      await pumpApp(tester, model);
      await tapLabel(tester, 'Sommeil');
      expect(
        find.text(
          'Mesures indicatives, calculées sur votre téléphone. Ne remplace pas un avis médical.',
        ),
        findsOneWidget,
      );
      expect(find.text('Pas encore de nuit'), findsOneWidget);
      await tapText(tester, 'Commencer la nuit');
      expect(model.calls, contains('startNight'));
      expect(find.byType(StandbyScreen), findsOneWidget);
      expect(find.text('Touchez l’écran pour le réveiller'), findsOneWidget);
      expect(find.textContaining('Il reste'), findsOneWidget);
      await tester.tapAt(const Offset(200, 300));
      await settle(tester);
      expect(model.calls, contains('leaveStandby'));
      expect(find.byType(StandbyScreen), findsNothing);
      await tearDownApp(tester);
    });

    testWidgets('loading state shows a message on the menu', (tester) async {
      usePhoneView(tester);
      final model = FakeAppModel();
      await pumpApp(tester, model);
      model.loadingAudio = true;
      await settle(tester);
      expect(find.text('Chargement des sons…'), findsOneWidget);
      await tester.pump(const Duration(seconds: 9));
      expect(find.text('Réseau lent, encore un instant…'), findsOneWidget);
      model.loadingAudio = false;
      await settle(tester);
      expect(find.text('Ambiance de la cascade · Oiseaux · Vent'), findsOneWidget);
      await tearDownApp(tester);
    });

    testWidgets('swipe hint is shown once on the first visit', (tester) async {
      usePhoneView(tester);
      final model = FakeAppModel();
      await pumpApp(tester, model, showHint: true);
      expect(find.text('Balayez pour changer de paysage'), findsOneWidget);
      await swipe(tester, const Offset(0, -220));
      expect(find.text('Balayez pour changer de paysage'), findsNothing);
      await tearDownApp(tester);
    });
  });

  group('Platform hooks', () {
    testWidgets('the swipe hint is stored and not shown again', (tester) async {
      usePhoneView(tester);
      final model = FakeAppModel();
      await pumpApp(tester, model, showHint: true);
      expect(find.text('Balayez pour changer de paysage'), findsOneWidget);
      expect(model.calls, contains('markHintSeen:${HomeScreen.swipeHintId}'));
      expect(model.hintSeen(HomeScreen.swipeHintId), isTrue);
      await tearDownApp(tester);

      // Next launch, same storage: no hint.
      await pumpApp(tester, model, showHint: true);
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.text('Balayez pour changer de paysage'), findsNothing);
      await tearDownApp(tester);
    });

    testWidgets('back on Accueil: exit interstitial first, then the app closes', (
      tester,
    ) async {
      usePhoneView(tester);
      final model = FakeAppModel();
      final platform = <String>[];
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'SystemNavigator.pop') {
          platform.add('pop after ${model.calls.where((c) => c == 'beforeExit').length}');
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await pumpApp(tester, model);

      // Back on another screen only closes it.
      await openRoute(tester, Routes.settings, (_) => const SettingsScreen());
      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(find.byType(SettingsScreen), findsNothing);
      // Back with the timer menu open only closes the menu.
      await tapLabel(tester, RegExp('^Minuteur'));
      expect(label('Durée du minuteur'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(label('Durée du minuteur'), findsNothing);
      expect(model.calls, isNot(contains('beforeExit')));
      expect(platform, isEmpty);

      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(model.calls.where((c) => c == 'beforeExit'), hasLength(1));
      expect(platform, ['pop after 1']);
      await tearDownApp(tester);
    });

    testWidgets('permanently denied: « Ouvrir les réglages » instead of asking', (
      tester,
    ) async {
      usePhoneView(tester);
      final model = FakeAppModel(deniedForever: {PermissionKind.microphone});
      await pumpApp(tester, model);
      await openRoute(tester, Routes.voice, (_) => const VoiceScreen());
      expect(find.text('Continuer'), findsNothing);
      expect(
        find.textContaining('Android ne la demandera plus'),
        findsOneWidget,
      );
      await tapText(tester, 'Ouvrir les réglages');
      expect(model.calls, contains('openAppSettings'));
      expect(model.calls, isNot(contains('requestPermission:microphone')));
      expect(model.calls, isNot(contains('startVoice')));
      expect(find.text('Le micro n’est pas autorisé'), findsOneWidget);

      // Granted from Android's settings: the next try starts listening.
      model.deniedForever.clear();
      await tapText(tester, 'Autoriser le micro');
      await tapText(tester, 'Continuer');
      expect(model.calls, contains('requestPermission:microphone'));
      expect(model.calls, contains('startVoice'));
      await tearDownApp(tester);
    });

    testWidgets('Confidentialité: policy for all, ad choices for the free plan', (
      tester,
    ) async {
      usePhoneView(tester);
      final model = FakeAppModel();
      await pumpApp(tester, model);
      await openRoute(tester, Routes.privacy, (_) => const PrivacyScreen());
      await tapLabel(tester, 'Politique de confidentialité');
      expect(model.calls, contains('openPrivacyPolicy'));
      await tapLabel(tester, 'Choix publicitaires');
      expect(model.calls, contains('openAdPrivacyOptions'));
      model.plan = Plan.annual;
      await settle(tester);
      expect(label('Choix publicitaires'), findsNothing);
      expect(label('Politique de confidentialité'), findsOneWidget);
      await tearDownApp(tester);
    });

    testWidgets('battery guide opens the app settings', (tester) async {
      usePhoneView(tester);
      final model = FakeAppModel();
      await pumpApp(tester, model);
      await openRoute(
        tester,
        Routes.batteryGuide,
        (_) => const BatteryGuideScreen(),
      );
      await tapText(tester, 'Ouvrir les réglages');
      expect(model.calls, contains('openBatteryGuide'));
      await tearDownApp(tester);
    });

    testWidgets('credits show the Google Play price, or a neutral line', (
      tester,
    ) async {
      usePhoneView(tester);
      final model = FakeAppModel(plan: Plan.lifetime, creditsPrice: '2,99 €');
      await pumpApp(tester, model);
      await openRoute(tester, Routes.credits, (_) => const CreditsScreen());
      expect(
        find.text('Prix du pack : 2,99 €, payé une fois sur Google Play.'),
        findsOneWidget,
      );
      model.creditsPrice = null;
      model.plan = Plan.lifetime; // notifies
      await settle(tester);
      expect(
        find.text('Le prix s’affiche dans Google Play avant de payer.'),
        findsOneWidget,
      );
      await tearDownApp(tester);
    });
  });
}
