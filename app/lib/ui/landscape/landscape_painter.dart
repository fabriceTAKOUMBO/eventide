// Procedural stand-ins for the licensed landscape photos (one composition per catalog
// `style`). Everything is deterministic: the same style always paints the same picture.
// Compositions are drawn in a portrait 390 × 844 frame and cropped like `object-fit: cover`.
//
// GPU budget (docs/app/architecture.md § 19, crash of 29 Oct 2026 on the Galaxy S24): these
// pictures are rasterised on the phone's GPU (Impeller/Vulkan), at full screen, for the
// neighbours, the menu thumbnail and the media card. Version 1 asked for up to 5,000 mask-filter
// blurs (each an offscreen pass) and 262 path clips (stencil passes) per picture; `lisiere` was
// the only one clipping to a 26-oval outline with 260 blurred dots and a blurred copy of that
// outline inside it. Since version 2: no clipPath at all (details are kept inside their shape by
// a point-in-shape test when recorded), no mask filter on dots, ovals, rectangles or strokes
// (soft radial or linear gradients instead), and at most [kMaxBlurredShapesPerLandscape] large
// blurred shapes per picture (merged when they were many). test/ui/landscape_budget_test.dart
// holds every style to that budget.
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// Reference frame of the mockup.
const Size kLandscapeFrame = Size(390, 844);

/// Version of the procedural pictures (2: GPU budget, see the top of this file). Part of the
/// media card file names, and of the crash guard (a style that died with an older painter is
/// tried again with this one).
const int kLandscapePainterVersion = 2;

/// Large mask-filter blurs a picture may ask for (distant woods, cliff, mist, waterfall).
const int kMaxBlurredShapesPerLandscape = 6;

/// Vertical focus used when a landscape is cropped to a wide box (thumbnails),
/// like the mockup's `object-position`.
double landscapeFocusY(String style) => switch (style) {
  'cascade' => 0.45,
  'sous-bois' => 0.35,
  'berge' => 0.6,
  'torrent' => 0.5,
  'pierres' => 0.6,
  'lisiere' => 0.5,
  'ville-pluie' => 0.5,
  'cafe' => 0.45,
  'toits' => 0.45,
  'etoiles' => 0.3,
  'aurore' => 0.35,
  'lune-lac' => 0.4,
  _ => 0.45,
};

class LandscapePainter extends CustomPainter {
  const LandscapePainter({required this.style});

  final String style;

  @override
  void paint(Canvas canvas, Size size) =>
      paintLandscapeCover(canvas, size, style);

  @override
  bool shouldRepaint(LandscapePainter oldDelegate) =>
      oldDelegate.style != style;
}

/// Paints the simplified picture of [style] (crash guard, docs/app/architecture.md § 19).
class SimplifiedLandscapePainter extends CustomPainter {
  const SimplifiedLandscapePainter({required this.style});

  final String style;

  @override
  void paint(Canvas canvas, Size size) =>
      paintSimplifiedLandscape(canvas, size, style);

  @override
  bool shouldRepaint(SimplifiedLandscapePainter oldDelegate) =>
      oldDelegate.style != style;
}

/// Colours of the simplified pictures: the sky-to-ground gradient of each composition and the
/// place and colour of its light.
typedef _Simple = ({List<int> colors, List<double> stops, int light, double lx, double ly});

const Map<String, _Simple> _simplified = {
  'cascade': (colors: [0xFF2C4A40, 0xFF1A3229, 0xFF5F8A80, 0xFF24453E, 0xFF0A1511], stops: [0, 0.3, 0.66, 0.75, 1], light: 0xFFDCEFE2, lx: 0.55, ly: 0.06),
  'sous-bois': (colors: [0xFFB9C48A, 0xFF889A5A, 0xFF4D6034, 0xFF243019, 0xFF141B0E], stops: [0, 0.25, 0.5, 0.75, 1], light: 0xFFFFF1C2, lx: 0.66, ly: 0.2),
  'berge': (colors: [0xFF3D5A44, 0xFF233A2B, 0xFF4C6D66, 0xFF1B3330, 0xFF122019], stops: [0, 0.3, 0.55, 0.8, 1], light: 0xFFCFE5D2, lx: 0.4, ly: 0.05),
  'torrent': (colors: [0xFF8EA4B6, 0xFFB8C6CC, 0xFF3E5263, 0xFF1F3127, 0xFF2C5559], stops: [0, 0.22, 0.4, 0.6, 1], light: 0xFFF2F6F6, lx: 0.5, ly: 0.4),
  'pierres': (colors: [0xFF4E6A5E, 0xFF2C473F, 0xFF15271F], stops: [0, 0.5, 1], light: 0xFFE4F2EE, lx: 0.5, ly: 0.2),
  'lisiere': (colors: [0xFF6E93B5, 0xFF9DB9CC, 0xFFDCE2CF, 0xFF27442D, 0xFF8FA65A, 0xFF22381A], stops: [0, 0.3, 0.45, 0.49, 0.53, 1], light: 0xFFFFE8B0, lx: 0.85, ly: 0.45),
  'ville-pluie': (colors: [0xFF161B2C, 0xFF262B42, 0xFF3C3346, 0xFF0E111A, 0xFF0B0C12], stops: [0, 0.45, 0.62, 0.72, 1], light: 0xFFB0705A, lx: 0.5, ly: 0.62),
  'cafe': (colors: [0xFF1E140E, 0xFF2A3346, 0xFF2E1F15, 0xFF5A3A22, 0xFF120B06], stops: [0, 0.3, 0.62, 0.76, 1], light: 0xFFFFA650, lx: 0.5, ly: 0.1),
  'toits': (colors: [0xFF333D52, 0xFF56627A, 0xFF8A8E98, 0xFF4C586A, 0xFF1A1F27], stops: [0, 0.3, 0.45, 0.7, 1], light: 0xFFE7B88A, lx: 0.25, ly: 0.42),
  'etoiles': (colors: [0xFF03060F, 0xFF0A1428, 0xFF1A2742, 0xFF2C3352, 0xFF03050A], stops: [0, 0.45, 0.72, 0.84, 0.9], light: 0xFF52618A, lx: 0.3, ly: 0.86),
  'aurore': (colors: [0xFF030812, 0xFF07172A, 0xFF0C2638, 0xFF0F2A34, 0xFF02060A], stops: [0, 0.4, 0.62, 0.7, 1], light: 0xFF2AD08A, lx: 0.5, ly: 0.38),
  'lune-lac': (colors: [0xFF070E1C, 0xFF12203A, 0xFF22344F, 0xFF1F3048, 0xFF060C16], stops: [0, 0.38, 0.56, 0.6, 1], light: 0xFFBFD0F0, lx: 0.62, ly: 0.2),
};

/// A picture of [style] made of three gradients only (no path, no blur, no clip): shown instead
/// of the full composition for a style whose drawing was interrupted by a crash.
void paintSimplifiedLandscape(Canvas canvas, Size size, String style) {
  final p = _simplified[style] ?? _simplified['cascade']!;
  final rect = Offset.zero & size;
  if (rect.isEmpty) return;
  canvas.drawRect(
    rect,
    Paint()
      ..shader = ui.Gradient.linear(
        rect.topCenter,
        rect.bottomCenter,
        [for (final c in p.colors) Color(c)],
        p.stops,
      ),
  );
  final light = Color(p.light);
  final centre = Offset(size.width * p.lx, size.height * p.ly);
  canvas.drawRect(
    rect,
    Paint()
      ..shader = ui.Gradient.radial(centre, size.longestSide * 0.55, [
        _a(light, 0.35),
        _a(light, 0),
      ]),
  );
  canvas.drawRect(
    rect,
    Paint()
      ..shader = ui.Gradient.radial(
        Offset(size.width / 2, size.height * 0.45),
        size.longestSide * 0.62,
        const [Color(0x00000000), Color(0x00000000), Color(0x8C000000)],
        const [0, 0.55, 1],
      ),
  );
}

/// Paints [style] so that it covers [size], cropping around [landscapeFocusY].
void paintLandscapeCover(Canvas canvas, Size size, String style) {
  final scale = math.max(
    size.width / kLandscapeFrame.width,
    size.height / kLandscapeFrame.height,
  );
  final vw = kLandscapeFrame.width * scale;
  final vh = kLandscapeFrame.height * scale;
  final dx = (size.width - vw) / 2;
  final dy = (size.height - vh) * landscapeFocusY(style);
  canvas.save();
  canvas.clipRect(Offset.zero & size);
  canvas.translate(dx, dy);
  paintLandscapeScene(canvas, Size(vw, vh), style);
  canvas.restore();
}

/// Paints the portrait composition of [style] into [size] (aspect ≈ 390:844).
void paintLandscapeScene(Canvas canvas, Size size, String style) {
  final k = _K(canvas, size, style);
  switch (style) {
    case 'cascade':
      _cascade(k);
    case 'sous-bois':
      _sousBois(k);
    case 'berge':
      _berge(k);
    case 'torrent':
      _torrent(k);
    case 'pierres':
      _pierres(k);
    case 'lisiere':
      _lisiere(k);
    case 'ville-pluie':
      _villePluie(k);
    case 'cafe':
      _cafe(k);
    case 'toits':
      _toits(k);
    case 'etoiles':
      _etoiles(k);
    case 'aurore':
      _aurore(k);
    case 'lune-lac':
      _luneLac(k);
    default:
      _cascade(k);
  }
  k.grain();
  k.vignette();
}

// ---------------------------------------------------------------------------
// Toolkit

/// mulberry32: small, fast, good enough for decoration.
class _Rng {
  _Rng(int seed) : _s = seed & 0xffffffff;
  int _s;

  double next() {
    _s = (_s + 0x6D2B79F5) & 0xffffffff;
    var t = _s;
    t = ((t ^ (t >> 15)) * (t | 1)) & 0xffffffff;
    t = (t ^ (t + (((t ^ (t >> 7)) * (t | 61)) & 0xffffffff))) & 0xffffffff;
    return ((t ^ (t >> 14)) & 0xffffffff) / 4294967296.0;
  }

  double range(double a, double b) => a + (b - a) * next();
  bool chance(double p) => next() < p;
}

int _hashString(String s) {
  var h = 2166136261;
  for (final c in s.codeUnits) {
    h = ((h ^ c) * 16777619) & 0x7fffffff;
  }
  return h;
}

double _hash1(int i, int seed) {
  var x = (i * 374761393 + seed * 668265263) & 0xffffffff;
  x = ((x ^ (x >> 13)) * 1274126177) & 0xffffffff;
  return ((x ^ (x >> 16)) & 0xffff) / 0xffff;
}

double _vnoise(double x, int seed) {
  final i = x.floor();
  final f = x - i;
  final u = f * f * (3 - 2 * f);
  return _hash1(i, seed) * (1 - u) + _hash1(i + 1, seed) * u;
}

/// Fractal noise in 0..1.
double _fbm(double x, int seed, [int octaves = 4]) {
  var sum = 0.0, amp = 0.5, freq = 1.0, norm = 0.0;
  for (var o = 0; o < octaves; o++) {
    sum += _vnoise(x * freq, seed + o * 101) * amp;
    norm += amp;
    amp *= 0.5;
    freq *= 2.1;
  }
  return sum / norm;
}

Color _c(int argb) => Color(argb);

/// Linear gradient with evenly spaced stops when none are given.
ui.Gradient _linear(
  Offset from,
  Offset to,
  List<Color> colors, [
  List<double>? stops,
]) {
  final st =
      stops ??
      [for (var i = 0; i < colors.length; i++) i / (colors.length - 1)];
  return ui.Gradient.linear(from, to, colors, st);
}

/// Point in polygon (even-odd), for details that must stay inside a shape without a GPU clip.
bool _inside(List<Offset> polygon, Offset p) {
  var inside = false;
  for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
    final a = polygon[i], b = polygon[j];
    if ((a.dy > p.dy) != (b.dy > p.dy) &&
        p.dx < (b.dx - a.dx) * (p.dy - a.dy) / (b.dy - a.dy) + a.dx) {
      inside = !inside;
    }
  }
  return inside;
}

