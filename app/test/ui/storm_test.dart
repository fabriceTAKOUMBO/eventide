// Contract § 11 in the interface: a landscape's ambiance is offered in « Mon mix » with that
// landscape only; a filmed storm (`eclairs`) shows a flash for each strike announced before a thunder
// (soft glow with reduced motion), or rare silent flashes when the mix has no thunder.
import 'dart:async';
import 'dart:math';

import 'package:eventide/core/catalog.dart';
import 'package:eventide/core/lightning.dart';
import 'package:eventide/core/plan.dart';
import 'package:eventide/ui/landscape/lightning_layer.dart';
import 'package:eventide/ui/navigation.dart';
import 'package:eventide/ui/screens/mix_sheet.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_harness.dart';
import 'fake_app_model.dart';
import 'ui_test_utils.dart';

Finder _label(Pattern text) => find.bySemanticsLabel(text);

LightningStrike _strike(double intensity) =>
    LightningStrike(at: DateTime(2026, 10, 29), thunderDelay: const Duration(seconds: 1), intensity: intensity);

void main() {
  group('Mon mix: the ambiance of a landscape', () {
    testWidgets('offered with its own landscape only', (tester) async {
      // A very tall screen: every row of the list is built.
      tester.view.physicalSize = const Size(390 * 3, 3200 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final model = FakeAppModel(plan: Plan.annual);
      await pumpApp(tester, model);
      await openRoute(tester, Routes.mix, (_) => const MixSheet());
      // Cascade en forêt: its ambiance is in the mix, the others are never offered.
      expect(find.text('Ambiance de la cascade'), findsOneWidget);
      expect(_label(RegExp('Ajouter ambiance', caseSensitive: false)), findsNothing);
      expect(find.text('Ambiance de la ville', skipOffstage: false), findsNothing);
      expect(find.text('Ambiance des toits', skipOffstage: false), findsNothing);
      // Removed, it is offered again (with its landscape).
      model.setLayerLevel(LayerKind.son, 'ambiance-cascade-foret', 0);
      await settle(tester);
      expect(_label('Ajouter ambiance de la cascade'), findsOneWidget);
      expect(_label('Ajouter ambiance de la ville'), findsNothing);

      // On « Pluie sur la ville »: its own ambiance and the thunder.
      model.selectLandscape('pluie-ville');
      await settle(tester);
      expect(find.text('Ambiance de la ville'), findsOneWidget);
      expect(find.text('Tonnerre'), findsOneWidget);
      expect(_label('Ajouter ambiance de la cascade'), findsNothing);
      await tearDownApp(tester);
    });
  });

  group('lightning of a filmed storm', () {
    Future<LightningPainter Function()> pump(
      WidgetTester tester, {
      required Stream<LightningStrike> strikes,
      bool thunderInMix = true,
      bool reduced = false,
      bool enabled = true,
      bool active = true,
      int seed = 7,
    }) async {
      await tester.pumpWidget(MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: LightningLayer(
            enabled: enabled,
            active: active,
            lightningStrikes: strikes,
            thunderInMix: thunderInMix,
            random: Random(seed),
          ),
        ),
      ));
      return () => tester
          .widget<CustomPaint>(find.descendant(of: find.byType(LightningLayer), matching: find.byType(CustomPaint)))
          .painter! as LightningPainter;
    }

    testWidgets('a flash for each strike: bright, then gone within 0.6 s', (tester) async {
      final strikes = StreamController<LightningStrike>.broadcast();
      final painter = await pump(tester, strikes: strikes.stream);
      await tester.pump(const Duration(milliseconds: 100));
      expect(painter().flashLevel, 0);
      strikes.add(_strike(0.9));
      await tester.pump(); // the idle layer wakes its ticker
      await tester.pump(const Duration(milliseconds: 16)); // the flash starts at this frame
      await tester.pump(const Duration(milliseconds: 40));
      expect(painter().flashLevel, greaterThan(0.5));
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump(const Duration(milliseconds: 40));
      expect(painter().flashLevel, 0);
      await tester.pumpWidget(const SizedBox());
      await strikes.close();
    });

    testWidgets('nothing on a landscape that is not a filmed storm; no flash while hidden', (tester) async {
      final strikes = StreamController<LightningStrike>.broadcast();
      await pump(tester, strikes: strikes.stream, enabled: false);
      expect(find.byType(CustomPaint), findsNothing, reason: 'nothing drawn at all');
      strikes.add(_strike(1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(find.byType(CustomPaint), findsNothing);
      await tester.pumpWidget(const SizedBox());

      final painter = await pump(tester, strikes: strikes.stream, active: false);
      strikes.add(_strike(1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(painter().flashLevel, 0);
      await tester.pumpWidget(const SizedBox());
      await strikes.close();
    });

    testWidgets('reduced motion: a soft glow only', (tester) async {
      final strikes = StreamController<LightningStrike>.broadcast();
      final painter = await pump(tester, strikes: strikes.stream, reduced: true);
      strikes.add(_strike(1));
      await tester.pump();
      var peak = 0.0;
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        peak = max(peak, painter().flashLevel);
      }
      expect(peak, greaterThan(0.2));
      expect(peak, lessThanOrEqualTo(0.35));
      expect(painter().flashLevel, 0, reason: 'over after 1.6 s');
      await tester.pumpWidget(const SizedBox());
      await strikes.close();
    });

    testWidgets('without thunder in the mix: one silent flash every 2 to 5 minutes, never sooner', (tester) async {
      final gaps = Random(7);
      final first = StormRules.silentFlashGap(gaps);
      final painter = await pump(tester, strikes: const Stream.empty(), thunderInMix: false, seed: 7);
      await tester.pump(first - const Duration(seconds: 1));
      expect(painter().flashLevel, 0);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 40));
      await tester.pump(const Duration(milliseconds: 40));
      expect(painter().flashLevel, greaterThan(0));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('with thunder in the mix: no flash of its own', (tester) async {
      final painter = await pump(tester, strikes: const Stream.empty(), thunderInMix: true);
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(seconds: 30));
        expect(painter().flashLevel, 0);
      }
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the home screen draws it only on a filmed storm that is playing', (tester) async {
      usePhoneView(tester);
      final model = FakeAppModel(plan: Plan.annual);
      await pumpApp(tester, model);
      expect(tester.widget<LightningLayer>(find.byType(LightningLayer)).enabled, isFalse);
      model.selectLandscape('pluie-ville');
      await settle(tester);
      expect(tester.widget<LightningLayer>(find.byType(LightningLayer)).enabled, isTrue);
      expect(tester.widget<LightningLayer>(find.byType(LightningLayer)).thunderInMix, isTrue);
      model.selectLandscape('ondes');
      await settle(tester);
      expect(tester.widget<LightningLayer>(find.byType(LightningLayer)).enabled, isFalse);
      await tearDownApp(tester);
    });
  });
  group('flash envelope', () {
    test('one main flash and one fainter re-flash, nothing after 0.6 s', () {
      expect(lightningFlashLevel(-0.01), 0);
      expect(lightningFlashLevel(0.6), 0);
      expect(lightningFlashLevel(0.03), closeTo(1, 1e-9));
      // Count the peaks over the flash (no strobe: at most two).
      var peaks = 0;
      var previous = 0.0;
      var rising = false;
      for (var t = 0.0; t < 0.7; t += 0.005) {
        final v = lightningFlashLevel(t);
        if (v < previous && rising) peaks++;
        rising = v > previous;
        previous = v;
      }
      expect(peaks, 2);
      expect(lightningFlashLevel(0.33), lessThan(0.6));
    });

    test('soft glow: smooth, at most 0.35, over in 1.6 s', () {
      var top = 0.0;
      for (var t = 0.0; t <= 1.6; t += 0.01) {
        top = max(top, lightningGlowLevel(t));
      }
      expect(top, closeTo(0.35, 0.001));
      expect(lightningGlowLevel(1.6), 0);
      expect(lightningGlowLevel(0.05), lessThan(0.01), reason: 'no sudden flash');
    });
  });
}
