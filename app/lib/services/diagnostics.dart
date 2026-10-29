// Problem report kept on the phone (docs/app/architecture.md « Rapport de problème »).
//
// - DiagnosticsLog: the app's own errors (Flutter, uncaught Dart) and a few breadcrumbs useful
//   after a crash (start, landscape, video players, playback, memory), in a small rotating
//   file (two files of [DiagnosticsLog.maxFileBytes] at most) that survives the crash.
// - DeviceDiagnostics: the native side (channel be.cinaf.eventide/device): process exits
//   recorded by Android (ApplicationExitInfo, Android 11+, each one given once), phone model.
// - ProblemReports: keeps the last exits on the phone and builds the plain-text report.
//
// Nothing leaves the phone unless the user shares the report; no account, no identifier.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;

import '../core/problem_report.dart';

/// Rotating log of the app: recent lines in memory, and in `log.txt` (rolled over to
/// `log.1.txt` past [maxFileBytes]) once [attach] gave it a folder.
class DiagnosticsLog {
  DiagnosticsLog({
    this.maxFileBytes = 160 * 1024,
    this.memoryLines = 300,
    this.maxLinesPerMinute = 120,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final int maxFileBytes;
  final int memoryLines;

  /// An error repeated every frame must not fill the log (nor wear the storage).
  final int maxLinesPerMinute;
  final DateTime Function() _now;

  final List<String> _recent = [];
  final List<String> _unwritten = [];
  Directory? _directory;
  Future<void> _queue = Future.value();
  int? _size;

  String? _lastMessage;
  int _repeats = 0;
  DateTime? _minuteStart;
  int _minuteCount = 0;
  int _dropped = 0;

  File? get _file => _directory == null ? null : File('${_directory!.path}/log.txt');
  File? get _previous => _directory == null ? null : File('${_directory!.path}/log.1.txt');

  /// Lines of this run, newest last (memory only).
  List<String> get recent => List.unmodifiable(_recent);

  /// Gives the log its folder: lines written so far are flushed there.
  Future<void> attach(Directory directory) {
    _directory = directory;
    final pending = [..._unwritten];
    _unwritten.clear();
    _queue = _queue.then((_) async {
      try {
        await directory.create(recursive: true);
        final file = _file!;
        _size = await file.exists() ? await file.length() : 0;
        for (final line in pending) {
          await _append(line);
        }
      } catch (e) {
        debugPrint('DiagnosticsLog: cannot open its folder ($e)');
      }
    });
    return _queue;
  }

  void info(String message) => add(message);

  void error(String message, [StackTrace? stack]) {
    final frames = stack == null
        ? ''
        : '\n${stack.toString().split('\n').where((l) => l.trim().isNotEmpty).take(14).map((l) => '    $l').join('\n')}';
    add('$message$frames', level: 'E');
  }

  void add(String message, {String level = 'I'}) {
    final text = redactLogLine(message.trimRight());
    if (text == _lastMessage) {
      _repeats++;
      return;
    }
    final now = _now();
    if (_repeats > 0) {
      _write(now, 'I', '(message précédent répété $_repeats fois)');
      _repeats = 0;
    }
    _lastMessage = text;
    final start = _minuteStart;
    if (start == null || now.difference(start) >= const Duration(minutes: 1)) {
      if (_dropped > 0) _write(now, 'I', '($_dropped lignes non enregistrées : trop de messages)');
      _minuteStart = now;
      _minuteCount = 0;
      _dropped = 0;
    }
    if (_minuteCount >= maxLinesPerMinute) {
      _dropped++;
      return;
    }
    _minuteCount++;
    _write(now, level, text);
  }

  void _write(DateTime at, String level, String text) {
    final line = '${_stamp(at)} $level $text';
    _recent.add(line);
    if (_recent.length > memoryLines) _recent.removeRange(0, _recent.length - memoryLines);
    if (_directory == null) {
      _unwritten.add(line);
      if (_unwritten.length > memoryLines) _unwritten.removeAt(0);
      return;
    }
    _queue = _queue.then((_) => _append(line));
  }

  Future<void> _append(String line) async {
    final file = _file;
    if (file == null) return;
    try {
      final bytes = utf8.encode('$line\n');
      var size = _size ?? (await file.exists() ? await file.length() : 0);
      if (size + bytes.length > maxFileBytes && size > 0) {
        final previous = _previous!;
        if (await previous.exists()) await previous.delete();
        await file.rename(previous.path);
        size = 0;
      }
      await file.writeAsBytes(bytes, mode: FileMode.append);
      _size = size + bytes.length;
    } catch (_) {
      // A full or read-only storage never breaks the app.
      _size = null;
    }
  }

  /// Every line kept on the phone (earlier runs included), oldest first.
  Future<List<String>> storedLines() async {
    await _queue;
    final lines = <String>[];
    for (final file in [_previous, _file]) {
      if (file == null) continue;
      try {
        if (await file.exists()) {
          lines.addAll(
            const LineSplitter().convert(utf8.decode(await file.readAsBytes(), allowMalformed: true)),
          );
        }
      } catch (_) {}
    }
    if (_directory == null) lines.addAll(_recent);
    return lines;
  }

  Future<void> flush() => _queue;

  /// Data deletion: forgets every line.
  Future<void> clear() async {
    _recent.clear();
    _unwritten.clear();
    await _queue;
    for (final file in [_previous, _file]) {
      try {
        if (file != null && await file.exists()) await file.delete();
      } catch (_) {}
    }
    _size = 0;
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _stamp(DateTime t) {
    final l = t.toLocal();
    final ms = l.millisecond.toString().padLeft(3, '0');
    return '${l.year}-${_two(l.month)}-${_two(l.day)} ${_two(l.hour)}:${_two(l.minute)}:${_two(l.second)}.$ms';
  }
}

/// The app's log, reachable from anywhere (video players, controller). Memory only until the
/// bootstrap attaches its folder; tests keep the default.
abstract final class Breadcrumbs {
  static DiagnosticsLog log = DiagnosticsLog();

  static void add(String message) => log.add(message);
}

/// Routes the app's errors to [log], then to whoever handled them before: Flutter still
/// prints its errors and the engine still reports uncaught ones (logcat, CI emulator checks).
/// No guarded zone: errors would then stop reaching PlatformDispatcher.onError and logcat.
void installErrorHooks(DiagnosticsLog log) {
  final previousFlutter = FlutterError.onError;
  FlutterError.onError = (details) {
    log.error('Erreur Flutter : ${details.exceptionAsString()}${details.library == null ? '' : ' (${details.library})'}', details.stack);
    (previousFlutter ?? FlutterError.presentError)(details);
  };
  final dispatcher = PlatformDispatcher.instance;
  final previous = dispatcher.onError;
  dispatcher.onError = (error, stack) {
    log.error('Erreur Dart non rattrapée : $error', stack);
    // false: not handled here, the engine reports it as before.
    return previous?.call(error, stack) ?? false;
  };
}

/// Breadcrumbs of a listening session (what matters after a crash 30 minutes in).
class SessionBreadcrumbs {
  SessionBreadcrumbs({
    required this.log,
    this.memoryEvery = const Duration(minutes: 5),
    int Function()? rss,
    int Function()? liveVideos,
  }) : _rss = rss ?? (() => ProcessInfo.currentRss),
       _liveVideos = liveVideos ?? (() => 0);

  final DiagnosticsLog log;
  final Duration memoryEvery;
  final int Function() _rss;
  final int Function() _liveVideos;
  Timer? _timer;
  String? _playback;
  String? _landscape;
  AppLifecycleState? _lifecycle;

  void start() {
    _timer ??= Timer.periodic(memoryEvery, (_) => memory());
    memory();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void memory() {
    try {
      log.add('mémoire : ${(_rss() / (1024 * 1024)).round()} Mo (RSS), vidéos de paysage : ${_liveVideos()}');
    } catch (_) {}
  }

  /// `playing`, `paused`, `loading` or `stopped`.
  void playback(String state) {
    if (state == _playback) return;
    _playback = state;
    log.add('son : $state');
  }

  void landscape(String id) {
    if (id == _landscape) return;
    _landscape = id;
    log.add('paysage : $id');
  }

  void lifecycle(AppLifecycleState state) {
    if (state == _lifecycle) return;
    _lifecycle = state;
    log.add('application : ${state.name}');
  }
}

/// Native side of the problem report and of the media card's launch intent.
abstract class DeviceDiagnostics {
  /// Process exits recorded by Android since the previous call (each one is given once).
  /// Empty below Android 11.
  Future<List<AppExit>> takeNewExits();

  Future<DeviceDetails> details();

  /// Gives the media session our own « open the app » intent, before the session is active
  /// (lock screen card, docs/app/architecture.md § 15.3). Safe to call again.
  Future<void> installMediaSessionActivity();
}

class MethodChannelDeviceDiagnostics implements DeviceDiagnostics {
  MethodChannelDeviceDiagnostics({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(deviceChannelName);

  static const String deviceChannelName = 'be.cinaf.eventide/device';

  final MethodChannel _channel;

  Future<T?> _invoke<T>(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      debugPrint('DeviceDiagnostics.$method: ${e.code} ${e.message}');
      return null;
    }
  }

  @override
  Future<List<AppExit>> takeNewExits() async {
    final list = await _invoke<List<Object?>>('takeExitReasons');
    if (list == null) return const [];
    return [
      for (final item in list)
        if (item is Map) AppExit.fromJson(item),
    ];
  }

  @override
  Future<DeviceDetails> details() async {
    final map = await _invoke<Map<Object?, Object?>>('deviceDetails');
    return map == null ? DeviceDetails.unknown : DeviceDetails.fromJson(map);
  }

  @override
  Future<void> installMediaSessionActivity() => _invoke<bool>('installMediaSessionActivity');
}

/// Exits kept on the phone (`exits.json`, the [keep] newest, traces on the newest only) and the
/// report built from them and from the log.
class ProblemReports {
  ProblemReports({
    required this.device,
    required this.log,
    this.directory,
    this.keep = 12,
    this.keepTraces = 3,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final DeviceDiagnostics device;
  final DiagnosticsLog log;
  final Directory? directory;
  final int keep;
  final int keepTraces;
  final DateTime Function() _now;

  List<AppExit> _exits = const [];
  DeviceDetails _details = DeviceDetails.unknown;
  Future<void>? _loading;

  File? get _file => directory == null ? null : File('${directory!.path}/exits.json');

  /// Newest first.
  List<AppExit> get exits => _exits;

  AppExit? get lastAbnormal => lastAbnormalExit(_exits);

  /// Reads the kept exits, adds the ones Android recorded since last time, saves them.
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    final stored = await _read();
    List<AppExit> fresh = const [];
    try {
      fresh = await device.takeNewExits();
    } catch (e) {
      debugPrint('ProblemReports: exits unavailable ($e)');
    }
    try {
      _details = await device.details();
    } catch (_) {}
    for (final e in fresh) {
      if (e.abnormal) log.add('Android : arrêt précédent anormal : ${exitSummary(e)}');
    }
    _exits = _merge(stored, fresh);
    if (fresh.isNotEmpty) await _save();
  }

  List<AppExit> _merge(List<AppExit> a, List<AppExit> b) {
    String key(AppExit e) => '${e.at.millisecondsSinceEpoch}|${e.reason.code}|${e.processName}';
    final byKey = <String, AppExit>{for (final e in a) key(e): e};
    for (final e in b) {
      byKey[key(e)] = e;
    }
    final all = byKey.values.toList()..sort((x, y) => y.at.compareTo(x.at));
    final kept = all.take(keep).toList();
    var traces = 0;
    return [
      for (final e in kept)
        if (e.trace != null && traces++ >= keepTraces) e.withoutTrace() else e,
    ];
  }

  Future<List<AppExit>> _read() async {
    final file = _file;
    if (file == null) return const [];
    try {
      if (!await file.exists()) return const [];
      final json = jsonDecode(await file.readAsString());
      final list = json is Map ? json['exits'] : null;
      if (list is! List) return const [];
      return [
        for (final item in list)
          if (item is Map) AppExit.fromJson(item),
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<void> _save() async {
    final file = _file;
    if (file == null) return;
    try {
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.part');
      await tmp.writeAsString(
        jsonEncode({'version': 1, 'exits': [for (final e in _exits) e.toJson()]}),
        flush: true,
      );
      await tmp.rename(file.path);
    } catch (e) {
      debugPrint('ProblemReports: cannot save ($e)');
    }
  }

  /// The plain-text report (« Signaler un problème »).
  Future<String> report() async {
    await load();
    return buildProblemReport(
      device: _details,
      exits: _exits,
      logLines: await log.storedLines(),
      now: _now(),
    );
  }

  /// Data deletion.
  Future<void> clear() async {
    _exits = const [];
    try {
      final file = _file;
      if (file != null && await file.exists()) await file.delete();
    } catch (_) {}
    await log.clear();
  }
}