Color _a(Color c, double alpha) =>
    c.withValues(alpha: (c.a * alpha).clamp(0.0, 1.0));
Color _mix(Color a, Color b, double t) => Color.lerp(a, b, t)!;

class _K {
  _K(this.canvas, this.size, String style)
    : w = size.width,
      h = size.height,
      s = size.width / kLandscapeFrame.width,
      seed = _hashString(style),
      rng = _Rng(_hashString(style));

  final Canvas canvas;
  final Size size;
  final double w, h, s;
  final int seed;
  final _Rng rng;

  Offset p(double x, double y) => Offset(x * w, y * h);
  Rect get full => Offset.zero & size;

  void vertical(List<Color> colors, List<double> stops, {Rect? rect}) {
    final r = rect ?? full;
    canvas.drawRect(
      r,
      Paint()..shader = _linear(r.topCenter, r.bottomCenter, colors, stops),
    );
  }

  void glow(
    Offset c,
    double radius,
    Color color, {
    double falloff = 1,
    BlendMode blend = BlendMode.srcOver,
  }) {
    canvas.drawCircle(
      c,
      radius,
      Paint()
        ..blendMode = blend
        ..shader = ui.Gradient.radial(
          c,
          radius,
          [color, _a(color, 0.45 * falloff), _a(color, 0)],
          [0, 0.4, 1],
        ),
    );
  }

  void ellipseGlow(Rect r, Color color, {BlendMode blend = BlendMode.srcOver}) {
    canvas.save();
    canvas.translate(r.center.dx, r.center.dy);
    canvas.scale(1, r.height / r.width);
    final rad = r.width / 2;
    canvas.drawCircle(
      Offset.zero,
      rad,
      Paint()
        ..blendMode = blend
        ..shader = ui.Gradient.radial(
          Offset.zero,
          rad,
          [color, _a(color, 0.4), _a(color, 0)],
          [0, 0.5, 1],
        ),
    );
    canvas.restore();
  }

  /// Plain fill. Never a mask filter: a blurred draw is an offscreen pass on the GPU. Soft dots,
  /// ovals and bands use [softCircle], [softOval] and [softRect]; the few large soft shapes use
  /// [blurredFill].
  Paint fill(Color c, {BlendMode blend = BlendMode.srcOver}) => Paint()
    ..color = c
    ..blendMode = blend;

  /// A large soft shape (distant woods, cliff, mist): the only mask-filter blur left, at most
  /// [kMaxBlurredShapesPerLandscape] per picture, never inside a clip.
  Paint blurredFill(Color c, double blur, {BlendMode blend = BlendMode.srcOver}) =>
      fill(c, blend: blend)..maskFilter = MaskFilter.blur(BlurStyle.normal, blur * s);

  /// Stroke. [blur] no longer blurs (no mask filter): the line is drawn a little wider and
  /// lighter instead, which is what a slight blur of a thin line looks like.
  Paint stroke(
    Color c,
    double width, {
    double blur = 0,
    BlendMode blend = BlendMode.srcOver,
  }) {
    final spread = blur * 0.8;
    return Paint()
      ..color = spread > 0 ? _a(c, width / (width + spread)) : c
      ..style = PaintingStyle.stroke
      ..strokeWidth = (width + spread) * s
      ..strokeCap = StrokeCap.round
      ..blendMode = blend;
  }

  /// A disc softened by [blur] (in frame units), as one radial gradient: half opacity at its
  /// edge, like a Gaussian blur, without any offscreen pass.
  void softCircle(Offset c, double radius, Color color, double blur) {
    final b = blur * s;
    if (radius <= 0) return;
    if (b <= 0) {
      canvas.drawCircle(c, radius, fill(color));
      return;
    }
    final outer = radius + 2 * b;
    canvas.drawCircle(
      c,
      outer,
      Paint()
        ..shader = ui.Gradient.radial(
          c,
          outer,
          [color, color, _a(color, 0.5), _a(color, 0)],
          [0, math.max(0.0, radius - b) / outer, radius / outer, 1],
        ),
    );
  }

  /// An oval softened by [blur] (contact shadows), as a stretched radial gradient.
  void softOval(Rect r, Color color, double blur) {
    final rx = r.width / 2, ry = r.height / 2;
    if (rx <= 0 || ry <= 0) return;
    canvas.save();
    canvas.translate(r.center.dx, r.center.dy);
    canvas.scale(1, ry / rx);
    softCircle(Offset.zero, rx, color, blur);
    canvas.restore();
  }

  /// A vertical band softened on its sides by [blur] (light streaks, reflections).
  void softRect(Rect r, Color color, double blur) {
    final b = blur * s;
    final o = Rect.fromLTRB(r.left - 2 * b, r.top, r.right + 2 * b, r.bottom);
    if (o.width <= 0 || o.height <= 0) return;
    final edge = 2 * b / o.width;
    final full = math.min(3 * b / o.width, 0.5);
    canvas.drawRect(
      o,
      Paint()
        ..shader = _linear(
          o.centerLeft,
          o.centerRight,
          [_a(color, 0), _a(color, 0.5), color, color, _a(color, 0.5), _a(color, 0)],
          [0, edge, full, 1 - full, 1 - edge, 1],
        ),
    );
  }

  /// Noisy horizon filled down to the bottom of the frame.
  Path ridge(
    double baseY,
    double amp,
    double freq,
    int sd, {
    int octaves = 5,
    double step = 3,
    double? bottom,
  }) {
    final path = Path()..moveTo(0, bottom ?? h);
    for (var x = 0.0; x <= w + step; x += step * s) {
      final n = _fbm(x / w * freq, sd, octaves);
      path.lineTo(x, baseY * h - n * amp * h);
    }
    path
      ..lineTo(w, bottom ?? h)
      ..close();
    return path;
  }

  /// Band of conifers standing on [baseY].
  Path conifers(
    double baseY,
    double minH,
    double maxH,
    double spacing,
    int sd, {
    double x0 = -0.05,
    double x1 = 1.05,
  }) {
    final r = _Rng(sd);
    final path = Path();
    var x = x0;
    while (x < x1) {
      final ht = r.range(minH, maxH) * h;
      final base = baseY * h + r.range(-0.006, 0.006) * h;
      _conifer(path, x * w, base, ht, r);
      x += spacing * r.range(0.45, 1.25);
    }
    return path;
  }

  void _conifer(Path path, double cx, double base, double ht, _Rng r) {
    final tiers = 9 + (ht / h * 40).round().clamp(0, 10);
    final halfMax = ht * r.range(0.2, 0.28);
    final right = <Offset>[];
    for (var i = 1; i <= tiers; i++) {
      final t = i / tiers;
      final y = base - ht + ht * t;
      final wTier = halfMax * math.pow(t, 0.85) * r.range(0.8, 1.15);
      right.add(Offset(cx + wTier, y));
      right.add(Offset(cx + wTier * r.range(0.25, 0.5), y - ht / tiers * 0.25));
    }
    path.moveTo(cx, base - ht);
    for (final pt in right) {
      path.lineTo(pt.dx, pt.dy);
    }
    path.lineTo(cx + halfMax * 0.12, base + 2 * s);
    path.lineTo(cx - halfMax * 0.12, base + 2 * s);
    for (final pt in right.reversed) {
      path.lineTo(2 * cx - pt.dx + r.range(-1, 1) * s, pt.dy);
    }
    path.close();
  }

  /// Rounded canopy band (deciduous woods) along [baseY].
  Path canopy(
    double baseY,
    double amp,
    double minR,
    double maxR,
    int sd, {
    double density = 1,
    double bottom = 1.0,
  }) {
    final r = _Rng(sd);
    final path = Path()
      ..moveTo(0, bottom * h)
      ..lineTo(0, baseY * h)
      ..lineTo(w, baseY * h)
      ..lineTo(w, bottom * h)
      ..close();
    var x = -0.05;
    while (x < 1.05) {
      final rad = r.range(minR, maxR) * w;
      final y =
          baseY * h - _fbm(x * 3, sd, 3) * amp * h + r.range(-0.3, 0.3) * rad;
      path.addOval(Rect.fromCircle(center: Offset(x * w, y), radius: rad));
      x += (rad / w) * r.range(0.6, 1.1) / density;
    }
    return path;
  }

  /// Irregular rock with light from the top left and optional moss cap. No clip: the texture
  /// and the moss dots are kept inside the outline by [_inside], the moss gradient is filled
  /// through the outline itself.
  void rock(
    Offset c,
    double rx,
    double ry,
    Color base, {
    Color? moss,
    double mossAmount = 0.35,
    int sd = 0,
    double light = 1,
  }) {
    final r = _Rng(seed + sd * 7919);
    final path = Path();
    final outline = <Offset>[];
    const n = 28;
    for (var i = 0; i <= n; i++) {
      final a = i / n * math.pi * 2;
      final wobble = 1 + (_vnoise(i * 0.7 + sd, seed) - 0.5) * 0.28;
      var y = math.sin(a) * ry * wobble;
      if (y > ry * 0.55) y = ry * 0.55 + (y - ry * 0.55) * 0.3; // flatter base
      final pt = Offset(c.dx + math.cos(a) * rx * wobble, c.dy + y);
      outline.add(pt);
      if (i == 0) {
        path.moveTo(pt.dx, pt.dy);
      } else {
        path.lineTo(pt.dx, pt.dy);
      }
    }
    path.close();
    // Contact shadow.
    softOval(
      Rect.fromCenter(
        center: c.translate(rx * 0.1, ry * 0.55),
        width: rx * 2.3,
        height: ry * 0.7,
      ),
      const Color(0x8C000000),
      6,
    );
    final hi = _mix(base, const Color(0xFFFFFFFF), 0.22 * light);
    final lo = _mix(base, const Color(0xFF000000), 0.6);
    canvas.drawPath(
      path,
      Paint()
        ..shader = ui.Gradient.radial(
          c.translate(-rx * 0.45, -ry * 0.55),
          math.max(rx, ry) * 2.1,
          [hi, base, lo],
          [0, 0.45, 1],
        ),
    );
    // Surface texture: fewer dots on small stones (pebbles of `pierres` are many).
    final dots = (rx / s / 4).clamp(4, 18).round();
    for (var i = 0; i < 18; i++) {
      final o = c.translate(r.range(-rx, rx), r.range(-ry, ry));
      final radius = r.range(0.05, 0.22) * rx;
      final color = _a(r.chance(0.5) ? hi : lo, 0.18);
      if (i >= dots || !_inside(outline, o)) continue;
      softCircle(o, radius, color, 2);
    }
    if (moss != null) {
      // Moss grows on the lit top and fades downwards, with a soft irregular edge.
      final top = c.dy - ry * 1.1;
      final depth = ry * 2 * mossAmount;
      canvas.drawPath(
        path,
        Paint()
          ..shader = _linear(
            Offset(c.dx, top),
            Offset(c.dx, top + depth * 1.3),
            [_a(moss, 0.85), _a(moss, 0.55), _a(moss, 0)],
            const [0, 0.55, 1],
          ),
      );
      for (var i = 0; i < 40; i++) {
        final o = Offset(
          c.dx + r.range(-rx, rx),
          top + r.range(0, depth * 1.2),
        );
        final radius = r.range(0.8, 3.2) * s;
        final color = _a(
          _mix(
            moss,
            r.chance(0.5) ? const Color(0xFFE6F2A0) : const Color(0xFF0E1A0A),
            r.range(0.1, 0.5),
          ),
          0.45,
        );
        if (!_inside(outline, o)) continue;
        canvas.drawCircle(o, radius, fill(color));
      }
      canvas.drawPath(path, stroke(_a(const Color(0xFF000000), 0.18), 1.2));
    }
  }

