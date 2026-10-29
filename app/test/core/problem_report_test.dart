// Problem report: Android's exit reasons, what counts as abnormal, and the shared text.
import 'package:eventide/core/problem_report.dart';
import 'package:flutter_test/flutter_test.dart';

AppExit _exit(
  ExitReason reason, {
  int importance = ProcessImportance.foregroundService,
  DateTime? at,
  String process = 'be.cinaf.eventide.demo',
  String? trace,
}) => AppExit(
  reason: reason,
  at: at ?? DateTime(2026, 10, 29, 22, 14),
  importance: importance,
  processName: process,
  trace: trace,
  pssKb: 512000,
  rssKb: 640000,
);

void main() {
  group('exit reasons', () {
    test('Android codes map to reasons, unknown codes to « inconnue »', () {
      expect(ExitReason.fromCode(4), ExitReason.crash);
      expect(ExitReason.fromCode(5), ExitReason.crashNative);
      expect(ExitReason.fromCode(6), ExitReason.anr);
      expect(ExitReason.fromCode(3), ExitReason.lowMemory);
      expect(ExitReason.fromCode(9), ExitReason.excessiveResourceUsage);
      expect(ExitReason.fromCode(16), ExitReason.packageUpdated);
      expect(ExitReason.fromCode(99), ExitReason.unknown);
      for (final r in ExitReason.values) {
        expect(r.label, isNotEmpty);
      }
    });

    test('crashes and ANRs are always abnormal, whatever the app was doing', () {
      for (final r in [ExitReason.crash, ExitReason.crashNative, ExitReason.anr, ExitReason.initializationFailure]) {
        expect(_exit(r, importance: ProcessImportance.cached).abnormal, isTrue, reason: r.name);
      }
    });

    test('a kill by the system is abnormal only while the app was in use', () {
      expect(_exit(ExitReason.lowMemory, importance: ProcessImportance.foreground).abnormal, isTrue);
      expect(_exit(ExitReason.lowMemory, importance: ProcessImportance.foregroundService).abnormal, isTrue);
      expect(_exit(ExitReason.signaled, importance: ProcessImportance.perceptible).abnormal, isTrue);
      expect(_exit(ExitReason.excessiveResourceUsage, importance: ProcessImportance.visible).abnormal, isTrue);
      // Idle in the background: Android's routine housekeeping.
      expect(_exit(ExitReason.lowMemory, importance: ProcessImportance.cached).abnormal, isFalse);
      expect(_exit(ExitReason.other, importance: 400).abnormal, isFalse);
      expect(_exit(ExitReason.other, importance: 0).abnormal, isFalse, reason: 'unknown importance');
    });

    test('what the user asked for, or an update, is never a problem', () {
      for (final r in [
        ExitReason.exitSelf,
        ExitReason.userRequested,
        ExitReason.userStopped,
        ExitReason.permissionChange,
        ExitReason.packageUpdated,
        ExitReason.packageStateChange,
      ]) {
        expect(_exit(r, importance: ProcessImportance.foreground).abnormal, isFalse, reason: r.name);
      }
    });

    test('native map and JSON round trip', () {
      final e = AppExit.fromJson({
        'reason': 5,
        'status': 11,
        'timestamp': DateTime(2026, 10, 29, 22, 14).millisecondsSinceEpoch,
        'importance': 125,
        'pss_kb': 812345,
        'rss_kb': 900000,
        'description': 'crash',
        'process': 'be.cinaf.eventide',
        'trace': 'libflutter.so',
        'trace_truncated': true,
      });
      expect(e.reason, ExitReason.crashNative);
      expect(e.status, 11);
      expect(e.importance, 125);
      expect(e.trace, 'libflutter.so');
      expect(e.traceTruncated, isTrue);
      final back = AppExit.fromJson(e.toJson());
      expect(back.toJson(), e.toJson());
      expect(e.withoutTrace().trace, isNull);
      // Lenient: missing fields.
      final bare = AppExit.fromJson({'reason': 6});
      expect(bare.reason, ExitReason.anr);
      expect(bare.description, isNull);
      expect(bare.processName, '');
    });
  });

  group('summary', () {
    test('the latest abnormal exit, in French', () {
      final exits = [
        _exit(ExitReason.lowMemory, importance: ProcessImportance.cached, at: DateTime(2026, 10, 29, 23)),
        _exit(ExitReason.crashNative, at: DateTime(2026, 10, 29, 22, 14)),
        _exit(ExitReason.anr, at: DateTime(2026, 10, 28, 8, 5)),
      ];
      final last = lastAbnormalExit(exits)!;
      expect(last.reason, ExitReason.crashNative);
      expect(exitSummary(last), 'Plantage natif (moteur, son ou vidéo), le 29 octobre à 22 h 14');
      expect(lastAbnormalExit(const []), isNull);
      expect(
        exitSummary(_exit(ExitReason.anr, process: 'be.cinaf.eventide:wallpaper', at: DateTime(2026, 1, 3, 7, 5))),
        'Application figée (ANR) (fond d’écran animé), le 3 janvier à 7 h 05',
      );
    });

    test('log lines lose e-mail addresses and URL queries (signed links)', () {
      expect(
        redactLogLine('GET https://cdn.example/videos/a.mp4?Signature=abc&Key-Pair-Id=K failed for jean@example.com'),
        'GET https://cdn.example/videos/a.mp4?… failed for <adresse masquée>',
      );
      expect(redactLogLine('plain line'), 'plain line');
    });
  });

  group('report', () {
    test('app, phone, exits, traces and recent log, newest exit first', () {
      final text = buildProblemReport(
        device: const DeviceDetails(
          appVersion: '1.0.0',
          buildNumber: '1',
          packageName: 'be.cinaf.eventide.demo',
          androidRelease: '15',
          sdkInt: 35,
          manufacturer: 'samsung',
          model: 'SM-S921B',
          totalMemoryMb: 7600,
        ),
        exits: [
          _exit(ExitReason.anr, at: DateTime(2026, 10, 28, 8, 5), trace: '----- pid 123 -----\n"main" prio=5'),
          _exit(ExitReason.crashNative, at: DateTime(2026, 10, 29, 22, 14)),
        ],
        logLines: ['2026-10-29 21:50:00.000 I son : lecture', 'E https://x.test/a?token=1'],
        now: DateTime(2026, 10, 30, 9),
      );
      expect(text, contains('be.cinaf.eventide.demo version 1.0.0 (1)'));
      expect(text, contains('Android : 15 (API 35)'));
      expect(text, contains('Appareil : samsung SM-S921B'));
      expect(text, contains('7600 Mo'));
      expect(text.indexOf('29 octobre à 22 h 14'), lessThan(text.indexOf('28 octobre à 8 h 05')));
      expect(text, contains('ANORMAL'));
      expect(text, contains('mémoire PSS 500 Mo'));
      expect(text, contains('== Trace : Application figée (ANR), 28 octobre à 8 h 05 =='));
      expect(text, contains('"main" prio=5'));
      expect(text, contains('son : lecture'));
      expect(text, contains('https://x.test/a?…'));
      expect(text, isNot(contains('token=1')));
      expect(text, contains('aucune donnée personnelle'));
    });

    test('Android 10 and older: no exit record, said plainly; empty log', () {
      final text = buildProblemReport(
        device: const DeviceDetails(sdkInt: 29),
        exits: const [],
        logLines: const [],
        now: DateTime(2026, 10, 30, 9),
      );
      expect(text, contains('Android 10 et plus ancien ne les fournit pas'));
      expect(text, contains('(vide)'));
    });

    test('only the newest log lines are kept', () {
      final text = buildProblemReport(
        device: DeviceDetails.unknown,
        exits: const [],
        logLines: [for (var i = 0; i < 50; i++) 'ligne $i'],
        now: DateTime(2026, 10, 30, 9),
        maxLogLines: 10,
      );
      expect(text, contains('ligne 49'));
      expect(text, contains('ligne 40'));
      expect(text, isNot(contains('ligne 39\n')));
      expect(text, contains('Aucun arrêt relevé.'));
    });
  });
}
