// Stroke icons drawn from the mockup's SVG paths (24 × 24 view box).
// A tiny SVG path parser keeps the shapes identical to the validated design.
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// One drawable part of an icon.
sealed class _Part {
  const _Part();
}

class _PathPart extends _Part {
  const _PathPart(this.d, {this.fill = false});
  final String d;
  final bool fill;
}

class _CirclePart extends _Part {
  const _CirclePart(this.cx, this.cy, this.r);
  final double cx, cy, r;
}

class _RectPart extends _Part {
  const _RectPart(this.x, this.y, this.w, this.h, this.rx, {this.fill = false});
  final double x, y, w, h, rx;
  final bool fill;
}

/// An icon: parts plus its default stroke width.
class VIconData {
  const VIconData(this._parts, {this.stroke = 1.8});
  final List<_Part> _parts;
  final double stroke;
}

abstract final class VIcons {
  static const heart = VIconData([
    _PathPart(
      'M19 14c1.49-1.46 3-3.21 3-5.5A5.5 5.5 0 0 0 16.5 3c-1.76 0-3 .5-4.5 2-1.5-1.5-2.74-2-4.5-2A5.5 5.5 0 0 0 2 8.5c0 2.3 1.5 4.05 3 5.5l7 7Z',
    ),
  ], stroke: 1.9);
  static const heartFilled = VIconData([
    _PathPart(
      'M19 14c1.49-1.46 3-3.21 3-5.5A5.5 5.5 0 0 0 16.5 3c-1.76 0-3 .5-4.5 2-1.5-1.5-2.74-2-4.5-2A5.5 5.5 0 0 0 2 8.5c0 2.3 1.5 4.05 3 5.5l7 7Z',
      fill: true,
    ),
    _PathPart(
      'M19 14c1.49-1.46 3-3.21 3-5.5A5.5 5.5 0 0 0 16.5 3c-1.76 0-3 .5-4.5 2-1.5-1.5-2.74-2-4.5-2A5.5 5.5 0 0 0 2 8.5c0 2.3 1.5 4.05 3 5.5l7 7Z',
    ),
  ], stroke: 1.9);
  static const arrowUp = VIconData([_PathPart('M5 15l7-7 7 7')], stroke: 2.2);
  static const arrowDown = VIconData([_PathPart('M5 9l7 7 7-7')], stroke: 2.2);
  static const chevronUp = VIconData([_PathPart('M6 15l6-6 6 6')], stroke: 2.2);
  static const chevronDown = VIconData([
    _PathPart('M6 9l6 6 6-6'),
  ], stroke: 2.2);
  static const chevronRight = VIconData([
    _PathPart('M9 6l6 6-6 6'),
  ], stroke: 2.2);
  static const chevronLeft = VIconData([
    _PathPart('M15 6l-6 6 6 6'),
  ], stroke: 2.2);
  static const menuCollapse = VIconData([
    _PathPart('M5 8.5l7 7 7-7'),
  ], stroke: 2.4);
  static const menuExpand = VIconData([
    _PathPart('M5 15.5l7-7 7 7'),
  ], stroke: 2.4);
  static const play = VIconData([
    _PathPart('M8 5.2v13.6L19.2 12z', fill: true),
  ]);
  static const pause = VIconData([
    _RectPart(6.5, 5, 3.8, 14, 1.2, fill: true),
    _RectPart(13.7, 5, 3.8, 14, 1.2, fill: true),
  ]);
  static const lock = VIconData([
    _RectPart(5, 11, 14, 9.5, 2.6),
    _PathPart('M8.2 11V8.2a3.8 3.8 0 0 1 7.6 0V11'),
  ], stroke: 2.1);
  static const mic = VIconData([
    _RectPart(9, 3, 6, 12, 3),
    _PathPart('M5.5 11.5a6.5 6.5 0 0 0 13 0M12 18v3'),
  ], stroke: 1.9);
  static const close = VIconData([
    _PathPart('M6 6l12 12M18 6L6 18'),
  ], stroke: 1.8);
  static const share = VIconData([
    _PathPart('M12 15V4M8 8l4-4 4 4M5 13v5a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-5'),
  ], stroke: 1.8);
  static const moon = VIconData([
    _PathPart('M20 14.5A8.5 8.5 0 1 1 9.5 4a7 7 0 0 0 10.5 10.5z'),
  ], stroke: 1.6);
  static const settings = VIconData([
    _PathPart('M4 7h8M18 7h2M4 17h2M12 17h8'),
    _CirclePart(15, 7, 2.2),
    _CirclePart(9, 17, 2.2),
  ], stroke: 1.6);
  static const timer = VIconData([
    _CirclePart(12, 13, 7.5),
    _PathPart('M12 9v4l2.5 1.5M9.5 3h5'),
  ], stroke: 1.7);
  static const alarm = VIconData([
    _CirclePart(12, 13, 7),
    _PathPart('M12 9.5V13l2.3 1.5M4.5 5.2L7.2 3M19.5 5.2L16.8 3'),
  ], stroke: 1.7);
  static const check = VIconData([_PathPart('M5 12l5 5 9-9')], stroke: 2.6);
  static const plus = VIconData([_PathPart('M12 5v14M5 12h14')], stroke: 2.2);
  static const minus = VIconData([_PathPart('M5 12h14')], stroke: 2.2);
  static const mixer = VIconData([
    _PathPart('M6 4v5M6 15v5M12 4v11M12 19v1M18 4v1M18 9v11'),
    _CirclePart(6, 12, 2.4),
    _CirclePart(12, 17, 2.4),
    _CirclePart(18, 7, 2.4),
  ], stroke: 1.7);
  static const wifiOff = VIconData([
    _PathPart(
      'M3 3l18 18M8.5 16.4a5 5 0 0 1 7 0M5 12.9a10 10 0 0 1 3.2-2M10.7 5.1A15 15 0 0 1 22 9M2 8.8a15 15 0 0 1 3-2.2M12 20h.01',
    ),
  ], stroke: 1.7);
  static const copy = VIconData([
    _PathPart(
      'M9 9h10a1 1 0 0 1 1 1v10a1 1 0 0 1-1 1H9a1 1 0 0 1-1-1V10a1 1 0 0 1 1-1zM16 9V5a1 1 0 0 0-1-1H5a1 1 0 0 0-1 1v10a1 1 0 0 0 1 1h3',
    ),
  ], stroke: 1.9);
  static const trash = VIconData([
    _PathPart('M4 7h16M9 7V4.5h6V7M6.5 7l1 12.5h9l1-12.5M10 11v5M14 11v5'),
  ], stroke: 1.8);
  static const swipe = VIconData([
    _PathPart('M12 3v18M8 7l4-4 4 4M8 17l4 4 4-4'),
  ], stroke: 1.9);
  static const shield = VIconData([
    _PathPart('M12 3l7 3v5.5c0 4.5-3 8-7 9.5-4-1.5-7-5-7-9.5V6l7-3z'),
    _PathPart('M9 12l2.2 2.2L15.5 10'),
  ], stroke: 1.8);
  static const bell = VIconData([
    _PathPart(
      'M6 16V11a6 6 0 0 1 12 0v5l1.5 2h-15L6 16zM10 20.5a2 2 0 0 0 4 0',
    ),
  ], stroke: 1.8);
  static const download = VIconData([
    _PathPart('M12 4v11M8 11l4 4 4-4M5 19h14'),
  ], stroke: 1.9);
  static const battery = VIconData([
    _RectPart(3, 7, 16, 10, 2.5),
    _PathPart('M21 10.5v3M6.5 10v4M10 10v4'),
  ], stroke: 1.8);
  static const google = VIconData([
    _PathPart(
      'M20 12.2c0-.6-.1-1.2-.2-1.7H12v3.3h4.5a4 4 0 0 1-1.7 2.6v2.1h2.8c1.6-1.5 2.4-3.7 2.4-6.3zM12 20.5c2.3 0 4.2-.8 5.6-2l-2.8-2.1c-.8.5-1.7.8-2.8.8-2.2 0-4-1.5-4.7-3.4H4.5v2.2A8.5 8.5 0 0 0 12 20.5zM7.3 13.8a5 5 0 0 1 0-3.4V8.2H4.5a8.5 8.5 0 0 0 0 7.8l2.8-2.2zM12 6.8c1.2 0 2.4.4 3.3 1.3l2.5-2.5A8.5 8.5 0 0 0 4.5 8.2l2.8 2.2C8 8.3 9.8 6.8 12 6.8z',
    ),
  ], stroke: 1.4);
  static const sparkle = VIconData([
    _PathPart(
      'M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8L12 3zM18.5 15.5l.8 2.2 2.2.8-2.2.8-.8 2.2-.8-2.2-2.2-.8 2.2-.8.8-2.2z',
    ),
  ], stroke: 1.6);
  static const refresh = VIconData([
    _PathPart('M19.5 12a7.5 7.5 0 1 1-2.2-5.3M19.5 4.5v4h-4'),
  ], stroke: 1.9);
  static const question = VIconData([
    _CirclePart(12, 12, 9),
    _PathPart('M9.5 9.5a2.6 2.6 0 0 1 5 .8c0 1.8-2.5 2.2-2.5 3.9M12 17.2h.01'),
  ], stroke: 1.9);
}

