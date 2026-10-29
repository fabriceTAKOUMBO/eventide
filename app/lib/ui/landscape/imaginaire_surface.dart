// The WebView that runs the 3D scenes of « Imaginaire » (contract § 12). The runtime itself
// (`assets/imaginaire/`: index.html, runtime.js, scenes/<id>.js, vendor/three.min.js) is a
// separate, offline web page; this file only loads it and talks to it:
//
// - app → page: one call of `window.eventide` (`start`, `setDecor`, `setMoment`, `setPaused`,
//   `setQuality`, `dispose`), see [SceneCalls];
// - page → app: JSON messages on the JavaScript channel `EventideScene` (`ready`, `error`,
//   `stats`), parsed by [parseSceneMessage].
//
// The WebView is locked down: JavaScript on, nothing else. Only `file:///android_asset/` pages
// may load (every other navigation is refused), no file or content access, no zoom, no scroll
// bars or overscroll, no media without a gesture, no geolocation; it never receives a touch
// (IgnorePointer: the home screen's swipes stay Flutter's). Its renderer process is guarded
// natively (SceneWebViewGuard.kt): if it crashes or Android kills it, the app lives on and the
// scene falls back to its poster ([SceneGone]).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../../core/scene.dart' show Moment;

/// Something the scene page (or its WebView) says.
sealed class SceneEvent {
  const SceneEvent();
}

/// The runtime page finished loading: `window.eventide` can be called.
final class SceneLoaded extends SceneEvent {
  const SceneLoaded();
}

/// `{"type":"ready"}`: the first frame of the scene is drawn.
final class SceneReady extends SceneEvent {
  const SceneReady();
}

/// `{"type":"error","detail":"…"}`, or the page could not load.
final class SceneError extends SceneEvent {
  const SceneError(this.detail);

  final String detail;
}

/// `{"type":"stats","fps":n,"ms":n}`, every 10 s.
final class SceneStats extends SceneEvent {
  const SceneStats({required this.fps, required this.ms});

  final double fps;
  final double ms;
}

/// The WebView's renderer process is gone ([crashed]: it crashed; otherwise Android killed it
/// for memory). The WebView must not be used again.
final class SceneGone extends SceneEvent {
  const SceneGone({required this.crashed});

  final bool crashed;
}

/// Parses one message of the `EventideScene` channel; null for anything else.
SceneEvent? parseSceneMessage(String message) {
  Object? json;
  try {
    json = jsonDecode(message);
  } catch (_) {
    return null;
  }
  if (json is! Map) return null;
  switch (json['type']) {
    case 'ready':
      return const SceneReady();
    case 'error':
      final detail = json['detail'];
      return SceneError(detail is String && detail.isNotEmpty ? detail : 'erreur de la scène');
    case 'stats':
      final fps = json['fps'];
      final ms = json['ms'];
      if (fps is! num || !fps.isFinite) return null;
      return SceneStats(fps: fps.toDouble(), ms: ms is num && ms.isFinite ? ms.toDouble() : 0);
  }
  return null;
}

/// Rendering quality given to the runtime (`quality`).
enum SceneQuality { low, high }

/// The JavaScript of each call of the runtime API (arguments JSON-encoded: never raw text).
abstract final class SceneCalls {
  static String start(
    String sceneId, {
    required Map<String, int> decor,
    required Moment moment,
    required SceneQuality quality,
    int fps = 30,
  }) =>
      'eventide.start(${jsonEncode(sceneId)}, ${jsonEncode({
        'decor': decor,
        'moment': moment.name,
        'quality': quality.name,
        'fps': fps,
      })});';

  static String setDecor(String id, int level) =>
      'eventide.setDecor(${jsonEncode(id)}, ${level.clamp(0, 100)});';

  static String setMoment(Moment moment) => 'eventide.setMoment(${jsonEncode(moment.name)});';

  static String setPaused(bool paused) => 'eventide.setPaused($paused);';

  static String setQuality(SceneQuality quality) => 'eventide.setQuality(${jsonEncode(quality.name)});';

  static const String dispose = 'if (window.eventide) { eventide.dispose(); }';
}

/// What the 3D view drives: the WebView in the app, a fake in tests.
abstract class ImaginaireSurface {
  /// Events of the page and of the WebView, in order.
  Stream<SceneEvent> get events;

  /// Loads the runtime page. Failures arrive as [SceneError] (never thrown).
  Future<void> load();

  /// Runs one call of the runtime API (see [SceneCalls]). Never throws.
  Future<void> run(String javaScript);

  /// The scene's picture (no touch, no semantics).
  Widget view();

  /// Releases the WebView. Never throws.
  Future<void> dispose();
}

/// The real surface: a webview_flutter WebView on Android.
class WebViewSceneSurface implements ImaginaireSurface {
  WebViewSceneSurface({this.page = 'assets/imaginaire/index.html'});

  /// Flutter asset key of the runtime page.
  final String page;

