// Light visual effects over the landscape (« Décor » tab of Mon mix).
// One Ticker drives every effect; particle positions are pure functions of time, so
// nothing is allocated per frame. Counts are capped; intensity = level / 100.
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../theme/vitre.dart';

/// Decor ids of the catalog.
const kDecorIds = [
  'brume',
  'rayons-soleil',
  'oiseaux-vol',
  'lucioles',
  'pluie-ecran',
  'feuilles',
  'neige',
  'etoiles',
  'eclairs',
];

/// One active effect.
@immutable
class DecorEffect {
  const DecorEffect(this.id, this.level);
  final String id;

  /// 0..100.
  final int level;

  double get intensity => (level / 100).clamp(0.0, 1.0);

  @override
  bool operator ==(Object other) => other is DecorEffect && other.id == id && other.level == level;

  @override
  int get hashCode => Object.hash(id, level);
}

/// Overlay drawing the active decor effects. Paused when [active] is false, when the
/// route is hidden (TickerMode) or when the app is in background. With reduced motion
/// it shows a faint static version (or nothing for moving-only effects).
class DecorLayer extends StatefulWidget {
  const DecorLayer({super.key, required this.effects, this.active = true});

  final List<DecorEffect> effects;
  final bool active;

  @override
  State<DecorLayer> createState() => _DecorLayerState();
}

class _DecorLayerState extends State<DecorLayer> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final Ticker _ticker = createTicker(_onTick);
  final ValueNotifier<double> _time = ValueNotifier<double>(0);
  Duration _last = Duration.zero;
  double _base = 0;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(DecorLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _sync();
  }

  bool get _reduced => Vitre.reduceMotion(context);

  void _sync() {
    final run = widget.active && _foreground && widget.effects.isNotEmpty && !_reduced;
    if (run && !_ticker.isActive) {
      _base = _time.value;
      _last = Duration.zero;
      _ticker.start();
    } else if (!run && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _onTick(Duration elapsed) {
    // ~30 updates per second are plenty for slow particles.
    if (elapsed - _last < const Duration(milliseconds: 32)) return;
    _last = elapsed;
    _time.value = _base + elapsed.inMicroseconds / 1e6;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _time.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.effects.isEmpty) return const SizedBox.shrink();
    return IgnorePointer(
      child: ExcludeSemantics(
        child: RepaintBoundary(
          child: CustomPaint(
            size: Size.infinite,
            painter: DecorPainter(effects: widget.effects, time: _time, still: _reduced),
          ),
        ),
      ),
    );
  }
}

class DecorPainter extends CustomPainter {
  DecorPainter({required this.effects, required ValueListenable<double> time, this.still = false})
      : _time = time,
        super(repaint: time);

  final List<DecorEffect> effects;
  final ValueListenable<double> _time;
  final bool still;

  @override
  void paint(Canvas canvas, Size size) {
    final t = still ? 0.0 : _time.value;
    for (final e in effects) {
      if (e.intensity <= 0) continue;
      final k = still ? 0.5 : 1.0;
      switch (e.id) {
        case 'brume':
          _mist(canvas, size, t, e.intensity * k);
        case 'rayons-soleil':
          _sunRays(canvas, size, t, e.intensity * k);
        case 'oiseaux-vol':
          if (!still) _birds(canvas, size, t, e.intensity);
        case 'lucioles':
          _fireflies(canvas, size, t, e.intensity * k);
        case 'pluie-ecran':
          _drops(canvas, size, t, e.intensity * k, still);
        case 'feuilles':
          _leaves(canvas, size, t, e.intensity * k);
        case 'neige':
          _snow(canvas, size, t, e.intensity * k);
        case 'etoiles':
          _twinkle(canvas, size, t, e.intensity * k, still);
        case 'eclairs':
          if (!still) _lightning(canvas, size, t, e.intensity);
      }
    }
  }

  @override
  bool shouldRepaint(DecorPainter old) => !_listEquals(old.effects, effects) || old.still != still;
}

