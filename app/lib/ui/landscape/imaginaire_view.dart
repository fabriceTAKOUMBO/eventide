// A 3D scene of « Imaginaire » (contract § 12), drawn live by the runtime in a WebView
// (imaginaire_surface.dart), shown like a living landscape: never a player, never a black frame.
//
// - Poster first: the scene's still picture (its frame at t = 0) stays on top until the page
//   says `ready` (first frame drawn), then fades away. Without the runtime, with « réduire les
//   animations », after an error, or for a scene the crash guard marked: the poster only.
// - Live only when seen: the scene's view is on screen (no other screen on top: TickerMode),
//   the app in the foreground and [ImaginaireView.live] set (the incoming landscape of a swipe
//   is a poster; the live scene starts when the swipe settles). Covered (another screen, the
//   black standby screen), inactive, in background or screen off: paused (`setPaused(true)`:
//   the render loop stops, the last frame stays), then released after
//   [ImaginaireView.releaseWhenCovered] (20 s), like the videos.
// - One live WebView at most in the whole app ([Imaginaire]): a newer live view takes it, the
//   older one goes back to its poster.
// - Never a crash of the app: an `error` message, a page that does not load or is not ready in
//   [Imaginaire.readyTimeout], or a renderer process that dies (guarded natively) put the poster
//   back and write a line in the problem report; that scene stays a poster until the app starts
//   again. Android WebView runs its GPU work in the app's process, so while a scene runs live it
//   is marked by the crash guard (CrashGuard.beginLive): if a native crash kills the app then,
//   that scene is shown as its poster from the next start on.
import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../core/crash_guard.dart';
import '../../core/scene.dart' show Moment;
import '../theme/vitre.dart';
import 'imaginaire_surface.dart';
import 'landscape_image.dart';

/// Version of the app ↔ runtime contract (crash guard key: a new one tries every scene live
/// again).
const int kImaginaireRuntimeVersion = 1;

/// What a 3D view shows now.
enum ImaginairePhase {
  /// Poster only, no WebView.
  poster,

  /// WebView created, page loading or scene starting: the poster is still on top.
  loading,

  /// The scene runs and is seen.
  live,

  /// The scene is paused on its last frame (covered, in background).
  paused,
}

/// Shared state of the 3D views.
abstract final class Imaginaire {
  /// Makes the WebView (tests set a fake).
  static ImaginaireSurface Function() surfaceFactory = WebViewSceneSurface.new;

  /// Breadcrumbs of the problem report (set by the bootstrap).
  static void Function(String message) log = _noLog;

  /// A page that has not said `ready` after this long is given up (poster).
  static Duration readyTimeout = const Duration(seconds: 12);

  /// Below this frame rate (`stats`), the scene is asked for its low quality.
  static const double lowFps = 20;

  /// Scenes that failed during this run: poster until the app starts again.
  static final Set<String> failedThisRun = {};

  static ImaginaireViewState? _live;

  /// Number of live WebViews (0 or 1).
  static int get liveCount => _live == null ? 0 : 1;

  static void _noLog(String message) {}

  @visibleForTesting
  static void debugReset() {
    failedThisRun.clear();
    _live = null;
    readyTimeout = const Duration(seconds: 12);
  }
}

class ImaginaireView extends StatefulWidget {
  const ImaginaireView({
    super.key,
    required this.sceneId,
    required this.poster,
    this.decor = const {},
    this.moment = Moment.jour,
    this.live = true,
    this.releaseWhenCovered = const Duration(seconds: 20),
  });

  final String sceneId;

  /// The scene's still picture, shown until the first frame and whenever it is not live.
  final Widget poster;

  /// Decor elements and their levels (0–100); only those the scene allows (the caller filters).
  final Map<String, int> decor;
  final Moment moment;

  /// May run live (false: poster only, e.g. the incoming landscape during a swipe).
  final bool live;

  /// A covered or backgrounded scene stays paused this long (coming back shows the same frame),
  /// then its WebView is released.
  final Duration releaseWhenCovered;

  @override
  State<ImaginaireView> createState() => ImaginaireViewState();
}

class ImaginaireViewState extends State<ImaginaireView> with WidgetsBindingObserver {
  ImaginaireSurface? _surface;
  StreamSubscription<SceneEvent>? _events;
  ImaginairePhase _phase = ImaginairePhase.poster;
  bool _started = false;
  bool _ready = false;
  bool _paused = false;
  int _guardToken = 0;
  SceneQuality _quality = SceneQuality.high;
  Timer? _coveredTimer;
  Timer? _readyTimer;
  AppLifecycleState _lifecycle = AppLifecycleState.resumed;
  bool _visible = true;
  bool _reduced = false;

