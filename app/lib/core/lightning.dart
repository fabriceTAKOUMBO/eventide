// Storm rules of the API contract § 11: how each event of a sound played by events is drawn
// and the lightning flash that comes before a thunder. Without `orage` (catalog), an event is
// one variant ([StormRules.singlePlan]); with it, a storm sequence of parts
// ([StormRules.plan]): a distant rumble alone, a soft pre-rumble then the flash then the strike
// and its roll, or a close strike and its aftershock, with the rain redoubling and a gust after
// a strong strike. Pure Dart: the scheduler (services/audio/event_scheduler.dart) plays the
// plans, the lightning layer draws the flashes.
import 'dart:math' as math;

/// A lightning strike announced by the thunder of the mix: a filmed storm (`eclairs`) shows a flash at
/// [at], the thunder follows [thunderDelay] later. [intensity] (0..1) is higher when the delay
/// is shorter (a close strike is brighter and louder); a distant one is faint (0.12 to 0.3).
class LightningStrike {
  const LightningStrike({required this.at, required this.thunderDelay, required this.intensity});

  /// When the flash is drawn.
  final DateTime at;

  /// Time from the flash to the sound it announces: 0.4 to 3.5 s for a strike, up to 6 s for a
  /// distant rumble.
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

/// Types of parts of a storm (catalog `orage.parties`).
enum StormPart {
  /// Soft rumble before the flash.
  avant('avant'),

  /// Strike and its long rolling rumble.
  coup('coup'),

  /// Close strike: sharper crack.
  coupProche('coup-proche'),

  /// Weaker rumble that follows a strike.
  replique('replique'),

  /// Distant rolling rumble, no crack.
  lointain('lointain');

  const StormPart(this.key);

  /// Key in the catalog.
  final String key;

  /// A strike: its flash comes first, the rain redoubles after it.
  bool get isStrike => this == coup || this == coupProche;

  static StormPart? fromKey(Object? key) {
    for (final p in values) {
      if (p.key == key) return p;
    }
    return null;
  }
}

/// Kinds of storm events (catalog `orage.sequences`; [single]: no `orage`, one variant).
enum StormKind {
  /// One variant after a flash (no `orage` in the catalog, or no sequence possible).
  single('variante', null),

  /// A distant rumble alone, a faint flash or none.
  lointain('lointain', StormPart.lointain),

  /// Pre-rumble, flash, strike after the distance delay, sometimes an aftershock.
  orage('orage', StormPart.coup),

  /// Flash, close strike after a short delay, an aftershock 5 to 20 s later.
  proche('proche', StormPart.coupProche);

  const StormKind(this.key, this.required);

  /// Key in the catalog (`orage.sequences`).
  final String key;

  /// The part without which this kind is never drawn.
  final StormPart? required;

  static StormKind? fromKey(Object? key) {
    for (final k in values) {
      if (k != single && k.key == key) return k;
    }
    return null;
  }
}

/// Loops that swell after a strong strike: the rain redoubling (`orage.averse`) or a light
/// gust of wind (`orage.rafale`).
enum SwellTarget { averse, rafale }

/// One step of a [StormPlan], [at] its time from the start of the event.
sealed class StormStep {
  const StormStep(this.at);

  final Duration at;
}

/// A lightning flash; the sound it announces is the next [StormSound] of the plan, [delay]
/// later.
class StormFlash extends StormStep {
  const StormFlash(super.at, {required this.delay, required this.intensity});

  final Duration delay;

  /// 0..1 ([LightningStrike.intensity]).
  final double intensity;

  @override
  String toString() => 'flash@${at.inMilliseconds}(${delay.inMilliseconds} ms, ${intensity.toStringAsFixed(2)})';
}

/// A part played: one variant with its random variations.
class StormSound extends StormStep {
  const StormSound(super.at, {required this.part, required this.variant, required this.gain, required this.speed, required this.pan});