bool _listEquals(List<DecorEffect> a, List<DecorEffect> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Stable pseudo-random value in 0..1 for particle [i] and channel [c].
double _r(int i, int c) {
  var x = (i * 73856093 ^ c * 19349663) & 0x7fffffff;
  x = ((x ^ (x >> 13)) * 1274126177) & 0x7fffffff;
  return ((x ^ (x >> 16)) & 0xffff) / 0xffff;
}

double _wrap(double v) => v - v.floorToDouble();

void _mist(Canvas canvas, Size size, double t, double k) {
  for (var i = 0; i < 4; i++) {
    final speed = 0.004 + _r(i, 1) * 0.006;
    final x = (_wrap(_r(i, 2) + t * speed) * 1.6 - 0.3) * size.width;
    final y = (0.35 + _r(i, 3) * 0.45) * size.height;
    final w = (0.9 + _r(i, 4)) * size.width;
    final h = (0.08 + _r(i, 5) * 0.08) * size.height;
    final rect = Rect.fromCenter(center: Offset(x, y), width: w, height: h);
    canvas.save();
    canvas.translate(rect.center.dx, rect.center.dy);
    canvas.scale(1, h / w);
    canvas.drawCircle(
      Offset.zero,
      w / 2,
      Paint()
        ..shader = ui.Gradient.radial(Offset.zero, w / 2, [
          Color.fromRGBO(225, 235, 232, 0.28 * k),
          Color.fromRGBO(225, 235, 232, 0),
        ]),
    );
    canvas.restore();
  }
}

void _sunRays(Canvas canvas, Size size, double t, double k) {
  final origin = Offset(size.width * 0.85, -size.height * 0.05);
  for (var i = 0; i < 5; i++) {
    final pulse = 0.6 + 0.4 * math.sin(t * (0.25 + _r(i, 1) * 0.2) + i * 1.7);
    final angle = 1.9 + (i - 2) * 0.13 + _r(i, 2) * 0.05;
    final len = size.height * 1.1;
    final end = origin + Offset(math.cos(angle), math.sin(angle)) * len;
    final perp = Offset(math.cos(angle + math.pi / 2), math.sin(angle + math.pi / 2));
    final width = size.width * (0.05 + _r(i, 3) * 0.06);
    final path = Path()
      ..moveTo(origin.dx, origin.dy)
      ..lineTo(end.dx + perp.dx * width, end.dy + perp.dy * width)
      ..lineTo(end.dx - perp.dx * width, end.dy - perp.dy * width)
      ..close();
    canvas.drawPath(
      path,
      Paint()
        ..blendMode = BlendMode.screen
        ..shader = ui.Gradient.linear(origin, end, [
          Color.fromRGBO(255, 240, 200, 0.22 * k * pulse),
          Color.fromRGBO(255, 240, 200, 0),
        ]),
    );
  }
}

void _birds(Canvas canvas, Size size, double t, double k) {
  final count = (2 + k * 4).round();
  final paint = Paint()
    ..color = Color.fromRGBO(12, 16, 14, 0.55 + 0.3 * k)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.6
    ..strokeCap = StrokeCap.round;
  for (var i = 0; i < count; i++) {
    final period = 26 + _r(i, 1) * 20;
    final phase = _wrap(t / period + _r(i, 2));
    final x = (-0.1 + phase * 1.2) * size.width;
    final y = (0.12 + _r(i, 3) * 0.25) * size.height + math.sin(phase * 9 + i) * 10;
    final s = 5 + _r(i, 4) * 5;
    final flap = math.sin(t * 7 + i * 2) * 0.6;
    final path = Path()
      ..moveTo(x - s, y - s * (0.3 + flap * 0.5))
      ..quadraticBezierTo(x - s * 0.4, y - s * 0.1, x, y)
      ..quadraticBezierTo(x + s * 0.4, y - s * 0.1, x + s, y - s * (0.3 + flap * 0.5));
    canvas.drawPath(path, paint);
  }
}

void _fireflies(Canvas canvas, Size size, double t, double k) {
  final count = (8 + k * 30).round();
  for (var i = 0; i < count; i++) {
    final x = (_r(i, 1) + math.sin(t * 0.13 + i) * 0.04) * size.width;
    final y = (0.4 + _r(i, 2) * 0.55 + math.cos(t * 0.11 + i * 1.3) * 0.03) * size.height;
    final blink = math.max(0.0, math.sin(t * (0.8 + _r(i, 3)) + i * 2.1));
    final a = blink * k;
    if (a < 0.02) continue;
    canvas.drawCircle(
      Offset(x, y),
      9,
      Paint()
        ..shader = ui.Gradient.radial(Offset(x, y), 9, [
          Color.fromRGBO(220, 255, 140, 0.5 * a),
          Color.fromRGBO(220, 255, 140, 0),
        ]),
    );
    canvas.drawCircle(Offset(x, y), 1.6, Paint()..color = Color.fromRGBO(250, 255, 210, 0.9 * a));
  }
}

void _drops(Canvas canvas, Size size, double t, double k, bool still) {
  final count = (10 + k * 30).round();
  for (var i = 0; i < count; i++) {
    final r = 2.5 + _r(i, 1) * 6;
    final slide = still ? 0.0 : _wrap(t / (14 + _r(i, 2) * 30) + _r(i, 3));
    // Most drops stay, some slide down quickly at the end of their cycle.
    final fall = slide > 0.85 ? (slide - 0.85) / 0.15 : 0.0;
    final x = _r(i, 4) * size.width;
    final y = (_r(i, 5) * 0.9 + fall * 0.5) * size.height;
    final c = Offset(x, y);
    final fade = 1 - fall;
    canvas.drawCircle(c, r, Paint()..color = Color.fromRGBO(200, 220, 230, 0.10 * k * fade));
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8
        ..color = Color.fromRGBO(255, 255, 255, 0.22 * k * fade),
    );
    canvas.drawCircle(c.translate(-r * 0.35, -r * 0.35), r * 0.25, Paint()..color = Color.fromRGBO(255, 255, 255, 0.5 * k * fade));
    if (fall > 0) {
      canvas.drawLine(
        c,
        c.translate(0, -fall * size.height * 0.2),
        Paint()
          ..strokeWidth = r * 0.5
          ..strokeCap = StrokeCap.round
          ..color = Color.fromRGBO(220, 235, 245, 0.08 * k),
      );
    }
  }
}

