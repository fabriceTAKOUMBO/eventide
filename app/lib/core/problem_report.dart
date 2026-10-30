// Problem report kept on the phone (docs/app/architecture.md « Rapport de problème »): why
// Android ended the app's processes (ApplicationExitInfo, Android 11+), and the plain-text
// report the user may share. Pure Dart: no plugin, no personal data (no account, no
// identifier, no listening history; URLs and e-mail addresses are masked in log lines).
import 'format.dart' show formatClock;

/// Why Android ended a process of the app: `ApplicationExitInfo.REASON_*` codes.
enum ExitReason {
  unknown(0),
  exitSelf(1),
  signaled(2),
  lowMemory(3),
  crash(4),
  crashNative(5),
  anr(6),
  initializationFailure(7),
  permissionChange(8),
  excessiveResourceUsage(9),
  userRequested(10),
  userStopped(11),
  dependencyDied(12),
  other(13),
  freezer(14),
  packageStateChange(15),
  packageUpdated(16);

  const ExitReason(this.code);

  final int code;

  static ExitReason fromCode(int code) {
    for (final r in values) {
      if (r.code == code) return r;
    }
    return unknown;
  }

  /// Short French label (Settings, report).
  String get label => switch (this) {
    unknown => 'Arrêt pour une raison inconnue',
    exitSelf => 'Fermeture normale',
    signaled => 'Arrêtée par un signal du système',
    lowMemory => 'Arrêtée par Android : mémoire insuffisante',
    crash => 'Plantage (erreur Java ou Kotlin)',
    crashNative => 'Plantage natif (moteur, son ou vidéo)',
    anr => 'Application figée (ANR)',
    initializationFailure => 'Échec au démarrage',
    permissionChange => 'Arrêtée après un changement d’autorisation',
    excessiveResourceUsage => 'Arrêtée par Android : trop de ressources utilisées',
    userRequested => 'Arrêtée à la demande de l’utilisateur',
    userStopped => 'Arrêt forcé depuis les Paramètres',
    dependencyDied => 'Arrêtée : un composant dont elle dépend s’est arrêté',
    other => 'Arrêtée par le système',
    freezer => 'Arrêtée pendant qu’Android la gelait',
    packageStateChange => 'Arrêtée : application désactivée ou modifiée',
    packageUpdated => 'Mise à jour de l’application',
  };

  /// Always a fault of the app, whatever it was doing.
  bool get isFailure => this == crash || this == crashNative || this == anr || this == initializationFailure;

  /// Asked by the user or part of an update: never shown as a problem.
  bool get isExpected =>
      this == exitSelf ||
      this == userRequested ||
      this == userStopped ||
      this == permissionChange ||
      this == packageStateChange ||
      this == packageUpdated;
}

/// `ActivityManager.RunningAppProcessInfo.IMPORTANCE_*` thresholds.
abstract final class ProcessImportance {
  static const int foreground = 100;
  static const int foregroundService = 125;
  static const int visible = 200;
  static const int perceptible = 230;
  static const int service = 300;
  static const int cached = 400;

  static String label(int importance) {
    if (importance <= 0) return 'inconnu';
    if (importance <= foreground) return 'au premier plan (à l’écran)';
    if (importance <= foregroundService) return 'service au premier plan (son en cours)';
    if (importance <= visible) return 'visible';
    if (importance <= perceptible) return 'perceptible (son en cours)';
    if (importance < cached) return 'service en arrière-plan';
    return 'en arrière-plan, inactive';
  }
}

/// One process exit recorded by Android (`ApplicationExitInfo`), as sent by the native side.
class AppExit {
  const AppExit({
    required this.reason,
    required this.at,
    this.status = 0,
    this.importance = 0,
    this.pssKb = 0,
    this.rssKb = 0,
    this.description,
    this.processName = '',
    this.trace,
    this.traceTruncated = false,
  });

  final ExitReason reason;
  final DateTime at;

  /// Exit status or signal number (`getStatus`).
  final int status;

  /// Importance of the process when it died (lower is more important).
  final int importance;

  /// Last known memory of the process, in kilobytes (0 when unknown).
  final int pssKb;
  final int rssKb;

  /// Android's own words (`getDescription`), English, possibly null.
  final String? description;

  /// `be.cinaf.eventide` (the app) or `be.cinaf.eventide:wallpaper` (the live wallpaper).
  final String processName;