/// Draws a [VIconData] at [size] with [color]. Purely decorative: wrap it in a labelled
/// button for accessibility.
class VIcon extends StatelessWidget {
  const VIcon(
    this.icon, {
    super.key,
    this.size = 24,
    this.color,
    this.strokeWidth,
  });

  final VIconData icon;
  final double size;
  final Color? color;
  final double? strokeWidth;

  @override
  Widget build(BuildContext context) {
    final c =
        color ??
        DefaultTextStyle.of(context).style.color ??
        const Color(0xFFFFFFFF);
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: _VIconPainter(icon, c, strokeWidth ?? icon.stroke),
        ),
      ),
    );
  }
}

class _VIconPainter extends CustomPainter {
  _VIconPainter(this.icon, this.color, this.stroke);

  final VIconData icon;
  final Color color;
  final double stroke;

  static final Map<String, Path> _cache = {};

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    canvas.save();
    canvas.scale(s);
    final strokePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    final fillPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    for (final part in icon._parts) {
      switch (part) {
        case _PathPart(:final d, :final fill):
          final path = _cache.putIfAbsent(d, () => parseSvgPath(d));
          canvas.drawPath(path, fill ? fillPaint : strokePaint);
        case _CirclePart(:final cx, :final cy, :final r):
          canvas.drawCircle(Offset(cx, cy), r, strokePaint);
        case _RectPart(
          :final x,
          :final y,
          :final w,
          :final h,
          :final rx,
          :final fill,
        ):
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(x, y, w, h),
              Radius.circular(rx),
            ),
            fill ? fillPaint : strokePaint,
          );
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_VIconPainter old) =>
      old.icon != icon || old.color != color || old.stroke != stroke;
}