void _leaves(Canvas canvas, Size size, double t, double k) {
  final count = (5 + k * 15).round();
  const colors = [Color(0xFFB8762E), Color(0xFF9C5A22), Color(0xFFC9A03C), Color(0xFF7E8A2E)];
  for (var i = 0; i < count; i++) {
    final period = 16 + _r(i, 1) * 14;
    final phase = _wrap(t / period + _r(i, 2));
    final x = (_r(i, 3) + math.sin(phase * 6.28 * 2 + i) * 0.06) * size.width;
    final y = (-0.05 + phase * 1.1) * size.height;
    final s = 6 + _r(i, 4) * 6;
    canvas.save();
    canvas.translate(x, y);
    canvas.rotate(t * (0.6 + _r(i, 5)) + i);
    canvas.scale(1, 0.4 + 0.6 * math.cos(t * 1.3 + i).abs());
    final leaf = Path()
      ..moveTo(-s, 0)
      ..quadraticBezierTo(0, -s * 0.6, s, 0)
      ..quadraticBezierTo(0, s * 0.6, -s, 0);
    canvas.drawPath(leaf, Paint()..color = colors[i % colors.length].withValues(alpha: 0.75 * k + 0.1));
    canvas.restore();
  }
}

void _snow(Canvas canvas, Size size, double t, double k) {
  final count = (30 + k * 90).round();
  final pts = Float32List(count * 2);
  final bigPts = Float32List(count * 2);
  var big = 0;
  var small = 0;
  for (var i = 0; i < count; i++) {
    final period = 10 + _r(i, 1) * 14;
    final phase = _wrap(t / period + _r(i, 2));
    final x = (_r(i, 3) + math.sin(phase * 6.28 + i) * 0.03) * size.width;
    final y = (-0.02 + phase * 1.04) * size.height;
    if (_r(i, 4) > 0.75) {
      bigPts[big * 2] = x;
      bigPts[big * 2 + 1] = y;
      big++;
    } else {
      pts[small * 2] = x;
      pts[small * 2 + 1] = y;
      small++;
    }
  }
  canvas.drawRawPoints(
    ui.PointMode.points,
    Float32List.sublistView(pts, 0, small * 2),
    Paint()
      ..color = Color.fromRGBO(255, 255, 255, 0.55 * k + 0.1)
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round,
  );
  canvas.drawRawPoints(
    ui.PointMode.points,
    Float32List.sublistView(bigPts, 0, big * 2),
    Paint()
      ..color = Color.fromRGBO(255, 255, 255, 0.7 * k + 0.1)
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round,
  );
}

void _twinkle(Canvas canvas, Size size, double t, double k, bool still) {
  final count = (40 + k * 80).round();
  for (var i = 0; i < count; i++) {
    final x = _r(i, 1) * size.width;
    final y = math.pow(_r(i, 2), 1.5) * size.height * 0.55;
    final tw = still ? 0.7 : 0.5 + 0.5 * math.sin(t * (1 + _r(i, 3) * 2) + i * 3.1);
    final a = (0.25 + 0.6 * tw) * k;
    canvas.drawCircle(Offset(x, y.toDouble()), 0.6 + _r(i, 4) * 1.1, Paint()..color = Color.fromRGBO(255, 255, 255, a));
  }
}

void _lightning(Canvas canvas, Size size, double t, double k) {
  // A distant flash every ~10–24 s; soft, low alpha (no strobe).
  const period = 17.0;
  final cycle = t % period;
  final flash = cycle < 0.25 ? math.sin(cycle / 0.25 * math.pi) : (cycle > 0.4 && cycle < 0.55 ? 0.5 * math.sin((cycle - 0.4) / 0.15 * math.pi) : 0.0);
  if (flash <= 0) return;
  final center = Offset(size.width * (0.2 + _r((t / period).floor(), 1) * 0.6), size.height * 0.15);
  canvas.drawRect(
    Offset.zero & size,
    Paint()
      ..shader = ui.Gradient.radial(center, size.height * 0.7, [
        Color.fromRGBO(210, 220, 255, 0.16 * k * flash),
        Color.fromRGBO(210, 220, 255, 0),
      ]),
  );
}