  /// ANR traces or the printable part of a native crash tombstone, truncated.
  final String? trace;
  final bool traceTruncated;

  /// A problem worth reporting: a crash or an ANR, or a kill by the system while the app was
  /// in use (on screen, playing sound, or a live wallpaper on screen). Android routinely ends
  /// idle background processes: those are not problems.
  bool get abnormal {
    if (reason.isFailure) return true;
    if (reason.isExpected) return false;
    return importance > 0 && importance < ProcessImportance.cached;
  }

  static int _int(Object? v) => v is int ? v : (v is num ? v.toInt() : 0);

  /// From the native map (`timestamp` in epoch milliseconds) or from [toJson].
  factory AppExit.fromJson(Map<Object?, Object?> json) {
    final trace = json['trace'];
    final description = json['description'];
    return AppExit(
      reason: ExitReason.fromCode(_int(json['reason'])),
      at: DateTime.fromMillisecondsSinceEpoch(_int(json['timestamp'])),
      status: _int(json['status']),
      importance: _int(json['importance']),
      pssKb: _int(json['pss_kb']),
      rssKb: _int(json['rss_kb']),
      description: description is String && description.isNotEmpty ? description : null,
      processName: json['process'] is String ? json['process'] as String : '',
      trace: trace is String && trace.isNotEmpty ? trace : null,
      traceTruncated: json['trace_truncated'] == true,
    );
  }

  Map<String, Object?> toJson() => {
    'reason': reason.code,
    'timestamp': at.millisecondsSinceEpoch,
    'status': status,
    'importance': importance,
    'pss_kb': pssKb,
    'rss_kb': rssKb,
    if (description != null) 'description': description,
    'process': processName,
    if (trace != null) 'trace': trace,
    if (traceTruncated) 'trace_truncated': true,
  };

  /// Without its trace (older reports are kept short).
  AppExit withoutTrace() => AppExit(
    reason: reason,
    at: at,
    status: status,
    importance: importance,
    pssKb: pssKb,
    rssKb: rssKb,
    description: description,
    processName: processName,
  );
}

/// What the report says about the phone and the app (no identifier of any kind).
class DeviceDetails {
  const DeviceDetails({
    this.appVersion = '',
    this.buildNumber = '',
    this.packageName = '',
    this.androidRelease = '',
    this.sdkInt = 0,
    this.manufacturer = '',
    this.model = '',
    this.totalMemoryMb = 0,
    this.lowRamDevice = false,
  });

  final String appVersion;
  final String buildNumber;
  final String packageName;
  final String androidRelease;
  final int sdkInt;
  final String manufacturer;
  final String model;
  final int totalMemoryMb;
  final bool lowRamDevice;

  static const DeviceDetails unknown = DeviceDetails();

  factory DeviceDetails.fromJson(Map<Object?, Object?> json) {
    String s(String key) => json[key] is String ? json[key] as String : '';
    int i(String key) => json[key] is int ? json[key] as int : 0;
    return DeviceDetails(
      appVersion: s('app_version'),
      buildNumber: s('build_number'),
      packageName: s('package'),
      androidRelease: s('android_release'),
      sdkInt: i('sdk_int'),
      manufacturer: s('manufacturer'),
      model: s('model'),
      totalMemoryMb: i('total_memory_mb'),
      lowRamDevice: json['low_ram'] == true,
    );
  }
}

const List<String> _monthNames = [
  'janvier',
  'février',
  'mars',
  'avril',
  'mai',
  'juin',
  'juillet',
  'août',
  'septembre',
  'octobre',
  'novembre',
  'décembre',
];

/// « 29 octobre à 22 h 14 » (local time).
String formatExitDate(DateTime at) {
  final l = at.toLocal();
  return '${l.day} ${_monthNames[l.month - 1]} à ${formatClock(l.hour, l.minute)}';
}

/// One line for Settings: « Plantage natif (moteur, son ou vidéo), le 29 octobre à 22 h 14 ».
String exitSummary(AppExit exit) {
  final wallpaper = exit.processName.endsWith(':wallpaper') ? ' (fond d’écran animé)' : '';
  return '${exit.reason.label}$wallpaper, le ${formatExitDate(exit.at)}';
}