/// Minimal SVG path data parser: M L H V C S Q A Z, absolute and relative.
Path parseSvgPath(String d) {
  final path = Path();
  final tokens = RegExp(
    r'[MmLlHhVvCcSsQqAaZz]|-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?',
  ).allMatches(d).map((m) => m.group(0)!).toList();
  var i = 0;
  var cmd = '';
  var cx = 0.0, cy = 0.0, sx = 0.0, sy = 0.0;
  var lastC2x = 0.0, lastC2y = 0.0;
  var lastWasCubic = false;
  bool isCmd(String t) => RegExp(r'^[A-Za-z]$').hasMatch(t);
  double n() => double.parse(tokens[i++]);
  while (i < tokens.length) {
    if (isCmd(tokens[i])) {
      cmd = tokens[i++];
    }
    final rel = cmd.toLowerCase() == cmd;
    switch (cmd.toUpperCase()) {
      case 'M':
        var x = n(), y = n();
        if (rel) {
          x += cx;
          y += cy;
        }
        path.moveTo(x, y);
        cx = sx = x;
        cy = sy = y;
        cmd = rel ? 'l' : 'L';
        lastWasCubic = false;
      case 'L':
        var x = n(), y = n();
        if (rel) {
          x += cx;
          y += cy;
        }
        path.lineTo(x, y);
        cx = x;
        cy = y;
        lastWasCubic = false;
      case 'H':
        var x = n();
        if (rel) x += cx;
        path.lineTo(x, cy);
        cx = x;
        lastWasCubic = false;
      case 'V':
        var y = n();
        if (rel) y += cy;
        path.lineTo(cx, y);
        cy = y;
        lastWasCubic = false;
      case 'C':
        var x1 = n(), y1 = n(), x2 = n(), y2 = n(), x = n(), y = n();
        if (rel) {
          x1 += cx;
          y1 += cy;
          x2 += cx;
          y2 += cy;
          x += cx;
          y += cy;
        }
        path.cubicTo(x1, y1, x2, y2, x, y);
        lastC2x = x2;
        lastC2y = y2;
        cx = x;
        cy = y;
        lastWasCubic = true;
      case 'S':
        var x2 = n(), y2 = n(), x = n(), y = n();
        if (rel) {
          x2 += cx;
          y2 += cy;
          x += cx;
          y += cy;
        }
        final x1 = lastWasCubic ? 2 * cx - lastC2x : cx;
        final y1 = lastWasCubic ? 2 * cy - lastC2y : cy;
        path.cubicTo(x1, y1, x2, y2, x, y);
        lastC2x = x2;
        lastC2y = y2;
        cx = x;
        cy = y;
        lastWasCubic = true;
      case 'Q':
        var x1 = n(), y1 = n(), x = n(), y = n();
        if (rel) {
          x1 += cx;
          y1 += cy;
          x += cx;
          y += cy;
        }
        path.quadraticBezierTo(x1, y1, x, y);
        cx = x;
        cy = y;
        lastWasCubic = false;
      case 'A':
        final rx = n(), ry = n(), rot = n();
        final large = n() != 0, sweep = n() != 0;
        var x = n(), y = n();
        if (rel) {
          x += cx;
          y += cy;
        }
        path.arcToPoint(
          Offset(x, y),
          radius: Radius.elliptical(rx, ry),
          rotation: rot * math.pi / 180,
          largeArc: large,
          clockwise: sweep,
        );
        cx = x;
        cy = y;
        lastWasCubic = false;
      case 'Z':
        path.close();
        cx = sx;
        cy = sy;
        lastWasCubic = false;
      default:
        i++;
    }
  }
  return path;
}
