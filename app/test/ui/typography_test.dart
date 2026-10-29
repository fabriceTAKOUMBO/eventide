// « Galerie » typography (product owner, 29 October 2026). Every main screen at the Galaxy
// S24's 384 × 832 dp, with the real fonts, at text scale 1.0 and 1.3: no overflow, no line cut
// by its maximum, only Manrope and Cormorant Garamond, no heavy weight, the display face never
// small. Capitals (buttons, eyebrows) are read by TalkBack as written.
import 'package:eventide/app/app_model.dart';
import 'package:eventide/core/catalog.dart';
import 'package:eventide/core/plan.dart';
import 'package:eventide/core/wallpaper.dart';
import 'package:eventide/ui/landscape/landscape_image.dart';
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
import 'package:eventide/ui/screens/wallpaper_sheet.dart';
import 'package:eventide/ui/theme/vitre.dart';
import 'package:eventide/ui/widgets/permission_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_harness.dart';
import 'fake_app_model.dart';
import 'screens_preview_test.dart' show sampleNights, sampleSchedule;
import 'ui_test_utils.dart';

class _Model extends FakeAppModel {
  _Model({super.onboarded, super.schedules, super.nights});

  @override
  WallpaperSupport get wallpaperSupport => const WallpaperSupport(liveWallpaper: true);
}

/// Galaxy S24: 1080 × 2340 px at 2.8125, i.e. 384 × 832 dp.
void _useS24(WidgetTester tester, double scale) {
  usePhoneView(tester, textScale: scale);
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 2.8125;
  tester.view.padding = const FakeViewPadding(top: 24 * 2.8125, bottom: 16 * 2.8125);
  tester.view.viewPadding = const FakeViewPadding(top: 24 * 2.8125, bottom: 16 * 2.8125);
}

const Set<String> _families = {'Manrope', kDisplayFamily};

/// No layout error, and every text on screen follows the type roles.
void _expectCleanText(WidgetTester tester, String where) {
  expect(tester.takeException(), isNull, reason: '$where: layout error');
  var count = 0;
  for (final element in find.byType(RichText).evaluate()) {
    final widget = element.widget as RichText;
    final paragraph = element.renderObject! as RenderParagraph;
    final text = widget.text.toPlainText();
    if (text.trim().isEmpty) continue;
    count++;
    expect(paragraph.didExceedMaxLines, isFalse, reason: '$where: « $text » is cut');
    widget.text.visitChildren((span) {
      final style = span.style;
      if (style == null) return true;
      final family = style.fontFamily;
      if (family != null) {
        expect(_families, contains(family), reason: '$where: « $text » in $family');
      }
      final weight = style.fontWeight ?? FontWeight.w400;
      expect(weight.value, lessThanOrEqualTo(600), reason: '$where: « $text » in $weight');
      for (final v in style.fontVariations ?? const <FontVariation>[]) {
        if (v.axis == 'wght') {
          expect(v.value, lessThanOrEqualTo(600), reason: '$where: « $text » at wght ${v.value}');
        }
      }
      if (family == kDisplayFamily) {
        expect(style.fontSize, greaterThanOrEqualTo(20), reason: '$where: « $text » too small for the display face');
      }
      return true;
    });
  }
  expect(count, greaterThan(0), reason: '$where: nothing drawn');
}

typedef _Screen = (String name, WidgetBuilder builder);

final List<_Screen> _sheets = [
  (Routes.landscapes, (_) => const LandscapesSheet()),
  (Routes.mix, (_) => const MixSheet()),
  ('mon-mix-musique', (_) => const MixSheet(initialKind: LayerKind.musique)),
  ('mon-mix-decor', (_) => const MixSheet(initialKind: LayerKind.decor)),
  (Routes.share, (_) => const ShareScreen()),
  (Routes.sleep, (_) => const SleepScreen()),
  (Routes.standby, (_) => const StandbyScreen()),
  (Routes.schedules, (_) => const SchedulesScreen()),
  (Routes.scheduleEditor, (_) => const ScheduleEditorScreen()),
  ('modifier-programmation', (_) => ScheduleEditorScreen(existing: sampleSchedule())),
  (Routes.premium, (_) => const PremiumScreen()),
  (Routes.settings, (_) => const SettingsScreen()),
  (Routes.privacy, (_) => const PrivacyScreen()),
  (Routes.batteryGuide, (_) => const BatteryGuideScreen()),
  (WallpaperSheet.routeName, (_) => const WallpaperSheet(landscapeId: 'cascade-foret')),
  ('fond-ecran-premium', (_) => const WallpaperSheet(landscapeId: 'pluie-ville')),
];