/// The latest abnormal exit, or null.
AppExit? lastAbnormalExit(Iterable<AppExit> exits) {
  AppExit? last;
  for (final e in exits) {
    if (e.abnormal && (last == null || e.at.isAfter(last.at))) last = e;
  }
  return last;
}

final RegExp _urlQuery = RegExp(r'(https?://[^\s?#]+)[?#][^\s]*');
final RegExp _email = RegExp(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}');

/// Masks what could identify someone or unlock content in a log line: e-mail addresses, and
/// the query of URLs (signed content links carry their signature there).
String redactLogLine(String line) => line
    .replaceAllMapped(_urlQuery, (m) => '${m[1]}?…')
    .replaceAll(_email, '<adresse masquée>');

/// Plain-text report shared by « Signaler un problème ». [logLines] are the app's own recent
/// log lines (errors and breadcrumbs), newest last.
String buildProblemReport({
  required DeviceDetails device,
  required List<AppExit> exits,
  required List<String> logLines,
  required DateTime now,
  int maxLogLines = 400,
}) {
  final b = StringBuffer()
    ..writeln('Full Relax — rapport de problème')
    ..writeln('Créé le ${formatExitDate(now)} (heure du téléphone, ${_offset(now)})')
    ..writeln('Ce rapport ne contient aucune donnée personnelle : ni compte, ni identifiant, ni historique d’écoute.')
    ..writeln()
    ..writeln('== Application et téléphone ==')
    ..writeln(
      'Application : ${device.packageName.isEmpty ? '?' : device.packageName} '
      '${device.appVersion.isEmpty ? '' : 'version ${device.appVersion}'}'
      '${device.buildNumber.isEmpty ? '' : ' (${device.buildNumber})'}',
    )
    ..writeln(
      'Android : ${device.androidRelease.isEmpty ? '?' : device.androidRelease}'
      '${device.sdkInt > 0 ? ' (API ${device.sdkInt})' : ''}',
    )
    ..writeln('Appareil : ${[device.manufacturer, device.model].where((s) => s.isNotEmpty).join(' ')}')
    ..writeln(
      'Mémoire du téléphone : ${device.totalMemoryMb > 0 ? '${device.totalMemoryMb} Mo' : '?'}'
      '${device.lowRamDevice ? ' (appareil à mémoire réduite)' : ''}',
    )
    ..writeln();

  final sorted = [...exits]..sort((a, b) => b.at.compareTo(a.at));
  b.writeln('== Arrêts de l’application relevés par Android ==');
  if (device.sdkInt > 0 && device.sdkInt < 30) {
    b.writeln('(Android 10 et plus ancien ne les fournit pas.)');
  } else if (sorted.isEmpty) {
    b.writeln('Aucun arrêt relevé.');
  }
  for (final e in sorted) {
    b
      ..writeln('- ${formatExitDate(e.at)} · ${e.reason.label}${e.abnormal ? ' · ANORMAL' : ''}')
      ..writeln(
        '  processus ${e.processName.isEmpty ? '?' : e.processName}, état : ${ProcessImportance.label(e.importance)}'
        ' (${e.importance}), code ${e.reason.code}, statut ${e.status}'
        '${e.pssKb > 0 ? ', mémoire PSS ${(e.pssKb / 1024).round()} Mo' : ''}'
        '${e.rssKb > 0 ? ', RSS ${(e.rssKb / 1024).round()} Mo' : ''}',
      );
    if (e.description != null) b.writeln('  Android : ${e.description}');
  }
  for (final e in sorted) {
    final trace = e.trace;
    if (trace == null) continue;
    b
      ..writeln()
      ..writeln('== Trace : ${e.reason.label}, ${formatExitDate(e.at)}${e.traceTruncated ? ' (tronquée)' : ''} ==')
      ..writeln(trace.trimRight());
  }
  b
    ..writeln()
    ..writeln('== Journal récent de l’application ==');
  final lines = logLines.length > maxLogLines ? logLines.sublist(logLines.length - maxLogLines) : logLines;
  if (lines.isEmpty) b.writeln('(vide)');
  for (final line in lines) {
    b.writeln(redactLogLine(line));
  }
  return b.toString();
}

String _offset(DateTime now) {
  final o = now.toLocal().timeZoneOffset;
  final sign = o.isNegative ? '−' : '+';
  final minutes = o.inMinutes.abs();
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return 'UTC$sign$h${m == 0 ? '' : ':${m.toString().padLeft(2, '0')}'}';
}
