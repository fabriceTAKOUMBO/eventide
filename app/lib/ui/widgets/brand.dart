// Identity: the app logo (the bundled brand picture, or a drawn drop as fallback) and the
// « Full Relax » wordmark, set in the title face of the « Galerie » style.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../landscape/landscape_image.dart';
import '../theme/vitre.dart';
import 'vicons.dart';

/// Name of the product as users see it.
const String _brandName = 'Full Relax';

/// App logo in its rounded tile. Uses the generated brand asset when bundled,
/// otherwise draws the drop.
class BrandLogo extends StatelessWidget {
  const BrandLogo({super.key, this.size = 104});

  final double size;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(size / 4);
    return Semantics(
      image: true,
      label: 'Logo $_brandName',
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: const [
            BoxShadow(
              color: Color(0x80000000),
              blurRadius: 36,
              offset: Offset(0, 14),
            ),
          ],
        ),
        foregroundDecoration: BoxDecoration(
          borderRadius: radius,
          border: Border.all(color: VitreColors.whiteA(0.28)),
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: ValueListenableBuilder<String?>(
            valueListenable: LandscapeImages.brandLogo,
            builder: (context, asset, _) => asset != null
                ? Image.asset(
                    asset,
                    fit: BoxFit.cover,
                    errorBuilder: (c, e, s) => _painted(),
                  )
                : _painted(),
          ),
        ),
      ),
    );
  }

  Widget _painted() => RepaintBoundary(
    child: CustomPaint(
      size: Size.square(size),
      painter: const BrandDropPainter(),
    ),
  );
}

/// The landscape held by the drop (fallback logo only: the bundled logo is a picture): a soft
/// forest light, drawn directly (the 2D procedural landscapes are gone).
void _paintBackdrop(Canvas canvas, Size size) {
  final rect = Offset.zero & size;
  canvas.drawRect(
    rect,
    Paint()
      ..shader = ui.Gradient.linear(
        rect.topCenter,
        rect.bottomCenter,
        const [Color(0xFF9CC9B4), Color(0xFF3F7461), Color(0xFF16302A)],
        const [0, 0.55, 1],
      ),
  );
  canvas.drawRect(
    rect,
    Paint()
      ..shader = ui.Gradient.radial(
        Offset(size.width * 0.5, size.height * 0.3),
        size.width * 0.6,
        const [Color(0x66F2E6C4), Color(0x00F2E6C4)],
      ),
  );
}

const String _dropPath =
    'M256 108 C259 108 262 112 266 118 C300 170 368 244 368 318 C368 380 318 412 256 412 '
    'C194 412 144 380 144 318 C144 244 212 170 246 118 C250 112 253 108 256 108 Z';

/// The drop on dark glass, holding the landscape upside down like a lens.
class BrandDropPainter extends CustomPainter {
  const BrandDropPainter();

  static final Path _drop = parseSvgPath(_dropPath);

  static const List<(double, double, double)> _droplets = [
    (92, 128, 11),
    (428, 98, 7),
    (74, 392, 13),
    (444, 410, 9),
    (420, 292, 5),
    (150, 70, 5.5),
    (448, 48, 19),
    (58, 66, 8),
    (210, 50, 9),
    (300, 38, 6),
    (366, 64, 12),
    (474, 176, 6),
    (462, 336, 10),
    (408, 372, 17),
    (40, 178, 9),
    (116, 304, 7),
    (62, 448, 21),
    (180, 468, 12),
    (296, 466, 7),
    (346, 440, 10),
    (132, 204, 15),
    (398, 206, 11),
    (140, 410, 6),
    (470, 470, 7),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 512;
    canvas.save();
    canvas.scale(s);
    const full = Rect.fromLTWH(0, 0, 512, 512);
    canvas.clipRRect(RRect.fromRectAndRadius(full, const Radius.circular(112)));

    // Blurred landscape behind dark glass.
    canvas.saveLayer(
      full,
      Paint()
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: 16,
          sigmaY: 16,
          tileMode: TileMode.clamp,
        ),
    );
    _paintBackdrop(canvas, const Size(512, 512));
    canvas.restore();
    canvas.drawRect(full, Paint()..color = const Color(0xBD04140F));
    canvas.drawRect(
      full,
      Paint()
        ..shader = ui.Gradient.radial(
          const Offset(256, 235),
          400,
          const [Color(0x00000000), Color(0x9E000000)],
          const [0.35, 1],
        ),
    );

