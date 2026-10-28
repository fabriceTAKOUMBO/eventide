// Landscape picture used everywhere (home, sheets backgrounds, thumbnails).
// Prefers a real photo when one is available, otherwise the procedural painter.
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/scene.dart' show Moment;
import '../theme/vitre.dart';
import 'landscape_painter.dart';

/// Returns a real photo for a landscape id, or null to use the procedural painter.
typedef LandscapeImageResolver = ImageProvider? Function(String landscapeId);

/// Where real photos come from. The content pipeline can set [resolver] (for example
/// to a downloaded file); bundled `assets/landscapes/<id>.jpg` files are found by
/// [discoverAssets].
abstract final class LandscapeImages {
  static LandscapeImageResolver? resolver;
  static final Set<String> _bundled = {};
  static final ValueNotifier<String?> brandLogo = ValueNotifier<String?>(null);

  static ImageProvider? providerFor(String landscapeId) {
    final custom = resolver?.call(landscapeId);
    if (custom != null) return custom;
    if (_bundled.contains(landscapeId)) {
      return AssetImage('assets/landscapes/$landscapeId.jpg');
    }
    return null;
  }

  /// Reads the asset manifest once to find bundled photos and the brand logo.
  static Future<void> discoverAssets([AssetBundle? bundle]) async {
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(
        bundle ?? rootBundle,
      );
      final assets = manifest.listAssets();
      for (final a in assets) {
        final m = RegExp(r'^assets/landscapes/([a-z0-9-]+)\.jpg$')
            .firstMatch(a);
        if (m != null) _bundled.add(m.group(1)!);
      }
      for (final candidate in const [
        'assets/brand/logo.png',
        'assets/brand/logo_512.png',
      ]) {
        if (assets.contains(candidate)) {
          brandLogo.value = candidate;
          break;
        }
      }
    } catch (_) {
      // No manifest (tests, previews): procedural pictures only.
    }
  }
}

/// Colour matrix giving the light of a moment of the day.
List<double> momentMatrix(Moment moment) => switch (moment) {
  Moment.aube => _compose(
    _gains(1.04, 0.9, 0.95, 12, 2, 10),
    _saturation(0.92),
  ),
  Moment.jour => _identity,
  Moment.soir => _compose(_gains(1.02, 0.8, 0.56, 8, 0, 0), _saturation(1.1)),
  Moment.nuit => _compose(_gains(0.3, 0.38, 0.6, 0, 3, 12), _saturation(0.45)),
};

const List<double> _identity = [
  1, 0, 0, 0, 0, //
  0, 1, 0, 0, 0, //
  0, 0, 1, 0, 0, //
  0, 0, 0, 1, 0,
];

List<double> _gains(
  double r,
  double g,
  double b,
  double ro,
  double go,
  double bo,
) => [
  r, 0, 0, 0, ro, //
  0, g, 0, 0, go, //
  0, 0, b, 0, bo, //
  0, 0, 0, 1, 0,
];

List<double> _saturation(double s) {
  const lr = 0.2126, lg = 0.7152, lb = 0.0722;
  return [
    lr * (1 - s) + s, lg * (1 - s), lb * (1 - s), 0, 0, //
    lr * (1 - s), lg * (1 - s) + s, lb * (1 - s), 0, 0, //
    lr * (1 - s), lg * (1 - s), lb * (1 - s) + s, 0, 0, //
    0, 0, 0, 1, 0,
  ];
}

/// Returns the matrix applying [b] first, then [a].
List<double> _compose(List<double> a, List<double> b) {
  final out = List<double>.filled(20, 0);
  for (var row = 0; row < 4; row++) {
    for (var col = 0; col < 5; col++) {
      var v = 0.0;
      for (var k = 0; k < 4; k++) {
        v += a[row * 5 + k] * b[k * 5 + col];
      }
      if (col == 4) v += a[row * 5 + 4];
      out[row * 5 + col] = v;
    }
  }
  return out;
}

/// Combined filter: moment light, then brightness and saturation adjustments.
List<double> landscapeMatrix({
  Moment moment = Moment.jour,
  double brightness = 1,
  double saturation = 1,
}) {
  var m = momentMatrix(moment);
  if (saturation != 1) m = _compose(_saturation(saturation), m);
  if (brightness != 1) {
    m = _compose(_gains(brightness, brightness, brightness, 0, 0, 0), m);
  }
  return m;
}

/// Full-bleed landscape: real photo or procedural picture, moment light, optional
/// blur and slow Ken Burns motion (disabled with reduced motion).
class LandscapeImage extends StatelessWidget {
  const LandscapeImage({
    super.key,
    required this.landscapeId,
    required this.style,
    this.moment = Moment.jour,
    this.kenBurns = false,
    this.blurSigma = 0,
    this.brightness = 1,
    this.saturation = 1,
  });

  final String landscapeId;
  final String style;
  final Moment moment;
  final bool kenBurns;
  final double blurSigma;
  final double brightness;
  final double saturation;

