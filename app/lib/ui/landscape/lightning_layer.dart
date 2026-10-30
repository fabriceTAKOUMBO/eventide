// Lightning of a filmed storm (contract § 11 and § 12): a landscape with `eclairs: true` has
// no lightning in its video (removed by tools/media/process_video.py); the app draws it. It is
// not a decor the user chooses any more (a filmed landscape's decor cannot be changed).
//
// With a thunder in the mix, a flash for each strike announced by the audio service
// ([LightningLayer.lightningStrikes]), the thunder following 0.4 to 3.5 s later; without one,
// rare silent flashes (one every 2 to 5 min). A flash is bright but short: one main flash and
// one fainter re-flash, over in 0.6 s (never a strobe). With « réduire les animations », a soft
// glow only. One ticker, running only while a flash is drawn.
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../core/lightning.dart';
import '../theme/vitre.dart';

/// Overlay of the lightning flashes. Draws nothing unless [enabled] (a filmed storm), [active]
/// (not during a swipe), the route is shown (TickerMode) and the app is in the foreground.
class LightningLayer extends StatefulWidget {
  const LightningLayer({
    super.key,
    required this.enabled,
    this.active = true,
    this.lightningStrikes,
    this.thunderInMix = false,
    this.random,
  });

  /// The landscape is a filmed storm (`eclairs`) and is the one playing.
  final bool enabled;
  final bool active;

  /// Strikes announced just before each thunder (AppModel.lightningStrikes): a flash for each
  /// one while the layer is visible.
  final Stream<LightningStrike>? lightningStrikes;

  /// The mix has a thunder (a sound played by events above level 0): flashes with its strikes
  /// only; otherwise rare silent ones.
  final bool thunderInMix;

  /// Draws the silent flashes and the flash positions (tests).
  final math.Random? random;

  @override
  State<LightningLayer> createState() => _LightningLayerState();
}

/// A flash being drawn: started at [start] (layer time, s).
@immutable
class LightningFlash {
  const LightningFlash({required this.start, required this.intensity, required this.x, this.soft = false});

  final double start;

  /// 0..1 ([LightningStrike.intensity]).
  final double intensity;

  /// Horizontal position of the light in the sky, 0..1.
  final double x;

  /// Reduced motion: a soft glow instead of a flash.
  final bool soft;

  double get duration => soft ? lightningGlowDuration : lightningFlashDuration;

  /// Brightness 0..1 at layer time [t].
  double levelAt(double t) => soft ? lightningGlowLevel(t - start) : lightningFlashLevel(t - start);
}

/// Lengths of a flash and of the soft glow drawn instead with reduced motion (s).
const double lightningFlashDuration = 0.6;
const double lightningGlowDuration = 1.6;

/// Brightness 0..1 of a lightning flash [t] s after it starts: a sharp main flash (30 ms rise,
/// gone after ~0.25 s), one fainter re-flash at 0.3 s, nothing left after 0.6 s. Two flashes at
/// most: never a strobe (well under 3 flashes a second, the photosensitivity limit).
double lightningFlashLevel(double t) {
  if (t < 0 || t >= lightningFlashDuration) return 0;
  double pulse(double t0, double rise, double fall, double peak) {
    final u = t - t0;
    if (u < 0) return 0;
    if (u < rise) return peak * u / rise;
    return peak * math.exp(-(u - rise) / fall);
  }

  final v = math.max(pulse(0, 0.03, 0.06, 1.0), pulse(0.3, 0.03, 0.07, 0.55));
  return v * ((lightningFlashDuration - t) / 0.1).clamp(0.0, 1.0);
}

/// Reduced motion: a soft glow that rises and falls over 1.6 s, never above 0.35.
double lightningGlowLevel(double t) {
  if (t < 0 || t >= lightningGlowDuration) return 0;
  final s = math.sin(math.pi * t / lightningGlowDuration);
  return 0.35 * s * s;
}