  /// Null for a [StormKind.single] event (a variant of `variantes`).
  final StormPart? part;
  final String variant;

  /// Linear gain on top of the sound's level.
  final double gain;
  final double speed;
  final double pan;

  @override
  String toString() => '${part?.key ?? 'variante'}@${at.inMilliseconds}($variant)';
}

/// The loops of [target] swell by [gainDb]: up over [rise], held [hold], back over [fall]. Only
/// after a strike that played.
class StormSwell extends StormStep {
  const StormSwell(super.at, {required this.target, required this.gainDb, required this.rise, required this.hold, required this.fall});

  final SwellTarget target;
  final double gainDb;
  final Duration rise;
  final Duration hold;
  final Duration fall;

  @override
  String toString() => '${target.name}@${at.inMilliseconds}(+${gainDb.toStringAsFixed(1)} dB)';
}

/// One storm event: its steps in time order.
class StormPlan {
  StormPlan(this.kind, List<StormStep> steps) : steps = List.unmodifiable(_inTimeOrder(steps));

  /// Stable sort by time: steps at the same time keep the order they were added in.
  static List<StormStep> _inTimeOrder(List<StormStep> steps) {
    final order = List<int>.generate(steps.length, (i) => i)
      ..sort((a, b) {
        final c = steps[a].at.compareTo(steps[b].at);
        return c != 0 ? c : a.compareTo(b);
      });
    return [for (final i in order) steps[i]];
  }

  final StormKind kind;
  final List<StormStep> steps;

  Iterable<StormSound> get sounds => steps.whereType<StormSound>();
  Iterable<StormFlash> get flashes => steps.whereType<StormFlash>();

  /// Time of the last step (the event lasts at least until then, plus its last sound).
  Duration get lastStepAt => steps.isEmpty ? Duration.zero : steps.last.at;

  /// The sound announced by the flash at [index]: the next sound of the plan.
  StormSound? announcedBy(int index) {
    for (var i = index + 1; i < steps.length; i++) {
      final s = steps[i];
      if (s is StormSound) return s;
    }
    return null;
  }

  @override
  String toString() => 'StormPlan(${kind.key}: ${steps.join(', ')})';
}

/// A `[min, max]` range of the storm rules (seconds, dB or intensity).
class StormRange {
  const StormRange(this.min, this.max);

  final double min;
  final double max;

  /// A value drawn uniformly in the range.
  double draw(math.Random random) => min + (max - min) * random.nextDouble();

  /// A duration drawn uniformly in the range (seconds).
  Duration seconds(math.Random random) => Duration(microseconds: (draw(random) * 1e6).round());

  /// [d] is in the range (to the microsecond).
  bool containsDuration(Duration d) =>
      d.inMicroseconds >= (min * 1e6).round() && d.inMicroseconds <= (max * 1e6).round();

  @override
  String toString() => '[$min, $max]';
}

abstract final class StormRules {
  /// Random gain of a single event, in dB.
  static const double minGainDb = -6;
  static const double maxGainDb = 0;

  /// Random gain of a part of a sequence, in dB (the files carry the natural level differences
  /// between the parts).
  static const double minPartGainDb = -3;

  /// Random playback speed of an event.
  static const double minSpeed = 0.92;
  static const double maxSpeed = 1.08;

  /// Random stereo position of an event (of a whole sequence).
  static const double maxPan = 0.4;

  /// Each part of a sequence: this far around the sequence's position (bounded by [maxPan]).
  static const double partPanSpread = 0.15;

  /// How many of the last variants played (of a part type) are never replayed.
  static const int noRepeat = 2;

  /// The thunder of a single event follows its flash after this much time.
  static const Duration minThunderDelay = Duration(milliseconds: 400);
  static const Duration maxThunderDelay = Duration(milliseconds: 3500);

