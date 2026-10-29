import 'dart:math';

import 'package:eventide/core/lightning.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('StormRules.pickVariant (contract § 11: never one of the two last played)', () {
    const ids = ['a', 'b', 'c', 'd'];

    test('avoids the two last played', () {
      final random = Random(5);
      for (var i = 0; i < 200; i++) {
        expect(StormRules.pickVariant(ids, const ['c', 'a'], random), isIn(const ['b', 'd']));
      }
    });

    test('only what leaves a choice is avoided', () {
      final random = Random(5);
      expect(StormRules.pickVariant(const ['a', 'b', 'c'], const ['a', 'b'], random), 'c');
      // Two variants: never the last one.
      for (var i = 0; i < 50; i++) {
        expect(StormRules.pickVariant(const ['a', 'b'], const ['b', 'a'], random), 'b');
      }
      // A single variant is replayed.
      expect(StormRules.pickVariant(const ['a'], const ['a'], random), 'a');
      expect(() => StormRules.pickVariant(const [], const [], random), throwsArgumentError);
    });

    test('every variant comes up', () {
      final random = Random(9);
      final seen = <String>{};
      final recent = <String>[];
      for (var i = 0; i < 100; i++) {
        final v = StormRules.pickVariant(ids, recent, random);
        seen.add(v);
        recent.add(v);
        if (recent.length > 2) recent.removeAt(0);
      }
      expect(seen, ids.toSet());
    });
  });

  test('draw: gain -6..0 dB, speed 0.92..1.08, pan -0.4..0.4', () {
    final random = Random(1);
    for (var i = 0; i < 500; i++) {
      final d = StormRules.draw(const ['a', 'b', 'c'], const [], random);
      expect(d.gain, inInclusiveRange(pow(10, -6 / 20), 1.0));
      expect(d.speed, inInclusiveRange(0.92, 1.08));
      expect(d.pan, inInclusiveRange(-0.4, 0.4));
    }
  });

  test('thunder delay 0.4-3.5 s; the shorter, the brighter', () {
    final random = Random(2);
    for (var i = 0; i < 200; i++) {
      expect(StormRules.thunderDelay(random).inMilliseconds, inInclusiveRange(400, 3500));
    }
    expect(StormRules.intensityFor(const Duration(milliseconds: 400)), 1.0);
    expect(StormRules.intensityFor(const Duration(milliseconds: 3500)), closeTo(0.35, 1e-9));
    expect(
      StormRules.intensityFor(const Duration(seconds: 1)),
      greaterThan(StormRules.intensityFor(const Duration(seconds: 2))),
    );
  });

  test('silent flashes of the decor: one every 2 to 5 minutes', () {
    final random = Random(4);
    for (var i = 0; i < 200; i++) {
      final gap = StormRules.silentFlashGap(random);
      expect(gap.inSeconds, inInclusiveRange(120, 300));
    }
  });

  group('storm plans (catalog `orage`, contract § 11)', () {
    const parts = {
      StormPart.avant: ['a1', 'a2', 'a3'],
      StormPart.coup: ['c1', 'c2', 'c3', 'c4'],
      StormPart.coupProche: ['p1', 'p2', 'p3'],
      StormPart.replique: ['r1', 'r2', 'r3'],
      StormPart.lointain: ['l1', 'l2', 'l3', 'l4'],
    };
    double s(Duration d) => d.inMicroseconds / 1e6;

    test('drawable: a kind needs a weight above 0 and its required part', () {
      const weights = {StormKind.lointain: 25.0, StormKind.orage: 55.0, StormKind.proche: 20.0};
      expect(StormRules.drawable(weights, parts.keys.toSet()), weights);
      expect(StormRules.drawable(weights, {StormPart.coup, StormPart.replique}), {StormKind.orage: 55.0});
      expect(StormRules.drawable(const {StormKind.orage: 0, StormKind.single: 3}, parts.keys.toSet()), isEmpty);
      expect(StormRules.drawable(weights, {StormPart.avant, StormPart.replique}), isEmpty);
    });

    test('drawKind follows the weights', () {
      final random = Random(11);
      const weights = {StormKind.lointain: 25.0, StormKind.orage: 55.0, StormKind.proche: 20.0};
      final counts = <StormKind, int>{};
      for (var i = 0; i < 20000; i++) {
        final k = StormRules.drawKind(weights, random);
        counts[k] = (counts[k] ?? 0) + 1;
      }
      for (final e in weights.entries) {
        expect(counts[e.key]! / 20000, closeTo(e.value / 100, 0.015), reason: e.key.key);
      }
    });

    test('orage: pre-rumble at 0, flash 2.5-5.5 s later, strike 1.2-3.5 s after it, swells after the strike', () {
      final random = Random(3);
      var aftershocks = 0;
      for (var i = 0; i < 2000; i++) {
        final plan = StormRules.plan(StormKind.orage, parts, const {}, random);
        final sounds = plan.sounds.toList();
        expect(sounds.first.part, StormPart.avant);
        expect(sounds.first.at, Duration.zero);
        final flash = plan.flashes.first;
        expect(s(flash.at), inInclusiveRange(2.5, 5.5));
        expect(s(flash.delay), inInclusiveRange(1.2, 3.5));
        expect(flash.intensity, closeTo(StormRules.intensityFor(flash.delay), 1e-12));
        final strike = sounds[1];
        expect(strike.part, StormPart.coup);
        expect(strike.at, flash.at + flash.delay);
        expect(plan.announcedBy(plan.steps.indexOf(flash)), same(strike));
        final swells = plan.steps.whereType<StormSwell>().toList();
        expect(swells.map((w) => w.target).toSet(), {SwellTarget.averse, SwellTarget.rafale});
        for (final w in swells) {
          expect(w.at > strike.at, isTrue);
          expect(w.gainDb, inInclusiveRange(1.5, 3.0));
        }
        if (sounds.length == 3) {
          aftershocks++;
          expect(sounds[2].part, StormPart.replique);
          expect(s(sounds[2].at - strike.at), inInclusiveRange(8, 20));
        }
        // Time order, flash before its sound.
        for (var j = 1; j < plan.steps.length; j++) {
          expect(plan.steps[j].at >= plan.steps[j - 1].at, isTrue);
        }
      }
      expect(aftershocks / 2000, closeTo(0.3, 0.04));
    });

    test('orage without a pre-rumble part: the flash opens the event', () {
      final plan = StormRules.plan(StormKind.orage, {StormPart.coup: ['c1']}, const {}, Random(1));
      expect(plan.steps.first, isA<StormFlash>());
      expect(plan.steps.first.at, Duration.zero);
      expect(plan.sounds.map((x) => x.part), [StormPart.coup], reason: 'no replique part: no aftershock');
    });

    test('proche: flash at 0, close strike 0.4-1.2 s later, always an aftershock 5-20 s after', () {
      final random = Random(5);
      var faint = 0;
      for (var i = 0; i < 2000; i++) {
        final plan = StormRules.plan(StormKind.proche, parts, const {}, random);
        final flashes = plan.flashes.toList();
        final [strike, after] = plan.sounds.toList();
        expect(flashes.first.at, Duration.zero);
        expect(s(flashes.first.delay), inInclusiveRange(0.4, 1.2));
        expect(strike.part, StormPart.coupProche);
        expect(strike.at, flashes.first.delay);
        expect(after.part, StormPart.replique);
        expect(s(after.at - strike.at), inInclusiveRange(5, 20));
        if (flashes.length == 2) {
          faint++;
          final f = flashes[1];
          expect(f.at + f.delay, after.at);
          expect(s(f.at), greaterThanOrEqualTo(3));
          expect(s(f.delay), inInclusiveRange(0.0001, 3.5));
          expect(f.intensity, inInclusiveRange(0.15, 0.3));
        }
      }
      expect(faint / 2000, closeTo(0.5, 0.04));
    });

    test('lointain: the rumble alone, a faint flash 4 times in 10, never a swell', () {
      final random = Random(7);
      var lit = 0;
      for (var i = 0; i < 2000; i++) {
        final plan = StormRules.plan(StormKind.lointain, parts, const {}, random);
        final sound = plan.sounds.single;
        expect(sound.part, StormPart.lointain);
        expect(plan.steps.whereType<StormSwell>(), isEmpty);
        if (plan.flashes.isEmpty) {
          expect(sound.at, Duration.zero);
        } else {
          lit++;
          final f = plan.flashes.single;
          expect(f.at, Duration.zero);
          expect(sound.at, f.delay);
          expect(s(f.delay), inInclusiveRange(3.5, 6));
          expect(f.intensity, inInclusiveRange(0.12, 0.25));
        }
      }
      expect(lit / 2000, closeTo(0.4, 0.04));
    });

    test('swells: rain +1.5..3 dB 0.8-2.5 s after the strike, rise 2.5-4, hold 2-5, fall 6-10; gust faster', () {
      final random = Random(9);
      for (var i = 0; i < 1000; i++) {
        final plan = StormRules.plan(i.isEven ? StormKind.orage : StormKind.proche, parts, const {}, random);
        final strike = plan.sounds.firstWhere((x) => x.part!.isStrike);
        for (final w in plan.steps.whereType<StormSwell>()) {
          final after = s(w.at - strike.at);
          if (w.target == SwellTarget.averse) {
            expect(after, inInclusiveRange(0.8, 2.5));
            expect(s(w.rise), inInclusiveRange(2.5, 4));
            expect(s(w.hold), inInclusiveRange(2, 5));
            expect(s(w.fall), inInclusiveRange(6, 10));
          } else {
            expect(after, inInclusiveRange(0.3, 1.5));
            expect(s(w.rise), inInclusiveRange(0.8, 1.5));
            expect(s(w.hold), inInclusiveRange(0.3, 1));
            expect(s(w.fall), inInclusiveRange(3, 5));
          }
          expect(w.gainDb, inInclusiveRange(StormRules.minSwellDb, StormRules.maxSwellDb));
        }
      }
    });

    test('parts: never one of the two last of their type; gain -3..0 dB; one direction per event', () {
      final random = Random(13);
      for (var i = 0; i < 1000; i++) {
        final plan = StormRules.plan(StormKind.orage, parts, const {
          StormPart.coup: ['c1', 'c2'],
          StormPart.avant: ['a3', 'a1'],
        }, random);
        final sounds = plan.sounds.toList();
        expect(sounds[0].variant, 'a2');
        expect(sounds[1].variant, isIn(const ['c3', 'c4']));
        final pans = [for (final x in sounds) x.pan];
        expect(pans.reduce(max) - pans.reduce(min), lessThanOrEqualTo(0.3 + 1e-9));
        for (final x in sounds) {
          expect(x.gain, inInclusiveRange(pow(10, -3 / 20), 1.0));
          expect(x.speed, inInclusiveRange(0.92, 1.08));
          expect(x.pan, inInclusiveRange(-0.4, 0.4));
        }
      }
    });

    test('single plan (no `orage`): a flash, then one variant 0.4-3.5 s later', () {
      final random = Random(17);
      for (var i = 0; i < 500; i++) {
        final plan = StormRules.singlePlan(const ['a', 'b', 'c'], const ['a', 'b'], random);
        expect(plan.kind, StormKind.single);
        final flash = plan.flashes.single;
        final sound = plan.sounds.single;
        expect(sound.variant, 'c');
        expect(sound.part, isNull);
        expect(sound.at, flash.delay);
        expect(flash.delay.inMilliseconds, inInclusiveRange(400, 3500));
        expect(sound.gain, inInclusiveRange(pow(10, -6 / 20), 1.0));
      }
      expect(() => StormRules.plan(StormKind.single, parts, const {}, random), throwsArgumentError);
    });

    test('catalog keys of the parts and kinds', () {
      expect([for (final p in StormPart.values) p.key], ['avant', 'coup', 'coup-proche', 'replique', 'lointain']);
      expect(StormPart.fromKey('coup-proche'), StormPart.coupProche);
      expect(StormPart.fromKey('tonnerre'), isNull);
      expect(StormKind.fromKey('orage'), StormKind.orage);
      expect(StormKind.fromKey('variante'), isNull, reason: 'single is not a catalog kind');
      expect(StormPart.coup.isStrike && StormPart.coupProche.isStrike, isTrue);
      expect(StormPart.replique.isStrike, isFalse);
    });
  });
}
