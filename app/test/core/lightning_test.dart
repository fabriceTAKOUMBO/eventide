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
}
