// Storm rules of the API contract § 11: how each event of a sound played by events is drawn
// (variant, gain, speed, stereo position) and the lightning flash that comes before a thunder.
// Pure Dart: the scheduler (services/audio/event_scheduler.dart) and the lightning layer use them.
import 'dart:math' as math;

/// A lightning strike announced by the thunder of the mix: a filmed storm (`eclairs`) shows a flash at
/// [at], the thunder follows [thunderDelay] later. [intensity] (0..1) is higher when the delay
/// is shorter (a close strike is brighter and louder).
class LightningStrike {
  const LightningStrike({required this.at, required this.thunderDelay, required this.intensity});

  /// When the flash is drawn.
  final DateTime at;

  /// Time from the flash to the thunder: [StormRules.minThunderDelay] to [StormRules.maxThunderDelay].
  final Duration thunderDelay;

  /// 0..1: brightness of the flash.
  final double intensity;

  @override
  String toString() => 'LightningStrike(${thunderDelay.inMilliseconds} ms, ${intensity.toStringAsFixed(2)})';
}

/// One event of a sound played by events: which variant, and its slight random variations.
class EventDraw {
  const EventDraw({required this.variant, required this.gain, required this.speed, required this.pan});

  final String variant;

  /// Linear gain factor applied on top of the sound's level (−6 to 0 dB).
  final double gain;

  /// Relative playback speed (0.92 to 1.08).
  final double speed;

  /// Stereo position (−0.4 to 0.4).
  final double pan;
}

abstract final class StormRules {
  /// Random gain of an event, in dB.
  static const double minGainDb = -6;
  static const double maxGainDb = 0;

  /// Random playback speed of an event.
  static const double minSpeed = 0.92;
  static const double maxSpeed = 1.08;

  /// Random stereo position of an event.
  static const double maxPan = 0.4;

  /// How many of the last variants played are never replayed.
  static const int noRepeat = 2;

  /// The thunder follows its flash after this much time.
  static const Duration minThunderDelay = Duration(milliseconds: 400);
  static const Duration maxThunderDelay = Duration(milliseconds: 3500);

  /// Silent flashes of a filmed storm (`eclairs`) when the mix has no thunder: one every 2 to 5 min.
  static const Duration minSilentFlashGap = Duration(minutes: 2);
  static const Duration maxSilentFlashGap = Duration(minutes: 5);

  /// Picks a variant at random, never one of the [noRepeat] last played ([recent], oldest
  /// first). With too few variants, only the most recent ones that leave a choice are avoided.
  static String pickVariant(List<String> variants, List<String> recent, math.Random random) {
    if (variants.isEmpty) throw ArgumentError('no variant');
    final avoid = <String>{};
    for (final id in recent.reversed) {
      if (avoid.length >= noRepeat) break;
      final left = variants.where((v) => !avoid.contains(v) && v != id);
      if (left.isEmpty) break;
      avoid.add(id);
    }
    final choices = [for (final v in variants) if (!avoid.contains(v)) v];
    return choices[random.nextInt(choices.length)];
  }

  /// The variant and the random variations of the next event.
  static EventDraw draw(List<String> variants, List<String> recent, math.Random random) {
    final variant = pickVariant(variants, recent, random);
    final db = minGainDb + (maxGainDb - minGainDb) * random.nextDouble();
    return EventDraw(
      variant: variant,
      gain: math.pow(10, db / 20).toDouble(),
      speed: minSpeed + (maxSpeed - minSpeed) * random.nextDouble(),
      pan: -maxPan + 2 * maxPan * random.nextDouble(),
    );
  }

  /// Delay from the flash to the thunder, drawn at random.
  static Duration thunderDelay(math.Random random) {
    final lo = minThunderDelay.inMicroseconds;
    final hi = maxThunderDelay.inMicroseconds;
    return Duration(microseconds: lo + ((hi - lo) * random.nextDouble()).round());
  }

  /// Brightness of the flash for a thunder [delay]: 1 at the shortest delay, 0.35 at the longest.
  static double intensityFor(Duration delay) {
    final lo = minThunderDelay.inMicroseconds;
    final hi = maxThunderDelay.inMicroseconds;
    final u = ((delay.inMicroseconds - lo) / (hi - lo)).clamp(0.0, 1.0);
    return 1.0 - 0.65 * u;
  }

  /// Gap before the next silent flash of a filmed storm (no thunder in the mix).
  static Duration silentFlashGap(math.Random random) {
    final lo = minSilentFlashGap.inMilliseconds;
    final hi = maxSilentFlashGap.inMilliseconds;
    return Duration(milliseconds: lo + ((hi - lo) * random.nextDouble()).round());
  }
}
