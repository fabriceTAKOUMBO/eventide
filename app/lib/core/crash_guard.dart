// Crash-loop guard (docs/app/architecture.md § 19).
//
// A native crash (GPU driver, plugin) kills the process: no Dart error handler runs, so the only
// trace it can leave is what was written *before* the risky work. Two sentinels, written
// synchronously to a small file:
//
// - start: set just before the first landscape is shown, cleared once the app has run stably
//   ([CrashGuard.stableAfter] in the foreground) or went to the background normally. Still set at
//   the next start: the previous start died, so this one is a safe start (the controller goes
//   back to the default free landscape and forgets the landscapes being browsed).
// - live work ([beginLive]): set while a 3D scene renders live in its WebView (Android
//   WebView runs its GPU work, WebGL included, in the app's own process: a GPU driver crash
//   there kills the app), cleared when it pauses or goes. Still set at the next start: that
//   scene is shown as its still picture from then on (until the app or the scene runtime
//   changes). The 2D procedural landscapes that used it before are gone (contract § 12).
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

/// Risky native work in progress (a live 3D scene): what it is, its subject (the scene id) and
/// a detail for the log (quality).
typedef GuardedWork = ({String what, String subject, String detail});

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

  /// App version and scene runtime version: a new build tries every scene live again.
  final String build;

  /// Breadcrumbs of the problem report (written durably by the app: they must survive the crash).
  final void Function(String message)? log;

  final Duration stableAfter;

  bool get enabled => store != null;

  int _unfinishedStarts = 0;
  bool _safeStart = false;
  final Set<String> _dead = {};
  final List<GuardedWork> _interrupted = [];
  final Map<int, GuardedWork> _live = {};
  int _nextToken = 1;
  bool _uiStarted = false;
  bool _stable = false;
  Timer? _stableTimer;

  /// The previous start died before running stably: start on the default landscape.
  bool get safeStart => _safeStart;

  /// Subjects (3D scene ids) whose live work was interrupted by a crash: shown as their still
  /// picture.
  Set<String> get deadSubjects => Set.unmodifiable(_dead);

  bool isDead(String subject) => _dead.contains(subject);

  /// Live work in progress when the previous run died (oldest first).
  List<GuardedWork> get interrupted => List.unmodifiable(_interrupted);

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
      final dead = state['dead'];
      if (dead is List) _dead.addAll(dead.whereType<String>());
      final live = state['live'];
      if (live is List) {
        for (final d in live) {
          if (d is! Map || d['subject'] is! String) continue;
          final entry = (what: '${d['what'] ?? ''}', subject: d['subject'] as String, detail: '${d['detail'] ?? ''}');
          _interrupted.add(entry);
          _dead.add(entry.subject);
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
        'lancement précédent arrêté pendant : ${d.what} ${d.subject} ${d.detail} ; '
        'ce paysage sera montré en image fixe',
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

  /// Marks risky live work as in progress (and notes it in the log). Returns the token for
  /// [endLive].
  int beginLive(String what, String subject, String detail) {
    log?.call('en direct : $what $subject $detail');
    if (!enabled) return 0;
    final token = _nextToken++;
    _live[token] = (what: what, subject: subject, detail: detail);
    _save();
    return token;
  }

  void endLive(int token) {
    if (_live.remove(token) != null) _save();
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
        'version': 2,
        'build': build,
        'starts': _unfinishedStarts,
        'dead': [..._dead],
        'live': [
          for (final d in _live.values) {'what': d.what, 'subject': d.subject, 'detail': d.detail},
        ],
      }));
    } catch (_) {
      // A full storage never breaks the app; the guard is best effort.
    }
  }
}
