// Crash-loop guard (docs/app/architecture.md § 19).
//
// A native crash (GPU driver, plugin) kills the process: no Dart error handler runs, so the only
// trace it can leave is what was written *before* the risky work. Two sentinels, written
// synchronously to a small file:
//
// - start: set just before the first landscape is drawn, cleared once the app has run stably
//   ([CrashGuard.stableAfter] in the foreground) or went to the background normally. Still set at
//   the next start: the previous start died, so this one is a safe start (the controller goes
//   back to the default free landscape and forgets the landscapes being browsed).
// - drawing: set before an offscreen drawing of a procedural landscape (full screen, thumbnail,
//   media card picture), cleared once done. Still set at the next start: that style is drawn
//   with the simplified picture from then on (until the app or the painter changes).
//
// Pure Dart: the storage is given ([GuardStore]); tests use [MemoryGuardStore].
import 'dart:async';
import 'dart:convert';

/// Where the guard keeps its state. Synchronous on purpose: the sentinel must be on disk before
/// the risky work starts, since nothing runs after a native crash.
abstract interface class GuardStore {
  String? read();
  void write(String content);
}

class MemoryGuardStore implements GuardStore {
  MemoryGuardStore([this.content]);

  String? content;
  int writes = 0;

  @override
  String? read() => content;

  @override
  void write(String content) {
    writes++;
    this.content = content;
  }
}

/// An offscreen drawing in progress.
typedef GuardedDrawing = ({String what, String style, String detail});

class CrashGuard {
  CrashGuard({
    this.store,
    this.build = '',
    this.log,
    this.stableAfter = const Duration(seconds: 20),
  });

  /// The app's guard (set by the bootstrap). The default one is inert (tests, previews):
  /// nothing is stored, nothing is ever marked, no timer.
  static CrashGuard current = CrashGuard();

  final GuardStore? store;

  /// App version and painter version: a new build tries every style again.
  final String build;

  /// Breadcrumbs of the problem report (written durably by the app: they must survive the crash).
  final void Function(String message)? log;

  final Duration stableAfter;

  bool get enabled => store != null;

  int _unfinishedStarts = 0;
  bool _safeStart = false;
  final Set<String> _dead = {};
  final List<GuardedDrawing> _interrupted = [];
  final Map<int, GuardedDrawing> _drawings = {};
  int _nextToken = 1;
  bool _uiStarted = false;
  bool _stable = false;
  Timer? _stableTimer;

  /// The previous start died before running stably: start on the default landscape.
  bool get safeStart => _safeStart;

  /// Styles whose drawing was interrupted by a crash: drawn simplified.
  Set<String> get deadStyles => Set.unmodifiable(_dead);

  bool isDead(String style) => _dead.contains(style);

  /// Drawings in progress when the previous run died (oldest first).
  List<GuardedDrawing> get interrupted => List.unmodifiable(_interrupted);

  /// Starts that began drawing and were not yet confirmed stable (this one included).
  int get unfinishedStarts => _unfinishedStarts;

  /// Reads what the previous run left. Call once, before the scene is loaded.
  void load() {
    final store = this.store;
    if (store == null) return;
    Object? state;
    try {
      final content = store.read();
      state = content == null ? null : jsonDecode(content);
    } catch (_) {
      state = null;
    }
    if (state is Map && state['build'] == build) {
      final starts = state['starts'];
      _unfinishedStarts = starts is int && starts > 0 ? starts : 0;
      final dead = state['dead'];
      if (dead is List) _dead.addAll(dead.whereType<String>());
      final drawing = state['drawing'];
      if (drawing is List) {
        for (final d in drawing) {
          if (d is! Map || d['style'] is! String) continue;
          final entry = (what: '${d['what'] ?? ''}', style: d['style'] as String, detail: '${d['detail'] ?? ''}');
          _interrupted.add(entry);
          _dead.add(entry.style);
        }
      }
    }
    _safeStart = _unfinishedStarts > 0;
    if (_safeStart) {
      log?.call(
        'démarrage protégé : le lancement précédent s’est arrêté avant 20 s '
        '($_unfinishedStarts fois de suite) ; retour au paysage par défaut',
      );
    }
    for (final d in _interrupted) {
      log?.call(
        'lancement précédent arrêté pendant : ${d.what} ${d.style} ${d.detail} ; '
        'ce paysage sera dessiné en version simplifiée',
      );
    }
    _save();
  }

  /// The first landscape is about to be drawn: this start counts as unfinished until
  /// [markStable] (called by itself after [stableAfter]).
  void uiStarting() {
    if (!enabled || _uiStarted) return;
    _uiStarted = true;
    _unfinishedStarts++;
    _save();
    _stableTimer = Timer(stableAfter, markStable);
  }

  /// The app ran stably (or reached the background normally): the start is over.
  void markStable() {
    _stableTimer?.cancel();
    _stableTimer = null;
    if (!enabled || !_uiStarted || _stable) return;
    _stable = true;
    _unfinishedStarts = 0;
    _save();
  }

  /// Marks an offscreen drawing as in progress (and notes it in the log). Returns the token
  /// for [endDrawing].
  int beginDrawing(String what, String style, String detail) {
    log?.call('dessin : $what $style $detail');
    if (!enabled) return 0;
    final token = _nextToken++;
    _drawings[token] = (what: what, style: style, detail: detail);
    _save();
    return token;
  }

  void endDrawing(int token) {
    if (_drawings.remove(token) != null) _save();
  }

  /// Stops the timer (tests).
  void dispose() {
    _stableTimer?.cancel();
    _stableTimer = null;
  }

  void _save() {
    final store = this.store;
    if (store == null) return;
    try {
      store.write(jsonEncode({
        'version': 1,
        'build': build,
        'starts': _unfinishedStarts,
        'dead': [..._dead],
        'drawing': [
          for (final d in _drawings.values) {'what': d.what, 'style': d.style, 'detail': d.detail},
        ],
      }));
    } catch (_) {
      // A full storage never breaks the app; the guard is best effort.
    }
  }
}
