// Problem report on the phone: rotating log, error hooks, breadcrumbs, exits kept by the app,
// and the native channel's contract.
import 'dart:io';

import 'package:eventide/core/problem_report.dart';
import 'package:eventide/services/diagnostics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';

import 'device_fakes.dart';

AppExit _exit(ExitReason reason, DateTime at, {String? trace, int importance = 125}) =>
    AppExit(reason: reason, at: at, importance: importance, processName: 'be.cinaf.eventide', trace: trace);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  var clock = DateTime(2026, 10, 29, 21);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('eventide-diagnostics');
    clock = DateTime(2026, 10, 29, 21);
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  group('FileGuardStore (crash guard sentinels)', () {
    test('written synchronously and atomically, read back by the next process', () {
      final file = File('${dir.path}/diagnostics/guard.json');
      final store = FileGuardStore(file);
      expect(store.read(), isNull);
      store.write('{"starts":1}');
      expect(file.readAsStringSync(), '{"starts":1}');
      expect(File('${file.path}.tmp').existsSync(), isFalse);
      expect(FileGuardStore(file).read(), '{"starts":1}');
    });

    test('an unwritable place never throws', () {
      final store = FileGuardStore(File('/proc/eventide-no-such-dir/guard.json'));
      expect(() => store.write('{}'), returnsNormally);
      expect(store.read(), isNull);
    });
  });

  group('DiagnosticsLog', () {
    test('kept in memory until it has a folder, then written there and read back by a later run', () async {
      final log = DiagnosticsLog(now: () => clock);
      log.add('démarrage');
      await log.attach(dir);
      log.error('Erreur Flutter : boom', StackTrace.fromString('#0 main (file.dart:1)\n#1 run (file.dart:2)'));
      await log.flush();
      final file = File('${dir.path}/log.txt');
      expect(await file.exists(), isTrue);
      final text = await file.readAsString();
      expect(text, contains('I démarrage'));
      expect(text, contains('E Erreur Flutter : boom'));
      expect(text, contains('#1 run'));
      // The next run reads the lines of the run that crashed.
      final next = DiagnosticsLog(now: () => clock);
      await next.attach(dir);
      next.add('redémarrage');
      final lines = await next.storedLines();
      expect(lines.first, contains('démarrage'));
      expect(lines.last, contains('redémarrage'));
    });

    test('a durable line is on disk before add returns (it must survive a native crash right after)', () async {
      final log = DiagnosticsLog(maxFileBytes: 300, maxLinesPerMinute: 1000, now: () => clock);
      await log.attach(dir);
      log.addDurable('dessin : paysage lisiere 672×1456');
      // No await, no flush: read synchronously, as if the process had just died.
      final file = File('${dir.path}/log.txt');
      expect(file.readAsStringSync(), contains('I dessin : paysage lisiere 672×1456'));
      // It rolls over like the others.
      for (var i = 0; i < 12; i++) {
        log.addDurable('dessin : image de la carte n° $i');
      }
      expect(file.lengthSync(), lessThanOrEqualTo(300));
      expect(File('${dir.path}/log.1.txt').existsSync(), isTrue);
      expect((await log.storedLines()).last, contains('n° 11'));
    });

    test('two files at most: the oldest lines go first', () async {
      final log = DiagnosticsLog(maxFileBytes: 400, maxLinesPerMinute: 1000, now: () => clock);
      await log.attach(dir);
      for (var i = 0; i < 40; i++) {
        log.add('ligne numéro $i');
      }
      await log.flush();
      expect(await File('${dir.path}/log.txt').length(), lessThanOrEqualTo(400));
      expect(await File('${dir.path}/log.1.txt').length(), lessThanOrEqualTo(400));
      final lines = await log.storedLines();
      expect(lines.last, contains('ligne numéro 39'));
      expect(lines.any((l) => RegExp(r'ligne numéro 0$').hasMatch(l)), isFalse);
      expect(dir.listSync().whereType<File>().length, 2);
    });

    test('a repeated message is written once with its count; a flood is capped per minute', () async {
      final log = DiagnosticsLog(maxLinesPerMinute: 5, now: () => clock);
      for (var i = 0; i < 30; i++) {
        log.add('même erreur');
      }
      log.add('autre chose');
      expect(log.recent.where((l) => l.contains('même erreur')), hasLength(1));
      expect(log.recent.any((l) => l.contains('répété 29 fois')), isTrue);
      for (var i = 0; i < 20; i++) {
        log.add('message $i');
      }
      // 5 counted lines (the repeat summary is not counted): the rest is dropped.
      expect(log.recent.length, 6);
      expect(log.recent.last, contains('message 2'));
      clock = clock.add(const Duration(minutes: 1));
      log.add('une minute plus tard');
      expect(log.recent.any((l) => l.contains('lignes non enregistrées')), isTrue);
      expect(log.recent.last, contains('une minute plus tard'));
    });

    test('URL queries and e-mail addresses never reach the file', () async {
      final log = DiagnosticsLog(now: () => clock);
      await log.attach(dir);
      log.add('download https://cdn.test/v.mp4?Signature=secret by a@b.example');
      await log.flush();
      final text = await File('${dir.path}/log.txt').readAsString();
      expect(text, isNot(contains('secret')));
      expect(text, isNot(contains('a@b.example')));
    });

    test('clear forgets everything', () async {
      final log = DiagnosticsLog(now: () => clock);
      await log.attach(dir);
      log.add('x');
      await log.clear();
      expect(await log.storedLines(), isEmpty);
      expect(log.recent, isEmpty);
    });
  });

  test('error hooks: logged, then handed to the previous handlers (still printed)', () {
    final log = DiagnosticsLog(now: () => clock);
    final savedFlutter = FlutterError.onError;
    final savedDispatcher = PlatformDispatcher.instance.onError;
    final seen = <String>[];
    try {
      FlutterError.onError = (details) => seen.add('flutter:${details.exceptionAsString()}');
      PlatformDispatcher.instance.onError = (error, stack) {
        seen.add('dispatcher:$error');
        return false;
      };
      installErrorHooks(log);
      FlutterError.onError!(FlutterErrorDetails(exception: StateError('layout'), library: 'rendering'));
      final handled = PlatformDispatcher.instance.onError!(StateError('async'), StackTrace.empty);
      expect(handled, isFalse, reason: 'the engine still reports it (logcat, CI checks)');
      expect(seen, ['flutter:Bad state: layout', 'dispatcher:Bad state: async']);
      expect(log.recent.where((l) => l.contains(' E ')), hasLength(2));
      expect(log.recent.first, contains('Erreur Flutter : Bad state: layout (rendering)'));
      expect(log.recent.last, contains('Erreur Dart non rattrapée : Bad state: async'));
    } finally {
      FlutterError.onError = savedFlutter;
      PlatformDispatcher.instance.onError = savedDispatcher;
    }
  });

  test('session breadcrumbs: changes only, memory with the live video players', () {
    final log = DiagnosticsLog(now: () => clock);
    final crumbs = SessionBreadcrumbs(log: log, rss: () => 300 * 1024 * 1024, liveVideos: () => 1);
    crumbs.playback('lecture');
    crumbs.playback('lecture');
    crumbs.playback('pause');
    crumbs.landscape('cascade-foret');
    crumbs.landscape('cascade-foret');
    crumbs.lifecycle(AppLifecycleState.paused);
    crumbs.memory();
    expect(log.recent.map((l) => l.substring(24)), [
      'I son : lecture',
      'I son : pause',
      'I paysage : cascade-foret',
      'I application : paused',
      'I mémoire : 300 Mo (RSS), vidéos de paysage : 1',
    ]);
  });

  group('ProblemReports', () {
    test('exits from Android are kept on the phone, merged, newest first, traces on the newest only', () async {
      final device = FakeDeviceDiagnostics()
        ..pending = [
          for (var i = 0; i < 5; i++) _exit(ExitReason.anr, DateTime(2026, 10, 20 + i), trace: 'trace $i'),
          _exit(ExitReason.lowMemory, DateTime(2026, 10, 29, 22), importance: 400),
        ];
      final log = DiagnosticsLog(now: () => clock);
      final first = ProblemReports(device: device, log: log, directory: dir, keep: 5, keepTraces: 2);
      await first.load();
      expect(first.exits, hasLength(5));
      expect(first.exits.first.reason, ExitReason.lowMemory);
      expect(first.exits.where((e) => e.trace != null).map((e) => e.trace), ['trace 4', 'trace 3']);
      expect(first.lastAbnormal!.at, DateTime(2026, 10, 24));
      expect(log.recent.where((l) => l.contains('arrêt précédent anormal')), hasLength(5));

      // Next start: Android gives only what is new; the kept ones are read back.
      device.pending = [_exit(ExitReason.crashNative, DateTime(2026, 10, 30, 7), trace: 'libflutter.so')];
      final second = ProblemReports(device: device, log: log, directory: dir, keep: 5, keepTraces: 2);
      await second.load();
      expect(second.exits.first.reason, ExitReason.crashNative);
      expect(second.exits, hasLength(5));
      expect(second.lastAbnormal!.reason, ExitReason.crashNative);
      expect(device.takes, 2);
    });

    test('report: phone, exits and the log of earlier runs; clear forgets them', () async {
      final device = FakeDeviceDiagnostics()..pending = [_exit(ExitReason.crash, DateTime(2026, 10, 29, 21, 40))];
      final log = DiagnosticsLog(now: () => clock);
      await log.attach(dir);
      log.add('son : lecture');
      final reports = ProblemReports(device: device, log: log, directory: dir, now: () => clock);
      final text = await reports.report();
      expect(text, contains('SM-S921B'));
      expect(text, contains('Plantage (erreur Java ou Kotlin)'));
      expect(text, contains('son : lecture'));
      await reports.clear();
      expect(reports.exits, isEmpty);
      expect(await File('${dir.path}/exits.json').exists(), isFalse);
      expect(await log.storedLines(), isEmpty);
    });

    test('an unreadable file or a native failure never breaks the app', () async {
      await File('${dir.path}/exits.json').writeAsString('{not json');
      final reports = ProblemReports(device: _ThrowingDevice(), log: DiagnosticsLog(), directory: dir);
      await reports.load();
      expect(reports.exits, isEmpty);
      expect(reports.lastAbnormal, isNull);
    });
  });

  group('native channel be.cinaf.eventide/device', () {
    const channel = MethodChannel(MethodChannelDeviceDiagnostics.deviceChannelName);
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('exits, details and the media card intent', () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return switch (call.method) {
          'takeExitReasons' => [
            {'reason': 5, 'timestamp': 1761772440000, 'importance': 100, 'process': 'be.cinaf.eventide'},
            'ignored',
          ],
          'deviceDetails' => {'model': 'SM-S921B', 'sdk_int': 35, 'android_release': '15', 'low_ram': false},
          'installMediaSessionActivity' => true,
          _ => null,
        };
      });
      final native = MethodChannelDeviceDiagnostics();
      final exits = await native.takeNewExits();
      expect(exits.single.reason, ExitReason.crashNative);
      expect(exits.single.abnormal, isTrue);
      final details = await native.details();
      expect(details.model, 'SM-S921B');
      expect(details.sdkInt, 35);
      await native.installMediaSessionActivity();
      expect(calls, ['takeExitReasons', 'deviceDetails', 'installMediaSessionActivity']);
    });

    test('no native side (other platform, old engine): empty answers', () async {
      final native = MethodChannelDeviceDiagnostics();
      expect(await native.takeNewExits(), isEmpty);
      expect((await native.details()).model, '');
      await native.installMediaSessionActivity();
    });
  });
}

class _ThrowingDevice implements DeviceDiagnostics {
  @override
  Future<List<AppExit>> takeNewExits() => Future.error(StateError('native'));

  @override
  Future<DeviceDetails> details() => Future.error(StateError('native'));

  @override
  Future<void> installMediaSessionActivity() async {}
}