class _LightningLayerState extends State<LightningLayer>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final Ticker _ticker = createTicker(_onTick);
  final ValueNotifier<double> _time = ValueNotifier<double>(0);
  double _base = 0;
  bool _foreground = true;
  late final math.Random _random = widget.random ?? math.Random();

  /// The flash being drawn, if any (read by the painter at each repaint).
  final ValueNotifier<LightningFlash?> _flash = ValueNotifier<LightningFlash?>(null);
  StreamSubscription<LightningStrike>? _strikes;
  Timer? _silent;

  /// A flash asked for: it starts at the next frame, so that it is drawn from its first instant.
  ({double intensity, double x})? _pending;

  /// The route is shown (no other screen over it: TickerMode).
  bool _routeShown = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _listen();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _routeShown = TickerMode.valuesOf(context).enabled;
    _sync();
  }

  @override
  void didUpdateWidget(LightningLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lightningStrikes != widget.lightningStrikes) _listen();
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _sync();
  }

  bool get _reduced => Vitre.reduceMotion(context);

  /// Shown now: a filmed storm, active, app in the foreground, route not hidden.
  bool get _visible => widget.enabled && widget.active && _foreground && _routeShown;

  void _listen() {
    _strikes?.cancel();
    _strikes = widget.lightningStrikes?.listen(_onStrike);
  }

  void _onStrike(LightningStrike strike) {
    if (!mounted || !_visible) return;
    _startFlash(strike.intensity);
  }

  void _startFlash(double intensity) {
    _pending = (intensity: intensity.clamp(0.0, 1.0), x: 0.2 + 0.6 * _random.nextDouble());
    _sync();
  }

  /// Rare silent flashes when the mix has no thunder (one every 2 to 5 min).
  void _armSilent() {
    final wanted = _visible && !widget.thunderInMix;
    if (!wanted) {
      _silent?.cancel();
      _silent = null;
      return;
    }
    _silent ??= Timer(StormRules.silentFlashGap(_random), () {
      _silent = null;
      if (!mounted) return;
      if (_visible && !widget.thunderInMix) {
        _startFlash(0.35 + 0.35 * _random.nextDouble());
      }
      _armSilent();
    });
  }

  void _sync() {
    if (!mounted) return;
    final flashing = _flash.value != null || _pending != null;
    final run = _visible && flashing;
    if (run && !_ticker.isActive) {
      _base = _time.value;
      _ticker.start();
    } else if (!run && _ticker.isActive) {
      _ticker.stop();
    }
    if (!_visible && flashing) {
      _pending = null;
      _flash.value = null;
    }
    _armSilent();
  }

  void _onTick(Duration elapsed) {
    _time.value = _base + elapsed.inMicroseconds / 1e6;
    final pending = _pending;
    if (pending != null) {
      _pending = null;
      _flash.value = LightningFlash(start: _time.value, intensity: pending.intensity, x: pending.x, soft: _reduced);
      return;
    }
    final flash = _flash.value;
    if (flash != null && _time.value - flash.start >= flash.duration) {
      _flash.value = null;
      _sync(); // the ticker only runs for a flash
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _strikes?.cancel();
    _silent?.cancel();
    _ticker.dispose();
    _time.dispose();
    _flash.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return const SizedBox.shrink();
    return IgnorePointer(
      child: ExcludeSemantics(
        child: RepaintBoundary(
          child: CustomPaint(
            size: Size.infinite,
            painter: LightningPainter(time: _time, flash: _flash),
          ),
        ),
      ),
    );
  }
}

class LightningPainter extends CustomPainter {
  LightningPainter({
    required ValueListenable<double> time,
    required ValueListenable<LightningFlash?> flash,
  }) : _time = time,
       _flash = flash,
       super(repaint: Listenable.merge([time, flash]));

  final ValueListenable<double> _time;
  final ValueListenable<LightningFlash?> _flash;

  /// Strength of the storm light (the former decor level, 50 %).
  static const double strength = 0.5;

  /// Brightness 0..1 of the flash drawn now (0 between flashes).
  double get flashLevel => _flash.value?.levelAt(_time.value) ?? 0;

  @override
  void paint(Canvas canvas, Size size) {
    final flash = _flash.value;
    if (flash == null) return;
    _lightning(canvas, size, flash, flash.levelAt(_time.value), strength);
  }

  @override
  bool shouldRepaint(LightningPainter oldDelegate) => false;
}

/// One lightning flash: light from a point of the sky ([LightningFlash.x], near the top),
/// brighter for a close strike, plus a light wash of the whole picture for the brightest ones.
/// With reduced motion ([LightningFlash.soft]) only the soft glow of the sky.
void _lightning(Canvas canvas, Size size, LightningFlash flash, double level, double k) {
  if (level <= 0) return;
  final strength = (0.25 + 0.45 * flash.intensity) * (0.6 + 0.4 * k) * level;
  final center = Offset(size.width * flash.x, size.height * 0.12);
  canvas.drawRect(
    Offset.zero & size,
    Paint()
      ..shader = ui.Gradient.radial(center, size.height * 0.9, [
        Color.fromRGBO(215, 225, 255, strength.clamp(0.0, 0.75)),
        const Color.fromRGBO(215, 225, 255, 0),
      ]),
  );
  if (!flash.soft && flash.intensity > 0.6) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = Color.fromRGBO(225, 232, 255, (0.22 * strength).clamp(0.0, 0.2)),
    );
  }
}
