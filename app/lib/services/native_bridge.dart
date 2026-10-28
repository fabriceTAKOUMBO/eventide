// Dart side of the Kotlin method channel `be.cinaf.eventide/native`
// (android/app/src/main/kotlin/be/cinaf/eventide/NativeBridgePlugin.kt).
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// How the next scheduled start is armed on the phone.
enum AlarmMode {
  /// `AlarmManager.setAlarmClock`: on time, and allowed to start the audio service.
  exact,

  /// `setAndAllowWhileIdle`: may be late; Android will likely refuse the background start,
  /// so the fallback « Lancer » notification is shown instead.
  inexact,

  /// Nothing to arm (no active schedule).
  none,
}

class AlarmSyncResult {
  const AlarmSyncResult({required this.mode, this.nextAt});

  final AlarmMode mode;
  final DateTime? nextAt;
}

class NetworkInfo {
  const NetworkInfo({required this.connected, required this.unmetered});

  final bool connected;

  /// Wi-Fi or Ethernet (used by « Téléchargements en Wi-Fi seulement »).
  final bool unmetered;
}

abstract class NativeBridge {
  /// Stores the schedules natively and (re)arms one alarm for the next occurrence.
  /// [payloadJson]: `{"schedules": [<contract § 2 + "paysage_nom">], "requires_network": bool}`.
  Future<AlarmSyncResult> syncSchedules(String payloadJson);

  Future<bool> canScheduleExactAlarms();

  /// Opens « Alarmes et rappels » for this app (Android 12+). False if nothing was opened.
  Future<bool> openExactAlarmSettings();

  /// Schedule id recorded by the alarm receiver (or the « Lancer » action), then cleared.
  Future<String?> consumePendingStart();

  Future<String> androidId();

  /// Play Integrity token (classic request) for [nonce].
  Future<String> requestIntegrityToken(String nonce, {String? cloudProjectNumber});

  Future<void> showNoConnectionNotification();

  /// Opens the app details screen, from which the user reaches battery settings.
  Future<void> openBatteryOptimizationGuide();

  /// Coarse connectivity from Android (null if unknown).
  Future<NetworkInfo?> networkStatus();

  /// « Lancer » tapped on the fallback notification while the app was running.
  Stream<void> get launchScheduleRequests;

  /// True only in the Android demo build (`-Peventide.demo=true`, manifest flag). False when
  /// the native side does not answer.
  Future<bool> isDemoBuild();
}

class MethodChannelNativeBridge implements NativeBridge {
  MethodChannelNativeBridge({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('be.cinaf.eventide/native') {
    _channel.setMethodCallHandler(_onCall);
  }

  final MethodChannel _channel;
  final _launchRequests = StreamController<void>.broadcast();

  Future<dynamic> _onCall(MethodCall call) async {
    if (call.method == 'launchSchedule') _launchRequests.add(null);
    return null;
  }

  Future<T?> _invoke<T>(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      // Engine started without our plugin (should not happen) or a non-Android platform.
      return null;
    } on PlatformException catch (e) {
      debugPrint('NativeBridge.$method: ${e.code} ${e.message}');
      return null;
    }
  }

  @override
  Future<AlarmSyncResult> syncSchedules(String payloadJson) async {
    final result = await _invoke<Map<Object?, Object?>>('syncSchedules', payloadJson);
    if (result == null) return const AlarmSyncResult(mode: AlarmMode.none);
    final mode = switch (result['mode']) {
      'exact' => AlarmMode.exact,
      'inexact' => AlarmMode.inexact,
      _ => AlarmMode.none,
    };
    final next = result['next_at'];
    return AlarmSyncResult(
      mode: mode,
      nextAt: next is int ? DateTime.fromMillisecondsSinceEpoch(next) : null,
    );
  }

  @override
  Future<bool> canScheduleExactAlarms() async => await _invoke<bool>('canScheduleExactAlarms') ?? false;

  @override
  Future<bool> openExactAlarmSettings() async => await _invoke<bool>('openExactAlarmSettings') ?? false;

  @override
  Future<String?> consumePendingStart() => _invoke<String>('consumePendingStart');

  @override
  Future<String> androidId() async => await _invoke<String>('androidId') ?? '';

  @override
  Future<String> requestIntegrityToken(String nonce, {String? cloudProjectNumber}) async {
    try {
      final token = await _channel.invokeMethod<String>('requestIntegrityToken', {
        'nonce': nonce,
        if (cloudProjectNumber != null && cloudProjectNumber.isNotEmpty) 'cloudProjectNumber': cloudProjectNumber,
      });
      if (token == null || token.isEmpty) throw StateError('empty integrity token');
      return token;
    } on MissingPluginException {
      throw StateError('Play Integrity unavailable');
    }
  }

  @override
  Future<void> showNoConnectionNotification() => _invoke<bool>('showNoConnectionNotification');

  @override
  Future<void> openBatteryOptimizationGuide() => _invoke<bool>('openBatteryOptimizationGuide');

  @override
  Future<NetworkInfo?> networkStatus() async {
    final result = await _invoke<Map<Object?, Object?>>('networkStatus');
    if (result == null) return null;
    return NetworkInfo(connected: result['connected'] == true, unmetered: result['unmetered'] == true);
  }

  @override
  Stream<void> get launchScheduleRequests => _launchRequests.stream;

  @override
  Future<bool> isDemoBuild() async => await _invoke<bool>('isDemoBuild') ?? false;
}