  /// Silent flashes of a filmed storm (`eclairs`) when the mix has no thunder: one every 2 to 5 min.
  static const Duration minSilentFlashGap = Duration(minutes: 2);
  static const Duration maxSilentFlashGap = Duration(minutes: 5);

  // ---- Sequences (catalog `orage`)

  /// `lointain`: no flash this often; otherwise a faint one, the rumble [distantDelay] later.
  static const double distantNoFlash = 0.6;
  static const StormRange distantIntensity = StormRange(0.12, 0.25);
  static const StormRange distantDelay = StormRange(3.5, 6.0);

  /// `orage`: the flash this long after the start of the pre-rumble, the strike [stormDelay]
  /// after the flash; an aftershock [stormAftershock] of the time, [stormAftershockAt] after
  /// the strike.
  static const StormRange preRumbleToFlash = StormRange(2.5, 5.5);
  static const StormRange stormDelay = StormRange(1.2, 3.5);
  static const double stormAftershock = 0.3;
  static const StormRange stormAftershockAt = StormRange(8, 20);

  /// `proche`: the close strike [closeDelay] after the flash, its aftershock [closeAftershockAt]
  /// after the strike.
  static const StormRange closeDelay = StormRange(0.4, 1.2);
  static const StormRange closeAftershockAt = StormRange(5, 20);

  /// An aftershock has a faint flash half of the time, [aftershockFlashLead] before it, never
  /// less than [flashGap] after the strike's flash.
  static const double aftershockFlash = 0.5;
  static const StormRange aftershockFlashLead = StormRange(2.0, 3.5);
  static const StormRange aftershockIntensity = StormRange(0.15, 0.3);
  static const Duration flashGap = Duration(seconds: 3);

  /// After a strike: the rain redoubles (`orage.averse`)...
  static const StormRange averseGainDb = StormRange(1.5, 3.0);
  static const StormRange averseStart = StormRange(0.8, 2.5);
  static const StormRange averseRise = StormRange(2.5, 4.0);
  static const StormRange averseHold = StormRange(2.0, 5.0);
  static const StormRange averseFall = StormRange(6.0, 10.0);

  /// ...and a light gust of wind (`orage.rafale`).
  static const StormRange gustGainDb = StormRange(1.5, 3.0);
  static const StormRange gustStart = StormRange(0.3, 1.5);
  static const StormRange gustRise = StormRange(0.8, 1.5);
  static const StormRange gustHold = StormRange(0.3, 1.0);
  static const StormRange gustFall = StormRange(3.0, 5.0);

  /// Bounds of the swells (both kinds), for the engine and the tests.
  static const double minSwellDb = 1.5;
  static const double maxSwellDb = 3.0;

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

  /// The variant and the random variations of the next single event.
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

  /// Delay from the flash to the thunder of a single event, drawn at random.
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

  /// A single event (no `orage`): a flash, then one variant 0.4 to 3.5 s later.
  static StormPlan singlePlan(List<String> variants, List<String> recent, math.Random random) {
    final delay = thunderDelay(random);
    final d = draw(variants, recent, random);
    return StormPlan(StormKind.single, [
      StormFlash(Duration.zero, delay: delay, intensity: intensityFor(delay)),
      StormSound(delay, part: null, variant: d.variant, gain: d.gain, speed: d.speed, pan: d.pan),
    ]);
  }

  /// The kinds that can be drawn: a weight above 0 and their required part present.
  static Map<StormKind, double> drawable(Map<StormKind, double> weights, Set<StormPart> parts) => {
        for (final e in weights.entries)
          if (e.key != StormKind.single && e.value > 0 && parts.contains(e.key.required)) e.key: e.value,
      };

  /// A kind drawn according to [weights] (already [drawable], not empty).
  static StormKind drawKind(Map<StormKind, double> weights, math.Random random) {
    final total = weights.values.fold<double>(0, (a, b) => a + b);
    var u = random.nextDouble() * total;
    for (final e in weights.entries) {
      u -= e.value;
      if (u < 0) return e.key;
    }
    return weights.keys.last;
  }