  @override
  Widget build(BuildContext context) {
    final provider = LandscapeImages.providerFor(landscapeId);
    final focus = Alignment(0, landscapeFocusY(style) * 2 - 1);
    Widget picture = provider != null
        ? Image(
            image: provider,
            fit: BoxFit.cover,
            alignment: focus,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
            errorBuilder: (context, error, stack) =>
                ProceduralLandscape(style: style),
          )
        : ProceduralLandscape(style: style);
    final matrix = landscapeMatrix(
      moment: moment,
      brightness: brightness,
      saturation: saturation,
    );
    if (!identical(matrix, _identity)) {
      picture = ColorFiltered(
        colorFilter: ColorFilter.matrix(matrix),
        child: picture,
      );
    }
    if (kenBurns && !Vitre.reduceMotion(context)) {
      picture = KenBurns(child: picture);
    } else if (kenBurns) {
      picture = Transform.scale(
        scale: 1.04,
        alignment: const Alignment(0, -0.2),
        child: picture,
      );
    }
    if (blurSigma > 0) {
      picture = ImageFiltered(
        imageFilter: ui.ImageFilter.blur(
          sigmaX: blurSigma,
          sigmaY: blurSigma,
          tileMode: TileMode.clamp,
        ),
        child: picture,
      );
    }
    return ClipRect(child: SizedBox.expand(child: picture));
  }
}

/// Procedural picture rasterised once per size and reused (cheap to animate).
class ProceduralLandscape extends StatelessWidget {
  const ProceduralLandscape({super.key, required this.style});

  final String style;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (!size.isFinite || size.isEmpty) return const SizedBox.shrink();
        final ratio = (MediaQuery.maybeDevicePixelRatioOf(context) ?? 2).clamp(
          1.0,
          1.75,
        );
        final image = LandscapeRasterCache.obtain(style, size, ratio);
        if (image == null) {
          return RepaintBoundary(
            child: CustomPaint(
              size: size,
              painter: LandscapePainter(style: style),
            ),
          );
        }
        return RawImage(
          image: image,
          width: size.width,
          height: size.height,
          fit: BoxFit.fill,
          filterQuality: FilterQuality.medium,
        );
      },
    );
  }
}

/// LRU cache of rasterised procedural landscapes.
abstract final class LandscapeRasterCache {
  static final Map<String, ui.Image> _images = {};
  static int _pixels = 0;
  static const int _budget = 14 * 1000 * 1000;
  static bool _unsupported = false;

  static ui.Image? obtain(String style, Size size, double ratio) {
    if (_unsupported) return null;
    final w = (size.width * ratio).ceil();
    final h = (size.height * ratio).ceil();
    final key = '$style@${w}x$h';
    final hit = _images.remove(key);
    if (hit != null) {
      _images[key] = hit;
      return hit;
    }
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.scale(ratio);
    paintLandscapeCover(canvas, size, style);
    final picture = recorder.endRecording();
    try {
      final image = picture.toImageSync(w, h);
      picture.dispose();
      _images[key] = image;
      _pixels += w * h;
      while (_pixels > _budget && _images.length > 1) {
        final oldest = _images.keys.first;
        final img = _images.remove(oldest)!;
        _pixels -= img.width * img.height;
        // Not disposed: a RawImage may still show it; the GC releases it.
      }
      return image;
    } catch (_) {
      picture.dispose();
      _unsupported = true;
      return null;
    }
  }

  @visibleForTesting
  static void clear() {
    _images.clear();
    _pixels = 0;
  }
}

/// Very slow zoom and drift (60 s, scale 1.04 → 1.12), updated ~20 times per second
/// to spare the battery; paused when hidden or when the app is in background.
class KenBurns extends StatefulWidget {
  const KenBurns({
    super.key,
    required this.child,
    this.period = const Duration(seconds: 60),
  });

  final Widget child;
  final Duration period;

  @override
  State<KenBurns> createState() => _KenBurnsState();
}

class _KenBurnsState extends State<KenBurns> with WidgetsBindingObserver {
  static final Stopwatch _clock = Stopwatch()..start();
  Timer? _timer;
  double _t = 0;
  bool _visible = true;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _t = _phase();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = TickerMode.valuesOf(context).enabled;
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _sync();
  }

  void _sync() {
    final run = _visible && _foreground;
    if (run && _timer == null) {
      _timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
        if (mounted) setState(() => _t = _phase());
      });
    } else if (!run) {
      _timer?.cancel();
      _timer = null;
    }
  }

  /// Shared clock so that every landscape moves in the same phase.
  double _phase() {
    final ms = widget.period.inMilliseconds;
    final cycle = (_clock.elapsedMilliseconds % (2 * ms)) / ms; // 0..2
    final linear = cycle <= 1 ? cycle : 2 - cycle;
    return Curves.easeInOut.transform(linear);
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scale = 1.04 + 0.08 * _t;
    return Transform(
      alignment: const Alignment(0, -0.2),
      transform: Matrix4.identity()
        ..translateByDouble(0, -10 * _t, 0, 1)
        ..scaleByDouble(scale, scale, 1, 1),
      child: widget.child,
    );
  }
}
