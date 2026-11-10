// Crash-loop guard (docs/app/architecture.md § 19).
//
// A native crash (GPU driver, plugin) kills the process: no Dart error handler runs, so the only
// trace it can leave is what was written *before* the risky work. One sentinel, written
// synchronously to a small file:
//
// - start: set just before the first landscape is shown, cleared once the app has run stably
//   ([CrashGuard.stableAfter] in the foreground) or went to the background normally. Still set at
//   the next start: the previous start died, so this one is a safe start (the controller goes
//   back to the default free landscape and forgets the landscapes being browsed).
//
// The sentinel of the live 3D scenes (a WebView rendering WebGL in the app's process) is gone
// with them (contract § 12, 10 November 2026: the « Imaginaire » landscapes are videos); what an
// older version wrote for it is ignored.
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

  /// App version: a new build starts with a clean state.
  final String build;

  /// Breadcrumbs of the problem report (written durably by the app: they must survive the crash).
  final void Function(String message)? log;

  final Duration stableAfter;

  bool get enabled => store != null;

  int _unfinishedStarts = 0;
  bool _safeStart = false;
  bool _uiStarted = false;
  bool _stable = false;
  Timer? _stableTimer;

  /// The previous start died before running stably: start on the default landscape.
  bool get safeStart => _safeStart;

  /// Starts that showed a landscape and were not yet confirmed stable (this one included).
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
    }
    _safeStart = _unfinishedStarts > 0;
    if (_safeStart) {
      log?.call(
        'démarrage protégé : le lancement précédent s’est arrêté avant 20 s '
        '($_unfinishedStarts fois de suite) ; retour au paysage par défaut',
      );
    }
    _save();
  }

  /// The first landscape is about to be shown: this start counts as unfinished until
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
        'version': 3,
        'build': build,
        'starts': _unfinishedStarts,
      }));
    } catch (_) {
      // A full storage never breaks the app; the guard is best effort.
    }
  }
}