  /// A storm event of [kind] from [parts] (variant ids per type), never a variant among the
  /// [noRepeat] last played of its type ([recent], oldest first).
  static StormPlan plan(
    StormKind kind,
    Map<StormPart, List<String>> parts,
    Map<StormPart, List<String>> recent,
    math.Random random,
  ) {
    final pan = -maxPan + 2 * maxPan * random.nextDouble();
    StormSound sound(Duration at, StormPart part) {
      final variant = pickVariant(parts[part]!, recent[part] ?? const [], random);
      final db = minPartGainDb + (maxGainDb - minPartGainDb) * random.nextDouble();
      return StormSound(
        at,
        part: part,
        variant: variant,
        gain: math.pow(10, db / 20).toDouble(),
        speed: minSpeed + (maxSpeed - minSpeed) * random.nextDouble(),
        pan: (pan - partPanSpread + 2 * partPanSpread * random.nextDouble()).clamp(-maxPan, maxPan),
      );
    }

    bool has(StormPart p) => (parts[p] ?? const []).isNotEmpty;
    final steps = <StormStep>[];

    /// The strike at [at] (its flash [delay] before), the swells after it, an aftershock maybe.
    void strike(Duration flashAt, Duration delay, StormPart part, {required double aftershock, required StormRange aftershockAt}) {
      final at = flashAt + delay;
      steps
        ..add(StormFlash(flashAt, delay: delay, intensity: intensityFor(delay)))
        ..add(sound(at, part))
        ..add(StormSwell(
          at + averseStart.seconds(random),
          target: SwellTarget.averse,
          gainDb: averseGainDb.draw(random),
          rise: averseRise.seconds(random),
          hold: averseHold.seconds(random),
          fall: averseFall.seconds(random),
        ))
        ..add(StormSwell(
          at + gustStart.seconds(random),
          target: SwellTarget.rafale,
          gainDb: gustGainDb.draw(random),
          rise: gustRise.seconds(random),
          hold: gustHold.seconds(random),
          fall: gustFall.seconds(random),
        ));
      if (!has(StormPart.replique) || random.nextDouble() >= aftershock) return;
      final after = at + aftershockAt.seconds(random);
      if (random.nextDouble() < aftershockFlash) {
        final lead = aftershockFlashLead.seconds(random);
        var flash = after - lead;
        final earliest = flashAt + flashGap;
        if (flash < earliest) flash = earliest;
        if (flash < after) {
          steps.add(StormFlash(flash, delay: after - flash, intensity: aftershockIntensity.draw(random)));
        }
      }
      steps.add(sound(after, StormPart.replique));
    }

    switch (kind) {
      case StormKind.single:
        throw ArgumentError('a single event is drawn by singlePlan');
      case StormKind.lointain:
        if (random.nextDouble() < distantNoFlash) {
          steps.add(sound(Duration.zero, StormPart.lointain));
        } else {
          final delay = distantDelay.seconds(random);
          steps
            ..add(StormFlash(Duration.zero, delay: delay, intensity: distantIntensity.draw(random)))
            ..add(sound(delay, StormPart.lointain));
        }
      case StormKind.orage:
        var flashAt = Duration.zero;
        if (has(StormPart.avant)) {
          steps.add(sound(Duration.zero, StormPart.avant));
          flashAt = preRumbleToFlash.seconds(random);
        }
        strike(flashAt, stormDelay.seconds(random), StormPart.coup,
            aftershock: stormAftershock, aftershockAt: stormAftershockAt);
      case StormKind.proche:
        strike(Duration.zero, closeDelay.seconds(random), StormPart.coupProche,
            aftershock: 1.0, aftershockAt: closeAftershockAt);
    }
    return StormPlan(kind, steps);
  }
}