  /// Fern or grass tuft made of curved strokes.
  void tuft(
    Offset base,
    double height,
    Color color,
    int blades, {
    double spread = 0.6,
    double width = 1.4,
    int sd = 0,
  }) {
    final r = _Rng(seed + sd * 31 + 5);
    for (var i = 0; i < blades; i++) {
      final ang = -math.pi / 2 + r.range(-spread, spread);
      final len = height * r.range(0.55, 1.0);
      final tip = base + Offset(math.cos(ang) * len, math.sin(ang) * len);
      final ctrl =
          base +
          Offset(
            math.cos(ang) * len * 0.5 + r.range(-0.2, 0.2) * len,
            math.sin(ang) * len * 0.6,
          );
      final path = Path()
        ..moveTo(base.dx, base.dy)
        ..quadraticBezierTo(ctrl.dx, ctrl.dy, tip.dx, tip.dy);
      canvas.drawPath(
        path,
        stroke(_a(color, r.range(0.6, 1)), width * r.range(0.6, 1.3)),
      );
    }
  }

  /// Fern frond: a curved rachis with leaflets.
  void fern(Offset base, double len, double angle, Color color, {int sd = 0}) {
    final r = _Rng(seed + sd * 53 + 11);
    final paint = stroke(color, 1.1);
    final path = Path()..moveTo(base.dx, base.dy);
    const steps = 16;
    var pt = base;
    var a = angle;
    for (var i = 1; i <= steps; i++) {
      final t = i / steps;
      a += 0.035;
      final next = pt + Offset(math.cos(a), math.sin(a)) * (len / steps);
      path.lineTo(next.dx, next.dy);
      final leaf = len * 0.22 * (1 - t) + 3 * s;
      for (final side in const [-1.0, 1.0]) {
        final la = a + side * (1.0 + r.range(-0.15, 0.15));
        final tip = next + Offset(math.cos(la), math.sin(la)) * leaf;
        canvas.drawLine(
          next,
          tip,
          paint..strokeWidth = (2.2 * (1 - t) + 0.6) * s,
        );
      }
      pt = next;
    }
    canvas.drawPath(path, stroke(color, 1.2)..style = PaintingStyle.stroke);
  }

  /// Short horizontal glints on water.
  void glints(
    Rect band,
    int count,
    Color color, {
    double minLen = 4,
    double maxLen = 40,
    double maxAlpha = 0.25,
    int sd = 0,
  }) {
    final r = _Rng(seed + 977 + sd);
    for (var i = 0; i < count; i++) {
      final y = band.top + band.height * math.pow(r.next(), 0.8);
      final x = band.left + band.width * r.next();
      final depth = (y - band.top) / band.height;
      final len = (minLen + (maxLen - minLen) * r.next()) * s * (0.5 + depth);
      canvas.drawLine(
        Offset(x, y),
        Offset(x + len, y),
        stroke(
          _a(color, r.range(0.2, 1) * maxAlpha),
          r.range(0.6, 1.6) * (0.6 + depth),
        ),
      );
    }
  }

  /// Star field; [bandAngle] concentrates stars along a milky-way band when set.
  void stars(
    Rect area,
    int count, {
    double maxR = 1.3,
    int sd = 0,
    double brightness = 1,
  }) {
    final r = _Rng(seed + 4049 + sd);
    final pts = Float32List(count * 2);
    for (var i = 0; i < count; i++) {
      pts[i * 2] = area.left + area.width * r.next();
      pts[i * 2 + 1] = area.top + area.height * math.pow(r.next(), 1.3);
    }
    canvas.drawRawPoints(
      ui.PointMode.points,
      pts,
      Paint()
        ..color = _a(const Color(0xFFFFFFFF), 0.55 * brightness)
        ..strokeWidth = 1.1 * s
        ..strokeCap = StrokeCap.round,
    );
    for (var i = 0; i < count ~/ 25; i++) {
      final c = Offset(
        area.left + area.width * r.next(),
        area.top + area.height * math.pow(r.next(), 1.4),
      );
      final rad = r.range(0.6, maxR) * s;
      final tint = r.chance(0.3)
          ? const Color(0xFFFFE2C2)
          : (r.chance(0.4) ? const Color(0xFFCADBFF) : const Color(0xFFFFFFFF));
      glow(c, rad * 5, _a(tint, 0.25 * brightness));
      canvas.drawCircle(c, rad, fill(_a(tint, 0.95 * brightness)));
    }
  }

  void rain(
    int count, {
    double alpha = 0.14,
    double angle = 0.18,
    int sd = 0,
    Rect? area,
  }) {
    final r = _Rng(seed + 1531 + sd);
    final a = area ?? full;
    for (var i = 0; i < count; i++) {
      final x = a.left + a.width * r.next();
      final y = a.top + a.height * r.next();
      final len = r.range(10, 34) * s;
      canvas.drawLine(
        Offset(x, y),
        Offset(x - len * angle, y + len),
        stroke(
          _a(const Color(0xFFDDE8F5), r.range(0.3, 1) * alpha),
          r.range(0.5, 1.1),
        ),
      );
    }
  }

  /// Fine photographic grain.
  void grain() {
    final r = _Rng(seed + 99991);
    final count = (w * h / 70).round().clamp(300, 40000);
    final light = Float32List(count * 2);
    final dark = Float32List(count * 2);
    for (var i = 0; i < count; i++) {
      light[i * 2] = r.next() * w;
      light[i * 2 + 1] = r.next() * h;
      dark[i * 2] = r.next() * w;
      dark[i * 2 + 1] = r.next() * h;
    }
    final paint = Paint()
      ..strokeWidth = math.max(0.8, s)
      ..color = const Color(0x0DFFFFFF);
    canvas.drawRawPoints(ui.PointMode.points, light, paint);
    canvas.drawRawPoints(
      ui.PointMode.points,
      dark,
      paint..color = const Color(0x14000000),
    );
  }

  void vignette({double strength = 0.55}) {
    final c = Offset(w / 2, h * 0.45);
    final rad = math.sqrt(w * w + h * h) * 0.62;
    canvas.drawRect(
      full,
      Paint()
        ..shader = ui.Gradient.radial(
          c,
          rad,
          [
            const Color(0x00000000),
            const Color(0x00000000),
            _a(const Color(0xFF000000), strength),
          ],
          [0, 0.55, 1],
        ),
    );
  }

  /// Soft horizontal haze band.
  void haze(double y, double height, Color color) {
    final r = Rect.fromLTWH(
      -w * 0.2,
      (y - height / 2) * h,
      w * 1.4,
      height * h,
    );
    canvas.drawRect(
      r,
      Paint()
        ..shader = _linear(
          r.topCenter,
          r.bottomCenter,
          [_a(color, 0), color, _a(color, 0)],
          const [0, 0.5, 1],
        ),
    );
  }