    // Small drops on the glass.
    for (final (x, y, r) in _droplets) {
      final c = Offset(x, y);
      canvas.drawCircle(
        c.translate(r * 0.12, r * 0.28),
        r * 1.02,
        Paint()
          ..color = const Color(0x66000000)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.4),
      );
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..shader = ui.Gradient.radial(
            c.translate(0, r * 0.24),
            r * 1.2,
            const [Color(0x57CDEEE0), Color(0x401B3D35), Color(0x8C000000)],
            const [0, 0.6, 1],
          ),
      );
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = const Color(0x47FFFFFF),
      );
      canvas.drawCircle(
        c.translate(-r * 0.36, -r * 0.4),
        r * 0.2 < 1.6 ? 1.6 : r * 0.2,
        Paint()..color = const Color(0xD9FFFFFF),
      );
    }
    for (final (x, y, r, color) in const [
      (120.0, 210.0, 54.0, Color(0x1A8FD3B0)),
      (400.0, 170.0, 44.0, Color(0x1AF2C98A)),
      (380.0, 380.0, 64.0, Color(0x177FC6C0)),
    ]) {
      canvas.drawCircle(
        Offset(x, y),
        r,
        Paint()
          ..color = color
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
      );
    }

    // Main drop.
    canvas.save();
    canvas.translate(256, 260);
    canvas.scale(0.9);
    canvas.translate(-256, -260);
    canvas.drawPath(
      _drop.shift(const Offset(10, 16)),
      Paint()
        ..color = const Color(0x99000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
    );
    canvas.save();
    canvas.clipPath(_drop);
    canvas.saveLayer(
      full,
      Paint()
        ..colorFilter = ColorFilter.matrix(
          landscapeMatrix(brightness: 1.35, saturation: 1.7),
        ),
    );
    canvas.translate(256, 259);
    canvas.rotate(3.14159265);
    canvas.translate(-256, -259);
    canvas.translate(91, 42);
    _paintBackdrop(canvas, const Size(330, 586));
    canvas.restore();
    canvas.drawRect(
      const Rect.fromLTWH(120, 90, 280, 340),
      Paint()
        ..shader = ui.Gradient.radial(
          const Offset(256, 316),
          132,
          const [Color(0x00000000), Color(0x61000000), Color(0xC7000000)],
          const [0.5, 0.82, 1],
        ),
    );
    canvas.drawRect(
      const Rect.fromLTWH(120, 90, 280, 340),
      Paint()
        ..shader = ui.Gradient.linear(
          const Offset(0, 90),
          const Offset(0, 226),
          const [Color(0x47000000), Color(0x00000000)],
        ),
    );
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(262, 388), width: 172, height: 56),
      Paint()
        ..color = const Color(0x9EF2FFD9)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
    );
    canvas.drawPath(
      _drop,
      Paint()
        ..shader = ui.Gradient.linear(
          const Offset(144, 108),
          const Offset(368, 412),
          const [Color(0x8CFFFFFF), Color(0x00FFFFFF)],
          const [0, 0.45],
        ),
    );
    canvas.restore();
    canvas.drawPath(
      _drop,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeJoin = StrokeJoin.round
        ..shader = ui.Gradient.linear(
          const Offset(144, 108),
          const Offset(368, 412),
          const [Color(0xD9FFFFFF), Color(0x38FFFFFF), Color(0x80FFFFFF)],
          const [0, 0.5, 1],
        ),
    );
    void highlight(
      Offset c,
      double rx,
      double ry,
      double deg,
      Color color, {
      double blur = 0,
    }) {
      canvas.save();
      canvas.translate(c.dx, c.dy);
      canvas.rotate(deg * 3.14159265 / 180);
      final paint = Paint()..color = color;
      if (blur > 0) paint.maskFilter = MaskFilter.blur(BlurStyle.normal, blur);
      canvas.drawOval(
        Rect.fromCenter(center: Offset.zero, width: rx * 2, height: ry * 2),
        paint,
      );
      canvas.restore();
    }

    highlight(
      const Offset(190, 280),
      8,
      46,
      10,
      const Color(0x66FFFFFF),
      blur: 2.4,
    );
    highlight(const Offset(190, 280), 3.8, 38, 10, const Color(0xE6FFFFFF));
    canvas.drawCircle(
      const Offset(238, 200),
      5,
      Paint()..color = const Color(0xD9FFFFFF),
    );
    highlight(
      const Offset(332, 366),
      6,
      17,
      34,
      const Color(0x80FFFFFF),
      blur: 2.4,
    );
    canvas.restore();
    canvas.restore();
  }

  @override
  bool shouldRepaint(BrandDropPainter oldDelegate) => false;
}

/// « Full Relax » in Cormorant Garamond 500 upright (the title face of the « Galerie » style),
/// slightly tracked, in warm white with a soft shadow. Not scaled by the text size setting: it is
/// a drawing (alternative text « Full Relax »).
class Wordmark extends StatelessWidget {
  const Wordmark({super.key, this.fontSize = 40});

  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final painter = _WordmarkPainter(fontSize);
    return Semantics(
      label: _brandName,
      container: true,
      excludeSemantics: true,
      child: CustomPaint(size: painter.measure(), painter: painter),
    );
  }
}

class _WordmarkPainter extends CustomPainter {
  _WordmarkPainter(this.fontSize);

  final double fontSize;

  /// Tracking in em: opens the Garamond a little, as display type is set for a name.
  static const double _trackingEm = 0.04;

  TextPainter _layout() {
    final style = VitreType.title(
      size: fontSize,
      color: VitreColors.wordmark,
      height: 1.1,
    ).copyWith(
      letterSpacing: _trackingEm * fontSize,
      shadows: const [
        Shadow(color: Color(0x8C000000), blurRadius: 18, offset: Offset(0, 2)),
      ],
    );
    return TextPainter(
      text: TextSpan(text: _brandName, style: style),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    )..layout();
  }

  Size measure() {
    final tp = _layout();
    final size = tp.size;
    tp.dispose();
    return size;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final tp = _layout();
    tp.paint(canvas, Offset.zero);
    tp.dispose();
  }

  @override
  bool shouldRepaint(_WordmarkPainter oldDelegate) =>
      oldDelegate.fontSize != fontSize;
}
