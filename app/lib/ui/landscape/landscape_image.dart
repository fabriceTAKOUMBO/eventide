// Landscape picture used everywhere (sheets backgrounds, thumbnails): the landscape's poster.
// Every landscape has one (contract § 12): the first frame of a filmed landscape's video, or the
// frame at t = 0 of a 3D scene. Bundled (free landscapes, demo build) or downloaded (Premium);
// until it is on the phone, a plain dark picture. Nothing is drawn by the app any more (the 2D
// procedural landscapes are gone). The full-screen landscape (home, welcome, offline) is
// LandscapeBackground, which adds the looping video or the live 3D scene.
import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/landscape_media.dart';
import '../theme/vitre.dart';

/// Returns a real photo for a landscape id, or null when none is on the phone.
typedef LandscapeImageResolver = ImageProvider? Function(String landscapeId);

/// Where the posters come from: bundled `assets/landscapes/<id>.jpg` files (found by
/// [discoverAssets]), then [resolver] (set by the app to the posters downloaded for Premium).
abstract final class LandscapeImages {
  static LandscapeImageResolver? resolver;
  static final Set<String> _bundled = {};
  static final Set<String> _bundledVideos = {};
  static final Set<String> _remoteVideos = {};
  static bool _sceneRuntime = false;
  static final ValueNotifier<String?> brandLogo = ValueNotifier<String?>(null);

  /// Bumped when [discoverAssets] has found the bundled media (pictures may change).
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// Entry page of the 3D scenes' runtime (`assets/imaginaire/`, contract § 12).
  static const String sceneRuntimeIndex = 'assets/imaginaire/index.html';

  static ImageProvider? providerFor(String landscapeId) {
    if (_bundled.contains(landscapeId)) {
      return AssetImage(LandscapeMediaKeys.bundledImage(landscapeId));
    }
    return resolver?.call(landscapeId);
  }

  /// The poster decoded at thumbnail size (menu tile, grid, schedules): one small copy
  /// (480 px wide) per landscape instead of the full picture.
  static ImageProvider? thumbnailFor(String landscapeId) {
    final provider = providerFor(landscapeId);
    return provider == null
        ? null
        : ResizeImage(
            provider,
            width: 480,
            policy: ResizeImagePolicy.fit,
          );
  }

  /// A looping video exists for this landscape (bundled, or on the content server). Whether it
  /// can be played now is the model's answer (AppModel.landscapeVideo); this only decides that
  /// the still picture stays put (no Ken Burns), so that the video replaces it without a jump.
  static bool hasVideo(String landscapeId) =>
      _bundledVideos.contains(landscapeId) ||
      _remoteVideos.contains(landscapeId);

  /// The runtime of the 3D scenes is bundled (`assets/imaginaire/index.html`). Without it a 3D
  /// scene shows its poster only.
  static bool get hasSceneRuntime => _sceneRuntime;

  @visibleForTesting
  static void debugSetVideos({Set<String> bundled = const {}, Set<String> remote = const {}}) {
    _bundledVideos
      ..clear()
      ..addAll(bundled);
    _remoteVideos
      ..clear()
      ..addAll(remote);
    revision.value++;
  }

  /// Set by tests: wins over what [discoverAssets] reads in the manifest, so the flag never
  /// flips back and forth (each flip would open or close a scene).
  static bool? _sceneRuntimeOverride;

  /// The value a test forced, or null.
  @visibleForTesting
  static bool? get debugSceneRuntimeOverride => _sceneRuntimeOverride;

  /// Forces the flag for tests (null: back to the manifest). Setting the same value again does
  /// nothing: a flip would close a live scene and open it again.
  @visibleForTesting
  static void debugSetSceneRuntime(bool? available) {
    _sceneRuntimeOverride = available;
    if (available == null || available == _sceneRuntime) return;
    _sceneRuntime = available;
    revision.value++;
  }

  /// Reads the asset manifest once to find bundled photos, videos, the 3D runtime and the brand
  /// logo.
  static Future<void> discoverAssets([AssetBundle? bundle]) async {
    try {
      final assetBundle = bundle ?? rootBundle;
      final manifest = await AssetManifest.loadFromAssetBundle(assetBundle);
      final assets = manifest.listAssets();
      for (final a in assets) {
        final m = RegExp(r'^assets/landscapes/([a-z0-9-]+)\.(jpg|mp4)$')
            .firstMatch(a);
        if (m == null) continue;
        (m.group(2) == 'jpg' ? _bundled : _bundledVideos).add(m.group(1)!);
      }
      _sceneRuntime = _sceneRuntimeOverride ?? assets.contains(sceneRuntimeIndex);
      if (assets.contains(LandscapeMediaKeys.remoteManifest)) {
        try {
          // Not cached by the bundle: read once here, and a cached future would outlive
          // the zone that created it (widget tests).
          final remote = RemoteLandscapeMedia.fromJson(
            jsonDecode(
              await assetBundle.loadString(
                LandscapeMediaKeys.remoteManifest,
                cache: false,
              ),
            ),
          );
          _remoteVideos.addAll(remote.videos);
        } catch (_) {}
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
      // No manifest (tests, previews): plain pictures only.
    }
    revision.value++;
  }
}

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

/// Brightness and saturation adjustments of a background (sheets, offline screen). A filmed
/// landscape is never recoloured by the moment of the day (contract § 12: a real video is shown
/// as it is); the moment only reaches the 3D scenes.
List<double> landscapeMatrix({double brightness = 1, double saturation = 1}) {
  var m = _identity;
  if (saturation != 1) m = _compose(_saturation(saturation), m);
  if (brightness != 1) {
    m = _compose(_gains(brightness, brightness, brightness, 0, 0, 0), m);
  }
  return m;
}

/// The poster of a landscape, cropped like `cover` (the dark placeholder until it is on the
/// phone).
class LandscapePoster extends StatelessWidget {
  const LandscapePoster({super.key, required this.landscapeId, this.thumbnail = false});

  final String landscapeId;

  /// Decoded at thumbnail size ([LandscapeImages.thumbnailFor]).
  final bool thumbnail;

  @override
  Widget build(BuildContext context) {
    final provider = thumbnail
        ? LandscapeImages.thumbnailFor(landscapeId)
        : LandscapeImages.providerFor(landscapeId);
    if (provider == null) return const LandscapePlaceholder();
    return Image(
      image: provider,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
      errorBuilder: (context, error, stack) => const LandscapePlaceholder(),
    );
  }
}

/// A landscape without its poster on the phone yet (Premium, not downloaded): a plain, dark
/// gradient. Drawn directly, nothing offscreen.
class LandscapePlaceholder extends StatelessWidget {
  const LandscapePlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF243530), Color(0xFF0E1714)],
        ),
      ),
      child: SizedBox.expand(),
    );
  }
}

/// Full-bleed landscape poster, with optional blur, dimming and slow Ken Burns motion (disabled
/// with reduced motion).
class LandscapeImage extends StatelessWidget {
  const LandscapeImage({
    super.key,
    required this.landscapeId,
    this.kenBurns = false,
    this.blurSigma = 0,
    this.brightness = 1,
    this.saturation = 1,
  });

  final String landscapeId;
  final bool kenBurns;
  final double blurSigma;
  final double brightness;
  final double saturation;

  @override
  Widget build(BuildContext context) {
    Widget picture = LandscapePoster(landscapeId: landscapeId);
    final matrix = landscapeMatrix(brightness: brightness, saturation: saturation);
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