  /// Light shafts from [origin] spreading downwards: one shape, one gradient, one blur.
  void rays(
    Offset origin,
    int count,
    double length,
    Color color, {
    double spread = 0.9,
    double baseAngle = 1.9,
    int sd = 0,
  }) {
    final r = _Rng(seed + 313 + sd);
    final shafts = Path();
    var alpha = 0.0;
    for (var i = 0; i < count; i++) {
      final a = baseAngle + r.range(-spread / 2, spread / 2);
      final wid = r.range(0.03, 0.09);
      final end = origin + Offset(math.cos(a), math.sin(a)) * length * h;
      final left =
          end +
          Offset(math.cos(a + math.pi / 2), math.sin(a + math.pi / 2)) *
              wid *
              w *
              2;
      final right =
          end -
          Offset(math.cos(a + math.pi / 2), math.sin(a + math.pi / 2)) *
              wid *
              w *
              2;
      shafts
        ..moveTo(origin.dx, origin.dy)
        ..lineTo(left.dx, left.dy)
        ..lineTo(right.dx, right.dy)
        ..close();
      alpha += r.range(0.5, 1) / count;
    }
    canvas.drawPath(
      shafts,
      // Opaque paint colour: its alpha would otherwise dim the gradient a second time.
      blurredFill(const Color(0xFF000000), 10, blend: BlendMode.screen)
        ..shader = ui.Gradient.radial(origin, length * h, [
          _a(color, alpha),
          _a(color, 0),
        ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Nature

void _cascade(_K k) {
  final c = k.canvas;
  k.vertical(
    [_c(0xFF2C4A40), _c(0xFF1A3229), _c(0xFF10221B), _c(0xFF0A1511)],
    const [0, 0.3, 0.62, 1],
  );
  // Sky through the canopy.
  k.glow(k.p(0.55, 0.06), 0.55 * k.w, _a(_c(0xFFDCEFE2), 0.55));
  // Far misty woods.
  c.drawPath(
    k.canopy(0.3, 0.08, 0.05, 0.1, k.seed + 1),
    k.blurredFill(_a(_c(0xFF6E8F80), 0.75), 7),
  );
  k.haze(0.3, 0.12, _a(_c(0xFFBFD8CB), 0.35));
  c.drawPath(
    k.canopy(0.38, 0.1, 0.06, 0.12, k.seed + 2),
    k.blurredFill(_a(_c(0xFF3F5E50), 0.92), 4),
  );
  // Cliff behind the fall.
  // Rock walls on both sides of the fall, rising out of the mist, with soft edges.
  final cliffOutline = <Offset>[Offset(0.05 * k.w, 0.66 * k.h)];
  for (var y = 0.66; y >= -0.02; y -= 0.01) {
    final n = _fbm(y * 9, k.seed + 31, 4);
    cliffOutline.add(
      Offset((0.1 + (0.66 - y) * 0.26 + (n - 0.5) * 0.1) * k.w, y * k.h),
    );
  }
  for (var y = -0.02; y <= 0.66; y += 0.01) {
    final n = _fbm(y * 9, k.seed + 37, 4);
    cliffOutline.add(
      Offset((0.9 - (0.66 - y) * 0.26 + (n - 0.5) * 0.1) * k.w, y * k.h),
    );
  }
  cliffOutline.add(Offset(0.95 * k.w, 0.66 * k.h));
  final cliff = Path()..addPolygon(cliffOutline, true);
  c.drawPath(
    cliff,
    Paint()
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 3 * k.s)
      ..shader = _linear(k.p(0.3, 0.12), k.p(0.6, 0.66), [
        _c(0xFF34433A),
        _c(0xFF1E2923),
        _c(0xFF111A15),
      ]),
  );
  final r = _Rng(k.seed + 5);
  // Ledges and cracks, kept on the cliff (no clip).
  for (var i = 0; i < 70; i++) {
    final y = r.range(0.14, 0.66);
    final x = r.range(0.15, 0.85);
    final len = r.range(0.02, 0.08);
    final from = k.p(x, y), to = k.p(x + len, y + r.range(-0.006, 0.01));
    final paint = k.stroke(
      _a(
        r.chance(0.6) ? _c(0xFF070C09) : _c(0xFF6F8A6A),
        r.range(0.15, 0.45),
      ),
      r.range(1, 3),
      blur: 0.8,
    );
    if (!_inside(cliffOutline, from) || !_inside(cliffOutline, to)) continue;
    c.drawLine(from, to, paint);
  }
  for (var i = 0; i < 90; i++) {
    final o = k.p(r.range(0.12, 0.88), r.range(0.14, 0.66));
    final radius = r.range(2, 7) * k.s;
    final color = _a(_c(0xFF4C7A3A), r.range(0.15, 0.45));
    if (!_inside(cliffOutline, o)) continue;
    k.softCircle(o, radius, color, 2);
  }
  k.haze(0.2, 0.12, _a(_c(0xFFCFE3D8), 0.25));
  // Waterfall: soft core then streaks.
  final fallTop = 0.15 * k.h, fallBottom = 0.665 * k.h;
  final core = Path()
    ..moveTo(0.44 * k.w, fallTop)
    ..lineTo(0.565 * k.w, fallTop)
    ..cubicTo(
      0.6 * k.w,
      0.4 * k.h,
      0.63 * k.w,
      0.55 * k.h,
      0.66 * k.w,
      fallBottom,
    )
    ..lineTo(0.36 * k.w, fallBottom)
    ..cubicTo(
      0.39 * k.w,
      0.55 * k.h,
      0.41 * k.w,
      0.4 * k.h,
      0.44 * k.w,
      fallTop,
    )
    ..close();
  c.drawPath(
    core,
    Paint()
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 4 * k.s)
      ..shader = _linear(Offset(0, fallTop), Offset(0, fallBottom), [
        _a(_c(0xFFDDEDE6), 0.55),
        _a(_c(0xFFF2FAF6), 0.78),
        _a(_c(0xFFFFFFFF), 0.9),
      ]),
  );
  for (var i = 0; i < 160; i++) {
    final t = r.next();
    final topX = 0.44 + t * 0.125;
    final botX = 0.36 + t * 0.3 + r.range(-0.01, 0.01);
    final y0 = fallTop + r.range(0, 0.05) * k.h;
    final path = Path()
      ..moveTo(topX * k.w, y0)
      ..quadraticBezierTo(
        ((topX + botX) / 2 + r.range(-0.01, 0.01)) * k.w,
        0.45 * k.h,
        botX * k.w,
        fallBottom - r.range(0, 0.04) * k.h,
      );
    c.drawPath(
      path,
      k.stroke(
        _a(_c(0xFFFFFFFF), r.range(0.08, 0.4)),
        r.range(0.5, 2.2),
        blur: r.chance(0.5) ? 1.2 : 0,
      ),
    );
  }
  // Mist at the base.
  k.ellipseGlow(
    Rect.fromCenter(
      center: k.p(0.51, 0.665),
      width: 0.95 * k.w,
      height: 0.12 * k.h,
    ),
    _a(_c(0xFFEFF7F3), 0.75),
  );
  k.ellipseGlow(
    Rect.fromCenter(
      center: k.p(0.5, 0.63),
      width: 0.6 * k.w,
      height: 0.1 * k.h,
    ),
    _a(_c(0xFFFFFFFF), 0.5),
  );
  // Pool.
  final pool = Rect.fromLTRB(0, 0.665 * k.h, k.w, 0.86 * k.h);
  c.drawRect(
    pool,
    Paint()
      ..shader = _linear(
        pool.topCenter,
        pool.bottomCenter,
        [_c(0xFF5F8A80), _c(0xFF24453E), _c(0xFF0F221E)],
        const [0, 0.35, 1],
      ),
  );
  k.softRect(
    Rect.fromLTRB(0.34 * k.w, pool.top, 0.68 * k.w, pool.bottom),
    _a(_c(0xFFE7F3EE), 0.18),
    14,
  );
  k.glints(pool, 260, _c(0xFFF4FFFA), maxAlpha: 0.32, maxLen: 34);
  // Foreground boulders and ferns framing the pool.
  k.rock(
    k.p(0.12, 0.8),
    0.24 * k.w,
    0.07 * k.h,
    _c(0xFF2A332C),
    moss: _c(0xFF5C8A40),
    mossAmount: 0.5,
    sd: 1,
  );
  k.rock(
    k.p(0.86, 0.78),
    0.22 * k.w,
    0.065 * k.h,
    _c(0xFF2C352F),
    moss: _c(0xFF587F3B),
    mossAmount: 0.45,
    sd: 2,
  );
  k.rock(
    k.p(0.5, 0.93),
    0.4 * k.w,
    0.09 * k.h,
    _c(0xFF1C241F),
    moss: _c(0xFF3F6A30),
    mossAmount: 0.4,
    sd: 3,
    light: 0.7,
  );
  k.rock(
    k.p(0.04, 0.98),
    0.25 * k.w,
    0.08 * k.h,
    _c(0xFF161D19),
    moss: _c(0xFF35592A),
    sd: 4,
    light: 0.5,
  );
  k.rock(
    k.p(0.98, 0.96),
    0.25 * k.w,
    0.08 * k.h,
    _c(0xFF161D19),
    moss: _c(0xFF35592A),
    sd: 5,
    light: 0.5,
  );
  for (var i = 0; i < 7; i++) {
    final left = i.isEven;
    k.fern(
      k.p(left ? r.range(0, 0.2) : r.range(0.8, 1), r.range(0.86, 1.0)),
      r.range(0.12, 0.2) * k.w,
      left ? -0.9 - r.range(0, 0.6) : -2.2 + r.range(0, 0.6),
      _a(_c(0xFF4C7A39), 0.9),
      sd: i,
    );
  }
  // Framing trunks and leaves.
  c.drawPath(
    Path()
      ..moveTo(0, 0)
      ..lineTo(0.08 * k.w, 0)
      ..cubicTo(
        0.07 * k.w,
        0.3 * k.h,
        0.09 * k.w,
        0.5 * k.h,
        0.06 * k.w,
        0.75 * k.h,
      )
      ..lineTo(0, 0.76 * k.h)
      ..close(),
    k.fill(_c(0xFF0B1410)),
  );
  c.drawPath(
    k.canopy(0.04, 0.03, 0.05, 0.1, k.seed + 9, bottom: 0),
    k.blurredFill(_a(_c(0xFF0F1D16), 0.8), 10),
  );
  k.haze(0.5, 0.25, _a(_c(0xFFCFE3D8), 0.08));
}

void _sousBois(_K k) {
  final c = k.canvas;
  k.vertical(
    [
      _c(0xFFB9C48A),
      _c(0xFF889A5A),
      _c(0xFF4D6034),
      _c(0xFF243019),
      _c(0xFF141B0E),
    ],
    const [0, 0.25, 0.5, 0.75, 1],
  );
  final sun = k.p(0.66, 0.2);
  k.glow(sun, 0.7 * k.w, _a(_c(0xFFFFF1C2), 0.9));
  k.glow(sun, 0.18 * k.w, _a(_c(0xFFFFFCEB), 0.95));
  final r = _Rng(k.seed + 3);
  // Trunks in depth layers: far are pale and thin, near are dark and wide.
  const layers = [
    (
      count: 14,
      minW: 0.008,
      maxW: 0.018,
      color: 0xFF9AA67C,
      ground: 0.66,
      blur: 3.0,
    ),
    (
      count: 10,
      minW: 0.016,
      maxW: 0.03,
      color: 0xFF5F6C45,
      ground: 0.7,
      blur: 1.5,
    ),
    (
      count: 6,
      minW: 0.03,
      maxW: 0.055,
      color: 0xFF2F3A22,
      ground: 0.76,
      blur: 0.0,
    ),
    (
      count: 3,
      minW: 0.07,
      maxW: 0.12,
      color: 0xFF141A0E,
      ground: 0.9,
      blur: 0.0,
    ),
  ];
  for (var li = 0; li < layers.length; li++) {
    final l = layers[li];
    // Far trunks are soft: one shape and one blur per layer, not one per trunk.
    final soft = Path();
    for (var i = 0; i < l.count; i++) {
      final x = li == 3
          ? [0.06, 0.88, 0.32][i] + r.range(-0.03, 0.03)
          : r.range(-0.02, 1.02);
      final wid = r.range(l.minW, l.maxW) * k.w;
      final lean = r.range(-0.02, 0.02) * k.w;
      final ground = (l.ground + r.range(-0.02, 0.02)) * k.h;
      final trunk = Path()
        ..moveTo(x * k.w - wid * 0.4 + lean, -10)
        ..lineTo(x * k.w + wid * 0.4 + lean, -10)
        ..lineTo(x * k.w + wid * 0.6, ground)
        ..quadraticBezierTo(
          x * k.w + wid * 1.1,
          ground + wid * 0.4,
          x * k.w + wid * 1.4,
          ground + wid * 0.5,
        )
        ..lineTo(x * k.w - wid * 1.4, ground + wid * 0.5)
        ..quadraticBezierTo(
          x * k.w - wid * 1.1,
          ground + wid * 0.4,
          x * k.w - wid * 0.6,
          ground,
        )
        ..close();
      if (l.blur > 0) {
        soft.addPath(trunk, Offset.zero);
      } else {
        c.drawPath(trunk, k.fill(_c(l.color)));
      }
      if (li >= 2) {
        // Bark light on the sun side.
        c.drawLine(
          Offset(x * k.w + wid * 0.25, 0),
          Offset(x * k.w + wid * 0.35, ground),
          k.stroke(
            _a(_c(0xFFE8D9A0), li == 3 ? 0.12 : 0.22),
            wid / k.s * 0.18,
            blur: 2,
          ),
        );
      }
    }
    if (l.blur > 0) c.drawPath(soft, k.blurredFill(_c(l.color), l.blur));
    if (li == 0) k.haze(0.55, 0.3, _a(_c(0xFFE6E7C0), 0.35));
    if (li == 1) {
      k.rays(
        sun,
        7,
        0.95,
        _a(_c(0xFFFFF4C8), 0.35),
        baseAngle: 1.95,
        spread: 1.0,
      );
    }
  }
  // Forest floor.
  final floor = Path()
    ..addPath(k.ridge(0.74, 0.04, 2, k.seed + 11), Offset.zero);
  c.drawPath(
    floor,
    Paint()
      ..shader = _linear(k.p(0, 0.7), k.p(0, 1), [
        _c(0xFF4C4A24),
        _c(0xFF2A2A15),
        _c(0xFF12140A),
      ]),
  );
  for (var i = 0; i < 40; i++) {
    final o = k.p(r.range(0, 1), r.range(0.75, 0.97));
    k.ellipseGlow(
      Rect.fromCenter(
        center: o,
        width: r.range(0.04, 0.14) * k.w,
        height: r.range(0.006, 0.016) * k.h,
      ),
      _a(_c(0xFFFFE7A3), r.range(0.15, 0.4)),
    );
  }
  for (var i = 0; i < 26; i++) {
    k.tuft(
      k.p(r.range(-0.05, 1.05), r.range(0.76, 1.02)),
      r.range(0.03, 0.08) * k.h,
      _mix(_c(0xFF4E6B2A), _c(0xFF9DB45A), r.next()),
      14,
      sd: i,
      width: 1.6,
    );
  }
  // Foliage at the top with sun dapples.
  c.drawPath(
    k.canopy(0.04, 0.03, 0.05, 0.11, k.seed + 21, bottom: 0),
    k.blurredFill(_a(_c(0xFF2F4220), 0.9), 3),
  );
  for (var i = 0; i < 30; i++) {
    k.glow(
      k.p(r.range(0, 1), r.range(0, 0.12)),
      r.range(4, 14) * k.s,
      _a(_c(0xFFF7F0B8), 0.5),
    );
  }
}

void _berge(_K k) {
  final c = k.canvas;
  k.vertical(
    [_c(0xFF3D5A44), _c(0xFF233A2B), _c(0xFF122019)],
    const [0, 0.45, 1],
  );
  k.glow(k.p(0.4, 0.05), 0.6 * k.w, _a(_c(0xFFCFE5D2), 0.5));
  // Dense foliage backdrop.
  c.drawPath(
    k.canopy(0.2, 0.06, 0.06, 0.12, k.seed + 1),
    k.blurredFill(_a(_c(0xFF4B6E4E), 0.8), 6),
  );
  c.drawPath(
    k.canopy(0.3, 0.06, 0.05, 0.1, k.seed + 2),
    k.blurredFill(_a(_c(0xFF2C4A33), 0.95), 3),
  );
  k.haze(0.32, 0.1, _a(_c(0xFFBFD6C2), 0.2));
  // Stream flowing towards the viewer.
  final stream = Path()
    ..moveTo(0.58 * k.w, 0.36 * k.h)
    ..cubicTo(
      0.66 * k.w,
      0.42 * k.h,
      0.78 * k.w,
      0.5 * k.h,
      0.7 * k.w,
      0.62 * k.h,
    )
    ..cubicTo(
      0.62 * k.w,
      0.74 * k.h,
      0.82 * k.w,
      0.86 * k.h,
      1.1 * k.w,
      1.02 * k.h,
    )
    ..lineTo(-0.1 * k.w, 1.02 * k.h)
    ..cubicTo(
      0.12 * k.w,
      0.86 * k.h,
      0.36 * k.w,
      0.72 * k.h,
      0.44 * k.w,
      0.6 * k.h,
    )
    ..cubicTo(
      0.5 * k.w,
      0.5 * k.h,
      0.52 * k.w,
      0.42 * k.h,
      0.58 * k.w,
      0.36 * k.h,
    )
    ..close();
  c.drawPath(
    stream,
    Paint()
      ..shader = _linear(
        k.p(0.6, 0.36),
        k.p(0.5, 1),
        [_c(0xFF9DB8AE), _c(0xFF4C6D66), _c(0xFF1B3330)],
        const [0, 0.4, 1],
      ),
  );
  // Ripples, kept on the water (no clip).
  final r = _Rng(k.seed + 7);
  for (var i = 0; i < 220; i++) {
    final y = r.range(0.38, 1.0);
    final x = r.range(0.1, 0.9);
    final len = r.range(0.02, 0.09) * (0.5 + y);
    final from = k.p(x, y), to = k.p(x + len * 0.35, y + len * 0.25);
    final paint = k.stroke(_a(_c(0xFFEAF6F1), r.range(0.05, 0.3)), r.range(0.5, 1.8));
    if (!stream.contains(from) || !stream.contains(to)) continue;
    c.drawLine(from, to, paint);
  }
  // Stones in the water with foam.
  for (final st in const [
    (0.5, 0.66, 0.06),
    (0.62, 0.78, 0.05),
    (0.38, 0.86, 0.08),
    (0.7, 0.92, 0.07),
  ]) {
    k.ellipseGlow(
      Rect.fromCenter(
        center: k.p(st.$1, st.$2 + 0.012),
        width: st.$3 * 3 * k.w,
        height: 0.03 * k.h,
      ),
      _a(_c(0xFFFFFFFF), 0.5),
    );
    k.rock(
      k.p(st.$1, st.$2),
      st.$3 * k.w,
      st.$3 * 0.6 * k.w,
      _c(0xFF3A443C),
      moss: _c(0xFF6E9A45),
      sd: (st.$1 * 100).round(),
    );
  }
  // Mossy banks.
  final left = Path()
    ..moveTo(0, 0.42 * k.h)
    ..cubicTo(
      0.25 * k.w,
      0.4 * k.h,
      0.42 * k.w,
      0.5 * k.h,
      0.4 * k.w,
      0.62 * k.h,
    )
    ..cubicTo(0.34 * k.w, 0.74 * k.h, 0.14 * k.w, 0.84 * k.h, 0, 0.9 * k.h)
    ..close();
  final right = Path()
    ..moveTo(k.w, 0.4 * k.h)
    ..cubicTo(
      0.86 * k.w,
      0.4 * k.h,
      0.74 * k.w,
      0.44 * k.h,
      0.8 * k.w,
      0.56 * k.h,
    )
    ..cubicTo(0.86 * k.w, 0.66 * k.h, 0.9 * k.w, 0.72 * k.h, k.w, 0.78 * k.h)
    ..close();
  for (final bank in [left, right]) {
    final b = bank.getBounds();
    c.drawPath(
      bank,
      Paint()
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 2.5 * k.s)
        ..shader = _linear(b.topCenter, b.bottomCenter, [
          _c(0xFF6E8F44),
          _c(0xFF3C6326),
          _c(0xFF15270F),
        ]),
    );
    // Moss cushions: many overlapping soft mounds with light tops, kept on the bank (no clip).
    for (var i = 0; i < 70; i++) {
      final o = Offset(
        b.left + r.next() * b.width,
        b.top + r.next() * b.height,
      );
      final rad = r.range(6, 22) * k.s;
      if (!bank.contains(o)) continue;
      c.drawCircle(
        o,
        rad,
        Paint()
          ..shader = ui.Gradient.radial(
            o.translate(-rad * 0.3, -rad * 0.45),
            rad * 1.3,
            [
              _a(_c(0xFFA6C76A), 0.55),
              _a(_c(0xFF3E6A27), 0.35),
              _a(_c(0xFF14260D), 0),
            ],
            const [0, 0.5, 1],
          ),
      );
    }
    for (var i = 0; i < 320; i++) {
      final o = Offset(
        b.left + r.next() * b.width,
        b.top + r.next() * b.height,
      );
      final radius = r.range(0.6, 2.2) * k.s;
      final color = _a(
        r.chance(0.5) ? _c(0xFFC9E07A) : _c(0xFF0F1F0A),
        r.range(0.15, 0.45),
      );
      if (!bank.contains(o)) continue;
      c.drawCircle(o, radius, k.fill(color));
    }
    // Shade where the bank meets the water.
    c.drawPath(bank, k.stroke(_a(_c(0xFF050B05), 0.5), 6, blur: 5));
  }
  for (var i = 0; i < 6; i++) {
    final onLeft = i < 3;
    k.fern(
      k.p(onLeft ? r.range(0.0, 0.25) : r.range(0.8, 1.0), r.range(0.45, 0.6)),
      r.range(0.12, 0.2) * k.w,
      onLeft ? -0.6 - r.range(0, 0.5) : -2.5 + r.range(0, 0.5),
      _a(_c(0xFF7FA84A), 0.85),
      sd: 10 + i,
    );
  }
  k.haze(0.6, 0.3, _a(_c(0xFFD6E6DA), 0.06));
}

void _torrent(_K k) {
  final c = k.canvas;
  k.vertical(
    [_c(0xFF8EA4B6), _c(0xFFB8C6CC), _c(0xFFD3DAD6)],
    const [0, 0.22, 0.36],
  );
  // Far ranges with snow.
  final far = k.ridge(0.3, 0.14, 2.2, k.seed + 1, bottom: 0.6 * k.h);
  c.drawPath(far, k.fill(_c(0xFF7187A0)));
  // Snow on the far ranges, kept on them (no clip).
  final r = _Rng(k.seed + 2);
  for (var i = 0; i < 60; i++) {
    final x = r.next();
    final top = 0.3 - _fbm(x * 2.2, k.seed + 1, 5) * 0.14;
    final from = k.p(x, top + 0.003);
    final to = k.p(x + r.range(-0.02, 0.02), top + r.range(0.008, 0.035));
    final paint = k.stroke(
      _a(_c(0xFFF1F5F8), r.range(0.25, 0.6)),
      r.range(1, 3),
      blur: 1.2,
    );
    if (!far.contains(from) || !far.contains(to)) continue;
    c.drawLine(from, to, paint);
  }
  k.haze(0.36, 0.08, _a(_c(0xFFDCE4E6), 0.55));
  c.drawPath(k.ridge(0.4, 0.1, 2.8, k.seed + 3), k.fill(_c(0xFF3E5263)));
  k.haze(0.42, 0.05, _a(_c(0xFFCBD6D8), 0.35));
  // Pine slopes converging to the valley.
  final leftSlope = Path()
    ..moveTo(0, 0.36 * k.h)
    ..lineTo(0.45 * k.w, 0.47 * k.h)
    ..lineTo(0.45 * k.w, k.h)
    ..lineTo(0, k.h)
    ..close();
  final rightSlope = Path()
    ..moveTo(k.w, 0.34 * k.h)
    ..lineTo(0.56 * k.w, 0.47 * k.h)
    ..lineTo(0.56 * k.w, k.h)
    ..lineTo(k.w, k.h)
    ..close();
  for (final slope in [leftSlope, rightSlope]) {
    c.drawPath(slope, k.fill(_c(0xFF1F3127)));
  }
  for (var row = 0; row < 7; row++) {
    final y = 0.4 + row * 0.022;
    final hgt = 0.03 + row * 0.012;
    c.drawPath(
      k.conifers(
        y + 0.02,
        hgt * 0.7,
        hgt,
        0.022 + row * 0.006,
        k.seed + 20 + row,
        x1: 0.44 - row * 0.02,
      ),
      k.fill(_mix(_c(0xFF2F4A3B), _c(0xFF0F1C15), row / 7)),
    );
    c.drawPath(
      k.conifers(
        y + 0.015,
        hgt * 0.7,
        hgt,
        0.022 + row * 0.006,
        k.seed + 40 + row,
        x0: 0.58 + row * 0.02,
      ),
      k.fill(_mix(_c(0xFF2F4A3B), _c(0xFF0F1C15), row / 7)),
    );
  }
  // Torrent.
  final water = Path()
    ..moveTo(0.47 * k.w, 0.47 * k.h)
    ..lineTo(0.54 * k.w, 0.47 * k.h)
    ..cubicTo(0.62 * k.w, 0.6 * k.h, 0.78 * k.w, 0.78 * k.h, 0.95 * k.w, k.h)
    ..lineTo(0.05 * k.w, k.h)
    ..cubicTo(
      0.25 * k.w,
      0.8 * k.h,
      0.4 * k.w,
      0.6 * k.h,
      0.47 * k.w,
      0.47 * k.h,
    )
    ..close();
  c.drawPath(
    water,
    Paint()
      ..shader = _linear(k.p(0.5, 0.47), k.p(0.5, 1), [
        _c(0xFFA9C9CC),
        _c(0xFF5E8F92),
        _c(0xFF2C5559),
      ]),
  );
  // Foam streaks, kept on the water (no clip).
  for (var i = 0; i < 360; i++) {
    final y = r.range(0.47, 1.0);
    final x = 0.5 + (r.next() - 0.5) * (0.1 + (y - 0.47) * 1.6);
    final len = 0.01 + (y - 0.47) * 0.08;
    final from = k.p(x, y), to = k.p(x + r.range(-0.01, 0.01), y + len);
    final paint = k.stroke(
      _a(_c(0xFFFFFFFF), r.range(0.15, 0.7)),
      r.range(0.6, 2.4) * (0.4 + y),
      blur: r.chance(0.3) ? 1.5 : 0,
    );
    if (!water.contains(from) || !water.contains(to)) continue;
    c.drawLine(from, to, paint);
  }
  // Boulders.
  for (final b in const [
    (0.3, 0.74, 0.07),
    (0.62, 0.7, 0.05),
    (0.52, 0.85, 0.08),
    (0.78, 0.88, 0.06),
    (0.2, 0.92, 0.09),
  ]) {
    k.ellipseGlow(
      Rect.fromCenter(
        center: k.p(b.$1, b.$2 - 0.01),
        width: b.$3 * 3.4 * k.w,
        height: 0.03 * k.h,
      ),
      _a(_c(0xFFFFFFFF), 0.6),
    );
    k.rock(
      k.p(b.$1, b.$2),
      b.$3 * k.w,
      b.$3 * 0.7 * k.w,
      _c(0xFF6A6F6C),
      sd: (b.$2 * 100).round(),
      light: 1.1,
    );
  }
  k.rock(k.p(0.02, 0.96), 0.22 * k.w, 0.08 * k.h, _c(0xFF3E4442), sd: 91);
  k.rock(k.p(1.0, 0.94), 0.2 * k.w, 0.08 * k.h, _c(0xFF3A403E), sd: 92);
  k.haze(0.48, 0.06, _a(_c(0xFFF2F6F6), 0.25));
}

void _pierres(_K k) {
  final c = k.canvas;
  k.vertical(
    [_c(0xFF4E6A5E), _c(0xFF2C473F), _c(0xFF15271F)],
    const [0, 0.5, 1],
  );
  final r = _Rng(k.seed + 1);
  const palette = [
    0xFF7A6F5B,
    0xFF5B5547,
    0xFF8E8269,
    0xFF46433A,
    0xFF6C665A,
    0xFF9C8F74,
    0xFF55524A,
  ];
  // Riverbed pebbles, larger towards the viewer.
  for (var i = 0; i < 260; i++) {
    final y = r.range(-0.02, 1.05);
    final size = (0.025 + y * 0.075) * r.range(0.6, 1.3);
    final x = r.range(-0.05, 1.05);
    k.rock(
      k.p(x, y),
      size * k.w,
      size * k.w * r.range(0.55, 0.8),
      _c(palette[r.next() * palette.length ~/ 1]),
      sd: 200 + i,
      light: 0.9,
    );
  }
  // Water over the stones: tint, depth and caustics.
  c.drawRect(
    k.full,
    Paint()
      ..shader = _linear(k.p(0, 0), k.p(0, 1), [
        _a(_c(0xFF2E5A55), 0.6),
        _a(_c(0xFF2C5550), 0.32),
        _a(_c(0xFF1F403A), 0.2),
      ]),
  );
  for (var i = 0; i < 220; i++) {
    final o = k.p(r.next(), r.next());
    final rad = r.range(6, 22) * k.s;
    final path = Path()
      ..addArc(
        Rect.fromCircle(center: o, radius: rad),
        r.range(0, 6.28),
        r.range(0.8, 2.2),
      );
    c.drawPath(
      path,
      k.stroke(
        _a(_c(0xFFDFFFF4), r.range(0.05, 0.18)),
        r.range(0.6, 1.6),
        blur: 0.6,
      ),
    );
  }
  // Surface reflections of the sky.
  for (var i = 0; i < 9; i++) {
    final o = k.p(r.next(), r.range(0, 0.7));
    k.ellipseGlow(
      Rect.fromCenter(
        center: o,
        width: r.range(0.2, 0.5) * k.w,
        height: r.range(0.01, 0.025) * k.h,
      ),
      _a(_c(0xFFE4F2EE), 0.22),
    );
  }
  k.glints(k.full, 160, _c(0xFFFFFFFF), maxAlpha: 0.22, maxLen: 26);
  // Dry stones emerging on the left with moss.
  k.rock(
    k.p(0.05, 0.3),
    0.2 * k.w,
    0.06 * k.h,
    _c(0xFF77705E),
    moss: _c(0xFF6E8E3E),
    mossAmount: 0.3,
    sd: 3,
    light: 1.2,
  );
  k.rock(
    k.p(0.9, 0.62),
    0.16 * k.w,
    0.05 * k.h,
    _c(0xFF6F6858),
    moss: _c(0xFF5E8038),
    mossAmount: 0.25,
    sd: 4,
    light: 1.2,
  );
}

void _lisiere(_K k) {
  final c = k.canvas;
  k.vertical(
    [_c(0xFF6E93B5), _c(0xFF9DB9CC), _c(0xFFDCE2CF)],
    const [0, 0.3, 0.48],
  );
  final r = _Rng(k.seed + 1);
  for (var i = 0; i < 14; i++) {
    final o = k.p(r.range(-0.1, 1.1), r.range(0.05, 0.32));
    k.ellipseGlow(
      Rect.fromCenter(
        center: o,
        width: r.range(0.25, 0.6) * k.w,
        height: r.range(0.03, 0.06) * k.h,
      ),
      _a(_c(0xFFFFFFFF), r.range(0.25, 0.5)),
    );
  }
  k.glow(k.p(0.85, 0.45), 0.5 * k.w, _a(_c(0xFFFFE8B0), 0.6));
  // Distant hills and the wood edge.
  c.drawPath(k.ridge(0.47, 0.03, 2, k.seed + 2), k.fill(_c(0xFF6F8C78)));
  c.drawPath(
    k.canopy(0.47, 0.05, 0.035, 0.07, k.seed + 3),
    k.fill(_c(0xFF27442D)),
  );
  for (var i = 0; i < 50; i++) {
    final o = k.p(r.range(0, 1), r.range(0.4, 0.47));
    k.softCircle(o, r.range(3, 9) * k.s, _a(_c(0xFF5D7F45), 0.45), 2);
  }
  // Big tree on the left.
  c.drawPath(
    Path()
      ..moveTo(0.06 * k.w, 0.52 * k.h)
      ..lineTo(0.1 * k.w, 0.3 * k.h)
      ..lineTo(0.14 * k.w, 0.3 * k.h)
      ..lineTo(0.16 * k.w, 0.53 * k.h)
      ..close(),
    k.fill(_c(0xFF1B2416)),
  );
  // Crown: 26 overlapping discs. Version 1 clipped to this outline and drew 260 blurred dots
  // and a blurred copy of it inside (the picture that crashed on the Galaxy S24, § 19 of the
  // architecture document): now a plain shape, and the dots are kept in it by a disc test.
  final crown = Path();
  final discs = <(Offset, double)>[];
  for (var i = 0; i < 26; i++) {
    final disc = (
      k.p(r.range(-0.12, 0.34), r.range(0.1, 0.34)),
      r.range(0.06, 0.12) * k.w,
    );
    discs.add(disc);
    crown.addOval(Rect.fromCircle(center: disc.$1, radius: disc.$2));
  }
  c.drawPath(crown, k.fill(_c(0xFF1E3220)));
  bool inCrown(Offset o) => discs.any((d) => (o - d.$1).distance <= d.$2);
  for (var i = 0; i < 260; i++) {
    final o = k.p(r.range(-0.12, 0.36), r.range(0.04, 0.36));
    final radius = r.range(1.5, 5) * k.s;
    final color = _a(
      r.chance(0.55) ? _c(0xFF6E8F4E) : _c(0xFF0C170C),
      r.range(0.2, 0.55),
    );
    if (!inCrown(o)) continue;
    c.drawCircle(o, radius, k.fill(color));
  }
  // Meadow.
  final meadow = k.ridge(0.5, 0.01, 1.5, k.seed + 4);
  c.drawPath(
    meadow,
    Paint()
      ..shader = _linear(k.p(0, 0.49), k.p(0, 1), [
        _c(0xFF8FA65A),
        _c(0xFF5D7D35),
        _c(0xFF22381A),
      ]),
  );
  for (var i = 0; i < 9; i++) {
    final y = 0.52 + i * 0.05;
    k.haze(y, 0.02, _a(_c(0xFFC8D88A), 0.08));
  }
  for (var i = 0; i < 70; i++) {
    final y = r.range(0.72, 1.04);
    k.tuft(
      k.p(r.range(-0.05, 1.05), y),
      (0.03 + (y - 0.7) * 0.25) * k.h,
      _mix(_c(0xFF39561F), _c(0xFFB5C76A), r.next() * 0.7),
      9,
      sd: i,
      spread: 0.4,
      width: 1.2,
    );
  }
  for (var i = 0; i < 50; i++) {
    final o = k.p(r.range(0, 1), r.range(0.6, 0.98));
    c.drawCircle(
      o,
      r.range(1, 2.4) * k.s,
      k.fill(_a(r.chance(0.6) ? _c(0xFFFFFFFF) : _c(0xFFF4D35E), 0.8)),
    );
  }
}

// ---------------------------------------------------------------------------
// Urban

void _windows(
  _K k,
  Rect building,
  double cell,
  double litRatio,
  _Rng r, {
  double alpha = 1,
}) {
  for (
    var y = building.top + cell * 0.8;
    y < building.bottom - cell;
    y += cell * 1.4
  ) {
    for (
      var x = building.left + cell * 0.5;
      x < building.right - cell;
      x += cell * 1.2
    ) {
      if (!r.chance(litRatio)) continue;
      final warm = r.chance(0.75);
      final col = warm ? _c(0xFFFFC77A) : _c(0xFFA9CCFF);
      final win = Rect.fromLTWH(x, y, cell * 0.7, cell * 0.9);
      k.canvas.drawRect(win, k.fill(_a(col, r.range(0.35, 0.95) * alpha)));
      if (r.chance(0.3)) k.glow(win.center, cell * 2, _a(col, 0.18 * alpha));
    }
  }
}

void _villePluie(_K k) {
  final c = k.canvas;
  k.vertical(
    [_c(0xFF161B2C), _c(0xFF262B42), _c(0xFF3C3346)],
    const [0, 0.45, 0.62],
  );
  k.glow(k.p(0.5, 0.62), 0.9 * k.w, _a(_c(0xFFB0705A), 0.35));
  final r = _Rng(k.seed + 1);
  // Far skyline.
  var x = -0.02;
  while (x < 1.02) {
    final bw = r.range(0.06, 0.14);
    final top = r.range(0.32, 0.5);
    final rect = Rect.fromLTRB(x * k.w, top * k.h, (x + bw) * k.w, 0.66 * k.h);
    c.drawRect(rect, k.fill(_c(0xFF232838)));
    _windows(k, rect, 5 * k.s, 0.25, r, alpha: 0.6);
    x += bw + r.range(0.0, 0.02);
  }
  k.haze(0.56, 0.16, _a(_c(0xFF8C7A86), 0.25));
  // Near buildings.
  x = -0.05;
  while (x < 1.05) {
    final bw = r.range(0.16, 0.3);
    final top = r.range(0.18, 0.4);
    final rect = Rect.fromLTRB(x * k.w, top * k.h, (x + bw) * k.w, 0.72 * k.h);
    c.drawRect(rect, k.fill(_c(0xFF0E111A)));
    c.drawRect(
      Rect.fromLTWH(rect.left, rect.top, rect.width, 3 * k.s),
      k.fill(_a(_c(0xFF6B7088), 0.35)),
    );
    _windows(k, rect, 9 * k.s, 0.35, r);
    x += bw + r.range(0.01, 0.04);
  }
  // Wet street with long reflections.
  final street = Rect.fromLTRB(0, 0.72 * k.h, k.w, k.h);
  c.drawRect(
    street,
    Paint()
      ..shader = _linear(street.topCenter, street.bottomCenter, [
        _c(0xFF1C1E2A),
        _c(0xFF0B0C12),
      ]),
  );
  for (var i = 0; i < 36; i++) {
    final rx = r.next();
    final warm = r.chance(0.7);
    final col = warm ? _c(0xFFFFB766) : _c(0xFF8FB8FF);
    k.softRect(
      Rect.fromLTWH(
        rx * k.w,
        0.72 * k.h,
        r.range(2, 7) * k.s,
        r.range(0.08, 0.26) * k.h,
      ),
      _a(col, r.range(0.12, 0.35)),
      4,
    );
  }
  // Street lamps.
  for (final lx in const [0.14, 0.5, 0.86]) {
    c.drawLine(k.p(lx, 0.5), k.p(lx, 0.74), k.stroke(_c(0xFF07080C), 3));
    k.glow(k.p(lx, 0.5), 0.12 * k.w, _a(_c(0xFFFFC98A), 0.7));
    c.drawCircle(k.p(lx, 0.5), 3 * k.s, k.fill(_c(0xFFFFF0D6)));
    k.ellipseGlow(
      Rect.fromCenter(
        center: k.p(lx, 0.8),
        width: 0.18 * k.w,
        height: 0.2 * k.h,
      ),
      _a(_c(0xFFFFC98A), 0.3),
    );
  }
  // Bokeh.
  for (var i = 0; i < 16; i++) {
    final o = k.p(r.next(), r.range(0.55, 0.95));
    k.softCircle(
      o,
      r.range(6, 18) * k.s,
      _a(r.chance(0.6) ? _c(0xFFFFC27A) : _c(0xFF9EC2FF), 0.16),
      3,
    );
  }
  k.rain(420, alpha: 0.2);
  k.haze(0.7, 0.1, _a(_c(0xFFA090A0), 0.12));
}

void _cafe(_K k) {
  final c = k.canvas;
  k.vertical(
    [_c(0xFF1E140E), _c(0xFF2E1F15), _c(0xFF140D09)],
    const [0, 0.55, 1],
  );
  final r = _Rng(k.seed + 1);
  // Window onto the rainy street.
  final win = Rect.fromLTRB(0.08 * k.w, 0.12 * k.h, 0.92 * k.w, 0.62 * k.h);
  c.drawRect(
    win,
    Paint()
      ..shader = _linear(win.topCenter, win.bottomCenter, [
        _c(0xFF1B2638),
        _c(0xFF2A3346),
        _c(0xFF3A3238),
      ]),
  );
  c.save();
  c.clipRect(win);
  for (var i = 0; i < 26; i++) {
    final o = Offset(
      win.left + r.next() * win.width,
      win.top + r.range(0.35, 1) * win.height,
    );
    final col = r.chance(0.55)
        ? _c(0xFFFFB86E)
        : (r.chance(0.5) ? _c(0xFF8DB4FF) : _c(0xFFFF7A6A));
    k.softCircle(o, r.range(8, 26) * k.s, _a(col, r.range(0.12, 0.3)), 5);
  }
  for (var i = 0; i < 140; i++) {
    final o = Offset(
      win.left + r.next() * win.width,
      win.top + r.next() * win.height,
    );
    final rad = r.range(0.8, 2.6) * k.s;
    c.drawCircle(o, rad, k.fill(_a(_c(0xFFCFE0FF), 0.18)));
    c.drawCircle(
      o.translate(-rad * 0.3, -rad * 0.3),
      rad * 0.35,
      k.fill(_a(_c(0xFFFFFFFF), 0.35)),
    );
  }
  k.rain(160, alpha: 0.12, area: win, sd: 3);
  c.restore();
  // Window frame and mullions.
  final frame = k.stroke(_c(0xFF0C0806), 7);
  c.drawRect(win, frame);
  c.drawLine(
    Offset(win.center.dx, win.top),
    Offset(win.center.dx, win.bottom),
    frame,
  );
  c.drawLine(
    Offset(win.left, win.top + win.height * 0.38),
    Offset(win.right, win.top + win.height * 0.38),
    frame..strokeWidth = 5 * k.s,
  );
  // Pendant lamps.
  for (final lx in const [0.24, 0.52, 0.8]) {
    final y = 0.08 + (lx * 7 % 1) * 0.06;
    c.drawLine(k.p(lx, 0), k.p(lx, y), k.stroke(_c(0xFF0A0705), 1.2));
    k.glow(k.p(lx, y + 0.02), 0.32 * k.w, _a(_c(0xFFFFA650), 0.32));
    c.drawPath(
      Path()
        ..moveTo((lx - 0.045) * k.w, (y + 0.025) * k.h)
        ..quadraticBezierTo(
          lx * k.w,
          (y - 0.02) * k.h,
          (lx + 0.045) * k.w,
          (y + 0.025) * k.h,
        )
        ..close(),
      k.fill(_c(0xFF2A1A0F)),
    );
    k.ellipseGlow(
      Rect.fromCenter(
        center: k.p(lx, y + 0.027),
        width: 0.08 * k.w,
        height: 0.012 * k.h,
      ),
      _a(_c(0xFFFFE0A8), 0.95),
    );
  }
  // Interior bokeh.
  for (var i = 0; i < 14; i++) {
    final o = k.p(r.next(), r.range(0.55, 0.8));
    k.softCircle(
      o,
      r.range(10, 28) * k.s,
      _a(_c(0xFFFFB25C), r.range(0.06, 0.16)),
      6,
    );
  }
  // Table with a cup.
  final table = Path()
    ..moveTo(0, 0.78 * k.h)
    ..lineTo(k.w, 0.74 * k.h)
    ..lineTo(k.w, k.h)
    ..lineTo(0, k.h)
    ..close();
  c.drawPath(
    table,
    Paint()
      ..shader = _linear(k.p(0, 0.74), k.p(0, 1), [
        _c(0xFF5A3A22),
        _c(0xFF2C1C10),
        _c(0xFF120B06),
      ]),
  );
  c.drawLine(
    k.p(0, 0.78),
    k.p(1, 0.74),
    k.stroke(_a(_c(0xFFFFC98A), 0.35), 2, blur: 1),
  );
  for (var i = 0; i < 30; i++) {
    final y = r.range(0.8, 1.0);
    c.drawLine(
      k.p(0, y),
      k.p(1, y - 0.04),
      k.stroke(_a(_c(0xFF000000), 0.12), r.range(0.5, 2)),
    );
  }
  final cup = Rect.fromCenter(
    center: k.p(0.62, 0.79),
    width: 0.16 * k.w,
    height: 0.07 * k.h,
  );
  k.ellipseGlow(
    Rect.fromCenter(
      center: cup.bottomCenter,
      width: cup.width * 1.8,
      height: cup.height * 0.5,
    ),
    _a(_c(0xFF000000), 0.6),
  );
  c.drawRRect(
    RRect.fromRectAndCorners(
      cup,
      bottomLeft: Radius.circular(cup.width * 0.4),
      bottomRight: Radius.circular(cup.width * 0.4),
    ),
    Paint()
      ..shader = _linear(cup.centerLeft, cup.centerRight, [
        _c(0xFFE8DED0),
        _c(0xFFB9AD9C),
        _c(0xFF6E655A),
      ]),
  );
  c.drawOval(
    Rect.fromCenter(
      center: cup.topCenter,
      width: cup.width,
      height: cup.height * 0.25,
    ),
    k.fill(_c(0xFF3A2414)),
  );
  c.drawArc(
    Rect.fromCenter(
      center: cup.centerRight.translate(4 * k.s, 0),
      width: cup.height * 0.7,
      height: cup.height * 0.6,
    ),
    -1.4,
    2.8,
    false,
    k.stroke(_c(0xFFB0A493), 3),
  );
  for (var i = 0; i < 3; i++) {
    final sx = cup.center.dx + (i - 1) * 8 * k.s;
    c.drawPath(
      Path()
        ..moveTo(sx, cup.top - 4 * k.s)
        ..cubicTo(
          sx - 8 * k.s,
          cup.top - 26 * k.s,
          sx + 8 * k.s,
          cup.top - 40 * k.s,
          sx,
          cup.top - 60 * k.s,
        ),
      k.stroke(_a(_c(0xFFFFFFFF), 0.1), 3, blur: 3),
    );
  }
}

void _toits(_K k) {
  final c = k.canvas;
  k.vertical(
    [_c(0xFF333D52), _c(0xFF56627A), _c(0xFF8A8E98)],
    const [0, 0.3, 0.45],
  );
  k.glow(k.p(0.25, 0.42), 0.6 * k.w, _a(_c(0xFFE7B88A), 0.3));
  final r = _Rng(k.seed + 1);
  // Receding roof rows, from far to near.
  for (var row = 0; row < 5; row++) {
    final t = row / 4;
    final baseY = 0.42 + t * 0.22;
    final height = 0.04 + t * 0.12;
    final haze = 1 - t;
    var x = -0.1 + r.range(0, 0.05);
    while (x < 1.1) {
      final bw = (0.12 + t * 0.35) * r.range(0.7, 1.2);
      final top = (baseY - height) * k.h;
      final roof = Path()
        ..moveTo(x * k.w, baseY * k.h)
        ..lineTo((x + bw * 0.12) * k.w, top)
        ..lineTo((x + bw * 0.88) * k.w, top)
        ..lineTo((x + bw) * k.w, baseY * k.h)
        ..close();
      final zinc = _mix(_c(0xFF4C586A), _c(0xFF7E8898), haze * 0.6);
      c.drawPath(
        roof,
        Paint()
          ..shader = _linear(Offset(0, top), Offset(0, baseY * k.h), [
            _mix(zinc, _c(0xFFFFFFFF), 0.12),
            zinc,
          ]),
      );
      // Standing seams.
      for (var sx = x + 0.012; sx < x + bw; sx += 0.012 + t * 0.012) {
        c.drawLine(
          Offset(sx * k.w, top + 2),
          Offset((sx + (sx - x - bw / 2) * 0.05) * k.w, baseY * k.h),
          k.stroke(_a(_c(0xFF20262F), 0.35), 0.6 + t),
        );
      }
      c.drawLine(
        Offset((x + bw * 0.12) * k.w, top),
        Offset((x + bw * 0.88) * k.w, top),
        k.stroke(_a(_c(0xFFE6ECF4), 0.35), 1 + t),
      );
      // Dormers with lit windows.
      if (r.chance(0.7)) {
        final dx = x + bw * r.range(0.3, 0.6);
        final dw = bw * 0.14;
        final dRect = Rect.fromLTWH(
          dx * k.w,
          top + height * k.h * 0.3,
          dw * k.w,
          height * k.h * 0.45,
        );
        c.drawRect(
          dRect.inflate(2 * k.s),
          k.fill(_mix(_c(0xFFC9C3B6), _c(0xFF7E8592), haze)),
        );
        final lit = r.chance(0.6);
        c.drawRect(
          dRect.deflate(dRect.width * 0.18),
          k.fill(lit ? _c(0xFFF2BF72) : _c(0xFF2A3140)),
        );
        if (lit) {
          k.glow(dRect.center, dRect.width * 2.5, _a(_c(0xFFFFC47A), 0.3));
        }
      }
      // Chimneys with terracotta pots.
      if (r.chance(0.6)) {
        final cx = x + bw * r.range(0.2, 0.8);
        final cw = 0.02 + t * 0.03;
        final ch = 0.02 + t * 0.05;
        final chimney = Rect.fromLTWH(
          cx * k.w,
          top - ch * k.h,
          cw * k.w,
          ch * k.h + 2,
        );
        c.drawRect(
          chimney,
          k.fill(_mix(_c(0xFF8C7A6C), _c(0xFF8D96A4), haze * 0.7)),
        );
        for (var p = 0; p < 3; p++) {
          c.drawRect(
            Rect.fromLTWH(
              chimney.left + chimney.width * (0.1 + p * 0.3),
              chimney.top - chimney.width * 0.25,
              chimney.width * 0.2,
              chimney.width * 0.3,
            ),
            k.fill(_mix(_c(0xFFA0563A), _c(0xFF8D96A4), haze * 0.6)),
          );
        }
      }
      x += bw + r.range(-0.02, 0.03);
    }
    k.haze(baseY, 0.04, _a(_c(0xFFB4BBC6), 0.25 * haze));
  }
  // Foreground roof edge with gutter, wet sheen.
  final near = Path()
    ..moveTo(0, 0.78 * k.h)
    ..lineTo(k.w, 0.7 * k.h)
    ..lineTo(k.w, k.h)
    ..lineTo(0, k.h)
    ..close();
  c.drawPath(
    near,
    Paint()
      ..shader = _linear(k.p(0, 0.7), k.p(0, 1), [
        _c(0xFF3D4757),
        _c(0xFF1A1F27),
      ]),
  );
  for (var i = 0; i < 22; i++) {
    final sx = i / 22;
    c.drawLine(
      k.p(sx, 0.78 - sx * 0.08),
      k.p(sx - 0.08, 1),
      k.stroke(_a(_c(0xFF0D1015), 0.5), 2),
    );
    c.drawLine(
      k.p(sx + 0.006, 0.78 - sx * 0.08),
      k.p(sx - 0.074, 1),
      k.stroke(_a(_c(0xFFB9C4D4), 0.12), 1),
    );
  }
  c.drawLine(k.p(0, 0.78), k.p(1, 0.7), k.stroke(_a(_c(0xFFDDE5EE), 0.5), 2.5));
  k.rain(380, alpha: 0.18, angle: 0.1);
}

// ---------------------------------------------------------------------------
// Astral

void _etoiles(_K k) {
  final c = k.canvas;
  k.vertical(
    [_c(0xFF03060F), _c(0xFF0A1428), _c(0xFF1A2742), _c(0xFF2C3352)],
    const [0, 0.45, 0.72, 0.84],
  );
  // Milky way band.
  c.save();
  c.translate(k.w * 0.5, k.h * 0.4);
  c.rotate(-1.05);
  final band = Rect.fromCenter(
    center: Offset.zero,
    width: k.h * 1.3,
    height: k.w * 0.42,
  );
  k.ellipseGlow(band, _a(_c(0xFFB8B4E8), 0.22));
  k.ellipseGlow(band.deflate(band.height * 0.2), _a(_c(0xFFFFE6CC), 0.16));
  final r = _Rng(k.seed + 1);
  final pts = Float32List(2400 * 2);
  for (var i = 0; i < 2400; i++) {
    final gx = (r.next() - 0.5) * band.width;
    final gy = (r.next() + r.next() + r.next() - 1.5) / 1.5 * band.height * 0.5;
    pts[i * 2] = gx;
    pts[i * 2 + 1] = gy;
  }
  c.drawRawPoints(
    ui.PointMode.points,
    pts,
    Paint()
      ..color = const Color(0x8CFFFFFF)
      ..strokeWidth = 0.9 * k.s
      ..strokeCap = StrokeCap.round,
  );
  for (var i = 0; i < 12; i++) {
    final o = Offset(
      (r.next() - 0.5) * band.width * 0.9,
      (r.next() - 0.5) * band.height * 0.25,
    );
    k.ellipseGlow(
      Rect.fromCenter(
        center: o,
        width: r.range(0.15, 0.4) * k.h,
        height: r.range(0.04, 0.08) * k.h,
      ),
      _a(_c(0xFF050814), 0.45),
    );
  }
  c.restore();
  k.stars(Rect.fromLTWH(0, 0, k.w, k.h * 0.8), 700, maxR: 1.6);
  k.glow(k.p(0.3, 0.86), 0.7 * k.w, _a(_c(0xFF52618A), 0.35));
  // Hills and trees silhouettes.
  c.drawPath(k.ridge(0.84, 0.05, 2, k.seed + 2), k.fill(_c(0xFF070A12)));
  c.drawPath(
    k.conifers(0.86, 0.04, 0.1, 0.05, k.seed + 3, x0: 0.62),
    k.fill(_c(0xFF03050A)),
  );
  c.drawPath(
    k.conifers(0.88, 0.03, 0.07, 0.06, k.seed + 4, x1: 0.25),
    k.fill(_c(0xFF03050A)),
  );
  c.drawRect(Rect.fromLTRB(0, 0.88 * k.h, k.w, k.h), k.fill(_c(0xFF03050A)));
}

void _aurore(_K k) {
  final c = k.canvas;
  k.vertical(
    [_c(0xFF030812), _c(0xFF07172A), _c(0xFF0C2638)],
    const [0, 0.4, 0.62],
  );
  k.stars(Rect.fromLTWH(0, 0, k.w, k.h * 0.62), 420, maxR: 1.4);
  final r = _Rng(k.seed + 1);
  // Aurora curtains: vertical rays standing on wavy curves.
  void curtain(
    double baseY,
    double amp,
    double height,
    Color low,
    Color high,
    int sd,
    double alpha,
  ) {
    for (var x = -0.05; x <= 1.05; x += 0.004) {
      final y =
          baseY +
          (_fbm(x * 1.6, sd, 3) - 0.5) * amp +
          math.sin(x * 5 + sd) * amp * 0.3;
      final hgt = height * (0.6 + _fbm(x * 7, sd + 9, 2) * 0.8);
      final intensity = math.pow(_fbm(x * 4, sd + 3, 3), 1.6) * alpha;
      final top = k.p(x, y - hgt);
      final bottom = k.p(x, y);
      // Rays 1.6 frame units apart and 5.5 wide: they overlap into a smooth curtain, so no
      // blur is needed (version 1 blurred each of the 550 lines, an offscreen pass each).
      c.drawLine(
        top,
        bottom,
        Paint()
          ..strokeWidth = 5.5 * k.s
          ..blendMode = BlendMode.plus
          ..shader = _linear(
            top,
            bottom,
            [
              _a(high, 0),
              _a(high, intensity * 0.4),
              _a(low, intensity * 0.8),
              _a(low, 0),
            ],
            const [0, 0.45, 0.88, 1],
          ),
      );
    }
  }

  curtain(0.36, 0.12, 0.22, _c(0xFF57FFB0), _c(0xFF9E7BFF), k.seed + 11, 0.55);
  curtain(0.3, 0.1, 0.16, _c(0xFF4CF0C8), _c(0xFF6FA8FF), k.seed + 23, 0.35);
  k.glow(
    k.p(0.5, 0.38),
    0.7 * k.w,
    _a(_c(0xFF2AD08A), 0.12),
    blend: BlendMode.plus,
  );
  // Snowy mountains.
  final mountains = k.ridge(0.58, 0.12, 2.4, k.seed + 2, bottom: 0.66 * k.h);
  c.drawPath(
    mountains,
    Paint()
      ..shader = _linear(k.p(0, 0.46), k.p(0, 0.66), [
        _c(0xFF1E3446),
        _c(0xFF0B1622),
      ]),
  );
  // Snow on the peaks, kept on the mountains (no clip).
  for (var i = 0; i < 80; i++) {
    final x = r.next();
    final top = 0.58 - _fbm(x * 2.4, k.seed + 2, 5) * 0.12;
    final from = k.p(x, top + 0.004);
    final to = k.p(x + r.range(-0.02, 0.02), top + r.range(0.006, 0.02));
    final paint = k.stroke(
      _a(_c(0xFFBFE6E0), r.range(0.06, 0.2)),
      r.range(1, 3),
      blur: 1.5,
    );
    if (!mountains.contains(from) || !mountains.contains(to)) continue;
    c.drawLine(from, to, paint);
  }
  // Lake with the aurora reflected.
  final lake = Rect.fromLTRB(0, 0.66 * k.h, k.w, 0.86 * k.h);
  c.drawRect(
    lake,
    Paint()
      ..shader = _linear(lake.topCenter, lake.bottomCenter, [
        _c(0xFF0F2A34),
        _c(0xFF06121A),
      ]),
  );
  c.save();
  c.clipRect(lake);
  // Side by side bands (no overlap, no blur): each fades out downwards.
  for (var x = 0.0; x <= 1; x += 0.01) {
    final intensity = math.pow(_fbm(x * 4, k.seed + 14, 3), 1.6) * 0.35;
    final top = k.p(x, 0.66);
    final bottom = k.p(x, 0.66 + 0.12 * _fbm(x * 7, k.seed + 20, 2) + 0.03);
    final glow = _a(_c(0xFF57FFB0), intensity * 0.8);
    c.drawLine(
      top,
      bottom,
      Paint()
        ..strokeWidth = 0.01 * k.w
        ..blendMode = BlendMode.plus
        ..shader = _linear(top, bottom, [glow, _a(glow, 0.5), _a(glow, 0)], const [0, 0.6, 1]),
    );
  }
  k.glints(lake, 120, _c(0xFFCFFFF0), maxAlpha: 0.2, maxLen: 30);
  c.restore();
  // Pines on the shore.
  c.drawPath(
    k.conifers(0.9, 0.06, 0.16, 0.05, k.seed + 3, x1: 0.32),
    k.fill(_c(0xFF02060A)),
  );
  c.drawPath(
    k.conifers(0.9, 0.05, 0.13, 0.05, k.seed + 4, x0: 0.7),
    k.fill(_c(0xFF02060A)),
  );
  c.drawRect(Rect.fromLTRB(0, 0.86 * k.h, k.w, k.h), k.fill(_c(0xFF02060A)));
  c.drawPath(k.ridge(0.87, 0.015, 3, k.seed + 5), k.fill(_c(0xFF02060A)));
}

void _luneLac(_K k) {
  final c = k.canvas;
  k.vertical(
    [_c(0xFF070E1C), _c(0xFF12203A), _c(0xFF22344F)],
    const [0, 0.38, 0.56],
  );
  k.stars(
    Rect.fromLTWH(0, 0, k.w, k.h * 0.52),
    260,
    maxR: 1.2,
    brightness: 0.7,
  );
  final moon = k.p(0.62, 0.2);
  final mr = 0.06 * k.w;
  k.glow(moon, mr * 9, _a(_c(0xFFBFD0F0), 0.28));
  k.glow(moon, mr * 3, _a(_c(0xFFEFF2FF), 0.35));
  c.drawCircle(
    moon,
    mr,
    Paint()
      ..shader = ui.Gradient.radial(
        moon.translate(-mr * 0.3, -mr * 0.3),
        mr * 1.4,
        [_c(0xFFFFFDF2), _c(0xFFE4E2D6)],
      ),
  );
  final r = _Rng(k.seed + 1);
  for (var i = 0; i < 7; i++) {
    k.softCircle(
      moon.translate(r.range(-0.6, 0.5) * mr, r.range(-0.6, 0.6) * mr),
      r.range(0.1, 0.3) * mr,
      _a(_c(0xFF9C9C94), 0.25),
      1,
    );
  }
  // Thin moonlit clouds.
  for (var i = 0; i < 6; i++) {
    final o = k.p(r.range(0.1, 1.0), r.range(0.12, 0.4));
    k.ellipseGlow(
      Rect.fromCenter(
        center: o,
        width: r.range(0.3, 0.7) * k.w,
        height: r.range(0.008, 0.02) * k.h,
      ),
      _a(_c(0xFFB9C8E6), 0.18),
    );
  }
  // Far hills and wooded shores.
  c.drawPath(
    k.ridge(0.56, 0.05, 1.8, k.seed + 2, bottom: 0.585 * k.h),
    k.fill(_c(0xFF18253D)),
  );
  c.drawPath(
    k.conifers(0.585, 0.02, 0.05, 0.03, k.seed + 3, x1: 0.36),
    k.fill(_c(0xFF0B1220)),
  );
  c.drawPath(
    k.conifers(0.585, 0.02, 0.06, 0.03, k.seed + 4, x0: 0.78),
    k.fill(_c(0xFF0B1220)),
  );
  k.haze(0.585, 0.025, _a(_c(0xFF8EA2C4), 0.25));
  // Lake.
  final lake = Rect.fromLTRB(0, 0.585 * k.h, k.w, k.h);
  c.drawRect(
    lake,
    Paint()
      ..shader = _linear(lake.topCenter, lake.bottomCenter, [
        _c(0xFF1F3048),
        _c(0xFF0D1828),
        _c(0xFF060C16),
      ]),
  );
  // Mirrored shore: both banks as one shape, mirrored in the path itself (no flipped canvas,
  // no clip), one soft blur.
  final mirror = Float64List.fromList([
    1, 0, 0, 0, //
    0, -1, 0, 0, //
    0, 0, 1, 0, //
    0, 2 * 0.585 * k.h, 0, 1,
  ]);
  final reflected = Path()
    ..addPath(k.conifers(0.585, 0.02, 0.05, 0.03, k.seed + 3, x1: 0.36), Offset.zero)
    ..addPath(k.conifers(0.585, 0.02, 0.06, 0.03, k.seed + 4, x0: 0.78), Offset.zero);
  c.drawPath(
    reflected.transform(mirror),
    k.blurredFill(_a(_c(0xFF0B1220), 0.7), 2),
  );
  // Moon glitter path.
  k.ellipseGlow(
    Rect.fromCenter(
      center: k.p(0.62, 0.68),
      width: 0.3 * k.w,
      height: 0.3 * k.h,
    ),
    _a(_c(0xFFDCE6FF), 0.12),
  );
  for (var i = 0; i < 420; i++) {
    final t = math.pow(r.next(), 0.9).toDouble();
    final y = 0.6 + t * 0.4;
    final spread = 0.02 + t * 0.16;
    final x = 0.62 + (r.next() + r.next() - 1) * spread;
    final len = (0.005 + t * 0.04) * r.range(0.4, 1.2);
    c.drawLine(
      k.p(x - len / 2, y),
      k.p(x + len / 2, y),
      k.stroke(
        _a(_c(0xFFF4F6FF), r.range(0.2, 0.85) * (1 - t * 0.5)),
        r.range(0.6, 1.6) * (0.6 + t),
      ),
    );
  }
  // Reeds in the foreground.
  for (var i = 0; i < 26; i++) {
    final base = k.p(r.range(-0.02, 0.3), 1.02);
    final top =
        base + Offset(r.range(-0.03, 0.05) * k.w, -r.range(0.08, 0.2) * k.h);
    c.drawPath(
      Path()
        ..moveTo(base.dx, base.dy)
        ..quadraticBezierTo(
          base.dx + (top.dx - base.dx) * 0.2,
          (base.dy + top.dy) / 2,
          top.dx,
          top.dy,
        ),
      k.stroke(_c(0xFF03060B), r.range(1.2, 2.6)),
    );
  }
}
