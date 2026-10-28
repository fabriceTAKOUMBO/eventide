// Runtime permissions. The UI always explains first (dossier, screen 1: nothing is asked at
// launch); these calls only happen after that explanation.
import 'package:permission_handler/permission_handler.dart';

import '../app/app_model.dart' show PermissionKind;
import 'native_bridge.dart';

abstract class Permissions {
  Future<bool> isGranted(PermissionKind kind);

  /// Asks Android. For exact alarms this opens the system screen and returns the state at once
  /// (the controller checks again when the app comes back).
  Future<bool> request(PermissionKind kind);

  /// Denied for good (« Ne plus demander », or refused twice): [request] would show nothing.
  /// Never true for exact alarms, which are granted from a settings screen anyway.
  Future<bool> isPermanentlyDenied(PermissionKind kind);

  /// Opens this app's page in Android settings. False if nothing was opened.
  Future<bool> openSettings();
}

class PlatformPermissions implements Permissions {
  PlatformPermissions(this._native);

  final NativeBridge _native;

  @override
  Future<bool> isGranted(PermissionKind kind) async {
    try {
      return switch (kind) {
        PermissionKind.microphone => await Permission.microphone.isGranted,
        PermissionKind.notifications => await Permission.notification.isGranted,
        PermissionKind.exactAlarm => await _native.canScheduleExactAlarms(),
      };
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> request(PermissionKind kind) async {
    try {
      switch (kind) {
        case PermissionKind.microphone:
          return (await Permission.microphone.request()).isGranted;
        case PermissionKind.notifications:
          return (await Permission.notification.request()).isGranted;
        case PermissionKind.exactAlarm:
          if (await _native.canScheduleExactAlarms()) return true;
          await _native.openExactAlarmSettings();
          return false;
      }
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> isPermanentlyDenied(PermissionKind kind) async {
    try {
      return switch (kind) {
        PermissionKind.microphone => await Permission.microphone.isPermanentlyDenied,
        PermissionKind.notifications => await Permission.notification.isPermanentlyDenied,
        PermissionKind.exactAlarm => false,
      };
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> openSettings() async {
    try {
      return await openAppSettings();
    } catch (_) {
      return false;
    }
  }
}