  final StreamController<SceneEvent> _events = StreamController<SceneEvent>.broadcast();
  WebViewController? _controller;
  int? _identifier;
  bool _disposed = false;

  @override
  Stream<SceneEvent> get events => _events.stream;

  void _emit(SceneEvent event) {
    if (!_disposed && !_events.isClosed) _events.add(event);
  }

  /// Only the bundled runtime may load; no network, no other file.
  static bool isLocalPage(String url) => url.startsWith('file:///android_asset/');

  @override
  Future<void> load() async {
    try {
      final controller = WebViewController();
      _controller = controller;
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      // Opaque dark: the page paints black before its first frame; the poster stays on top
      // until `ready`.
      await controller.setBackgroundColor(const Color(0xFF000000));
      await controller.enableZoom(false);
      await controller.addJavaScriptChannel(
        'EventideScene',
        onMessageReceived: (message) {
          final event = parseSceneMessage(message.message);
          if (event != null) _emit(event);
        },
      );
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) =>
              isLocalPage(request.url) ? NavigationDecision.navigate : NavigationDecision.prevent,
          onPageFinished: (url) {
            if (isLocalPage(url)) _emit(const SceneLoaded());
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame ?? true) {
              _emit(SceneError('page non chargée (${error.errorCode} ${error.description})'));
            }
          },
        ),
      );
      final platform = controller.platform;
      if (platform is AndroidWebViewController) {
        await platform.setAllowFileAccess(false); // assets stay readable (file:///android_asset)
        await platform.setAllowContentAccess(false);
        await platform.setGeolocationEnabled(false);
        await platform.setMediaPlaybackRequiresUserGesture(true);
        await platform.setTextZoom(100);
        await platform.setVerticalScrollBarEnabled(false);
        await platform.setHorizontalScrollBarEnabled(false);
        await platform.setOverScrollMode(WebViewOverScrollMode.never);
        _identifier = platform.webViewIdentifier;
        // Without the native guard (Android 7, or the guard missing), a renderer crash would
        // kill the app: the scene stays a poster then.
        final guarded = await SceneRendererGuard.install(
          platform.webViewIdentifier,
          (crashed) => _emit(SceneGone(crashed: crashed)),
        );
        if (!guarded) {
          _emit(const SceneError('moteur de rendu non protégé sur ce téléphone'));
          return;
        }
      }
      if (_disposed) return;
      await controller.loadFlutterAsset(page);
    } catch (e) {
      _emit(SceneError('WebView indisponible ($e)'));
    }
  }

  @override
  Future<void> run(String javaScript) async {
    final controller = _controller;
    if (controller == null || _disposed) return;
    try {
      await controller.runJavaScript(javaScript);
    } catch (e) {
      debugPrint('Imaginaire: call failed ($e)');
    }
  }

  @override
  Widget view() {
    final controller = _controller;
    if (controller == null) return const SizedBox.shrink();
    return IgnorePointer(child: ExcludeSemantics(child: WebViewWidget(controller: controller)));
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final id = _identifier;
    if (id != null) SceneRendererGuard.remove(id);
    final controller = _controller;
    if (controller != null) {
      try {
        // Nothing left in the page: no frame, no timer, while the WebView goes.
        await controller.runJavaScript(SceneCalls.dispose);
        await controller.loadRequest(Uri.parse('about:blank'));
      } catch (_) {}
    }
    await _events.close();
  }
}

/// The native guard of the WebView's renderer process (SceneWebViewGuard.kt, channel
/// `be.cinaf.eventide/device`): webview_flutter_android does not handle
/// `onRenderProcessGone`, so without it Android would kill the whole app when the renderer
/// crashes or is reclaimed.
abstract final class SceneRendererGuard {
  static const MethodChannel _channel = MethodChannel('be.cinaf.eventide/device');
  static final Map<int, void Function(bool crashed)> _listeners = {};
  static bool _listening = false;

  /// Wraps the WebView [identifier]'s client natively. False when it could not be guarded
  /// (Android 7, no such WebView, no native side).
  static Future<bool> install(int identifier, void Function(bool crashed) onGone) async {
    if (!_listening) {
      _listening = true;
      _channel.setMethodCallHandler(_onCall);
    }
    _listeners[identifier] = onGone;
    try {
      final ok = await _channel.invokeMethod<bool>('guardSceneWebView', {'identifier': identifier});
      if (ok == true) return true;
    } catch (e) {
      debugPrint('Imaginaire: renderer guard unavailable ($e)');
    }
    _listeners.remove(identifier);
    return false;
  }

  static void remove(int identifier) => _listeners.remove(identifier);

  static Future<Object?> _onCall(MethodCall call) async {
    if (call.method != 'sceneRendererGone') return null;
    final args = call.arguments;
    if (args is! Map) return null;
    final id = args['identifier'];
    final listener = id is int ? _listeners.remove(id) : null;
    listener?.call(args['crashed'] == true);
    return null;
  }
}