void main() {
  setUpAll(loadAppFonts);
  setUp(() => LandscapeImages.debugSetVideos(bundled: {'cascade-foret'}));
  tearDown(() => LandscapeImages.debugSetVideos());

  test('the display face is really loaded, upright and italic', () {
    double width(TextStyle style) {
      final painter = TextPainter(
        text: TextSpan(text: 'Cascade en forêt', style: style),
        textDirection: TextDirection.ltr,
      )..layout();
      final w = painter.width;
      painter.dispose();
      return w;
    }

    final italic = VitreType.display(size: 32);
    final upright = VitreType.title(size: 32);
    expect(italic.fontFamily, kDisplayFamily);
    expect(italic.fontStyle, FontStyle.italic);
    expect(italic.fontWeight, FontWeight.w500);
    expect(upright.fontStyle, FontStyle.normal);
    // The test font draws every glyph as a 1 em square: 16 × 32 = 512 px.
    expect(width(upright), lessThan(16 * 32 * 0.6));
    expect(width(italic), lessThan(16 * 32 * 0.6));
    // Two different files: the italic is narrower.
    expect(width(italic), lessThan(width(upright)));
  });

  for (final scale in const [1.0, 1.3]) {
    group('384 × 832, text scale $scale', () {
      testWidgets('welcome, home (expanded, collapsed, locked, timer), offline', (tester) async {
        _useS24(tester, scale);
        final model = _Model(onboarded: false);
        await pumpApp(tester, model, showHint: true);
        _expectCleanText(tester, 'Bienvenue');
        // TalkBack reads the button as written, not letter by letter.
        expect(findCaps('Commencer'), findsOneWidget);
        expect(find.bySemanticsLabel('Commencer'), findsOneWidget);
        expect(find.bySemanticsLabel('COMMENCER'), findsNothing);

        await model.completeOnboarding();
        await settle(tester);
        _expectCleanText(tester, 'Accueil');
        final name = tester.widget<Text>(find.text('Cascade en forêt'));
        expect(name.style!.fontFamily, kDisplayFamily);
        expect(name.style!.fontStyle, FontStyle.italic);

        await tester.tap(find.bySemanticsLabel(RegExp('^Minuteur')));
        await settle(tester);
        _expectCleanText(tester, 'Accueil, minuteur');
        await tester.tap(find.text('Sans minuteur'));
        await settle(tester);

        await tester.tap(find.bySemanticsLabel('Réduire le menu pour voir plus de paysage'));
        await settle(tester);
        _expectCleanText(tester, 'Accueil replié');
        await tester.tap(find.bySemanticsLabel('Afficher le menu complet'));
        await settle(tester);

        await model.saveSchedule(sampleSchedule());
        model.browseLandscape('aurore-boreale');
        await settle(tester);
        _expectCleanText(tester, 'Accueil, paysage Premium');

        model.online = false;
        model.browseLandscape('cascade-foret');
        await settle(tester);
        expect(find.text('Pas de connexion'), findsOneWidget);
        _expectCleanText(tester, 'Hors connexion');
        await tearDownApp(tester);
      });

      testWidgets('every sheet, free plan then annual', (tester) async {
        _useS24(tester, scale);
        final model = _Model(
          schedules: [sampleSchedule()],
          nights: sampleNights(DateTime(2026, 10, 28, 20, 30)),
        );
        model.addFavoriteForTest(model.scene);
        await pumpApp(tester, model);
        for (final (name, builder) in _sheets) {
          await openRoute(tester, name, builder);
          _expectCleanText(tester, '$name (gratuit)');
          navigatorOf(tester).pop();
          await settle(tester);
        }
        model.plan = Plan.annual;
        for (final (name, builder) in _sheets) {
          await openRoute(tester, name, builder);
          _expectCleanText(tester, '$name (annuel)');
          navigatorOf(tester).pop();
          await settle(tester);
        }
        await tearDownApp(tester);
      });

      testWidgets('dialogs: permissions and data deletion', (tester) async {
        _useS24(tester, scale);
        await pumpApp(tester, _Model());
        final context = tester.element(find.byType(Navigator).first);
        for (final kind in PermissionKind.values) {
          for (final denied in const [false, true]) {
            final model = _Model();
            if (denied) model.deniedForever.add(kind);
            final result = explainAndRequestPermission(context, model, kind);
            await settle(tester);
            _expectCleanText(tester, '${kind.name}${denied ? ' (refusée)' : ''}');
            await tester.tap(find.text('Plus tard'));
            await settle(tester);
            expect(await result, isFalse);
          }
        }
        await openRoute(tester, Routes.privacy, (_) => const PrivacyScreen());
        await tester.ensureVisible(findCaps('Supprimer mes données'));
        await settle(tester);
        await tester.tap(findCaps('Supprimer mes données'));
        await settle(tester);
        expect(find.text('Supprimer mes données ?'), findsOneWidget);
        _expectCleanText(tester, 'Supprimer mes données ?');
        await tester.tap(find.text('Garder mes données'));
        await settle(tester);
        await tearDownApp(tester);
      });
    });
  }
}
