// Fakes of the native side of the problem report and of the landscape wallpaper.

import 'package:eventide/core/problem_report.dart';
import 'package:eventide/core/wallpaper.dart';
import 'package:eventide/services/diagnostics.dart';
import 'package:eventide/services/wallpaper_service.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeDeviceDiagnostics implements DeviceDiagnostics {
  List<AppExit> pending = [];
  int takes = 0;
  int installs = 0;
  DeviceDetails device = const DeviceDetails(packageName: 'be.cinaf.eventide', sdkInt: 35, model: 'SM-S921B');

  @override
  Future<List<AppExit>> takeNewExits() async {
    takes++;
    final out = pending;
    pending = [];
    return out;
  }

  @override
  Future<DeviceDetails> details() async => device;

  @override
  Future<void> installMediaSessionActivity() async => installs++;
}

class FakeWallpaperPlatform implements WallpaperPlatform {
  WallpaperSupport supported = const WallpaperSupport(liveWallpaper: true);
  String? selection;
  WallpaperResult answer = WallpaperResult.opened;
  final List<Map<String, Object?>> set = [];
  final List<bool> allowed = [];
  int clears = 0;

  @override
  Future<WallpaperSupport> support() async => supported;

  @override
  Future<String?> selectedLandscape() async => selection;

  @override
  Future<WallpaperResult> setLiveWallpaper({
    required String landscapeId,
    required String name,
    String? videoPath,
    String? posterPath,
    required bool allowed,
  }) async {
    set.add({'id': landscapeId, 'name': name, 'video': videoPath, 'poster': posterPath, 'allowed': allowed});
    return answer;
  }

  @override
  Future<void> setAllowed(bool allowed) async => this.allowed.add(allowed);

  @override
  Future<void> clearSelection() async => clears++;
}