  /// What the view shows now (tests).
  @visibleForTesting
  ImaginairePhase get phase => _phase;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lifecycle = WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
    LandscapeImages.revision.addListener(_onAssets);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = TickerMode.valuesOf(context).enabled;
    _reduced = Vitre.reduceMotion(context);
    _sync();
  }

  @override
  void didUpdateWidget(ImaginaireView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sceneId != widget.sceneId) {
      _release();
    } else if (_started) {
      _applyChanges(oldWidget);
    }
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == _lifecycle) return;
    _lifecycle = state;
    _sync();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    LandscapeImages.revision.removeListener(_onAssets);
    _release(rebuild: false);
    super.dispose();
  }

  void _onAssets() {
    if (!mounted) return;
    _sync();
    _rebuild();
  }

  bool get _wanted =>
      widget.live &&
      !_reduced &&
      LandscapeImages.hasSceneRuntime &&
      !CrashGuard.current.isDead(widget.sceneId) &&
      !Imaginaire.failedThisRun.contains(widget.sceneId);

  bool get _seen => _visible && _lifecycle == AppLifecycleState.resumed;

  /// Creates, resumes, pauses or releases the scene to match the conditions.
  void _sync() {
    if (!_wanted) {
      _release();
      return;
    }
    if (_surface == null) {
      // Never a WebView that would not be seen.
      if (_seen) _create();
      return;
    }
    if (_seen) {
      _coveredTimer?.cancel();
      _coveredTimer = null;
      _resume();
    } else {
      _pause();
      _coveredTimer ??= Timer(widget.releaseWhenCovered, () {
        _coveredTimer = null;
        _release();
      });
    }
  }

  void _create() {
    // One live WebView in the whole app: the previous owner goes back to its poster.
    final previous = Imaginaire._live;
    if (previous != null && previous != this) previous._release();
    Imaginaire._live = this;
    final surface = Imaginaire.surfaceFactory();
    _surface = surface;
    _started = false;
    _ready = false;
    _paused = false;
    _quality = SceneQuality.high;
    _phase = ImaginairePhase.loading;
    _events = surface.events.listen(_onEvent);
    _readyTimer = Timer(Imaginaire.readyTimeout, () {
      _readyTimer = null;
      _fail('pas prête après ${Imaginaire.readyTimeout.inSeconds} s');
    });
    Imaginaire.log('scène 3D : ouverture ${widget.sceneId}');
    unawaited(surface.load());
    _rebuild();
  }

  void _onEvent(SceneEvent event) {
    if (!mounted || _surface == null) return;
    switch (event) {
      case SceneLoaded():
        if (!_started) _start();
      case SceneReady():
        _readyTimer?.cancel();
        _readyTimer = null;
        if (!_ready) Imaginaire.log('scène 3D : ${widget.sceneId} prête');
        _ready = true;
        _phase = _paused ? ImaginairePhase.paused : ImaginairePhase.live;
        _rebuild();
      case SceneError(:final detail):
        _fail(detail);
      case SceneGone(:final crashed):
        if (crashed) {
          _fail('moteur de rendu planté');
        } else {
          // Reclaimed by Android (memory): not the scene's fault, it may come back later.
          Imaginaire.log('scène 3D : ${widget.sceneId}, moteur de rendu libéré par Android');
          _release();
        }
      case SceneStats(:final fps):
        if (fps < Imaginaire.lowFps && _quality == SceneQuality.high) {
          _quality = SceneQuality.low;
          Imaginaire.log('scène 3D : ${widget.sceneId} à ${fps.round()} i/s, qualité basse');
          _run(SceneCalls.setQuality(SceneQuality.low));
        }
    }
  }

  void _start() {
    _started = true;
    _guardToken = CrashGuard.current.beginLive('scène 3D', widget.sceneId, _quality.name);
    _run(SceneCalls.start(widget.sceneId, decor: widget.decor, moment: widget.moment, quality: _quality));
    if (!_seen) _pause();
  }

  void _pause() {
    if (!_started || _paused) return;
    _paused = true;
    _run(SceneCalls.setPaused(true));
    CrashGuard.current.endLive(_guardToken);
    if (_phase == ImaginairePhase.live) _phase = ImaginairePhase.paused;
    _rebuild();
  }

  void _resume() {
    if (!_started || !_paused) return;
    _paused = false;
    _guardToken = CrashGuard.current.beginLive('scène 3D', widget.sceneId, _quality.name);
    _run(SceneCalls.setPaused(false));
    if (_phase == ImaginairePhase.paused) _phase = ImaginairePhase.live;
    _rebuild();
  }

  void _applyChanges(ImaginaireView old) {
    for (final entry in widget.decor.entries) {
      if (old.decor[entry.key] != entry.value) _run(SceneCalls.setDecor(entry.key, entry.value));
    }
    for (final id in old.decor.keys) {
      if (!widget.decor.containsKey(id)) _run(SceneCalls.setDecor(id, 0));
    }
    if (old.moment != widget.moment) _run(SceneCalls.setMoment(widget.moment));
  }

  void _run(String javaScript) {
    final surface = _surface;
    if (surface != null) unawaited(surface.run(javaScript));
  }

  /// The scene cannot run: its poster until the app starts again, and a line in the report.
  void _fail(String detail) {
    Imaginaire.failedThisRun.add(widget.sceneId);
    Imaginaire.log('scène 3D : ${widget.sceneId} en image fixe ($detail)');
    _release();
  }

  /// Back to the poster: the WebView goes.
  void _release({bool rebuild = true}) {
    _coveredTimer?.cancel();
    _coveredTimer = null;
    _readyTimer?.cancel();
    _readyTimer = null;
    final surface = _surface;
    if (surface == null) return;
    _surface = null;
    unawaited(_events?.cancel());
    _events = null;
    if (_started && !_paused) CrashGuard.current.endLive(_guardToken);
    _started = false;
    _ready = false;
    _paused = false;
    _phase = ImaginairePhase.poster;
    if (Imaginaire._live == this) Imaginaire._live = null;
    unawaited(surface.dispose());
    if (rebuild) _rebuild();
  }

  /// Rebuilds now, or after the frame when called while widgets are being built (an older live
  /// view evicted by a newer one is a sibling being built in the same frame).
  void _rebuild() {
    if (!mounted) return;
    final scheduler = SchedulerBinding.instance;
    if (scheduler.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      scheduler.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
      scheduler.ensureVisualUpdate();
      return;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final surface = _surface;
    final showScene = surface != null && _ready;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (surface != null) Positioned.fill(child: surface.view()),
        IgnorePointer(
          child: AnimatedOpacity(
            key: const ValueKey('imaginaire-poster'),
            opacity: showScene ? 0 : 1,
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeOut,
            child: widget.poster,
          ),
        ),
      ],
    );
  }
}
