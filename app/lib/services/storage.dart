// Small versioned JSON files in the app support directory. Local first: nothing here is sent
// to the server. Each file is `{"version": n, "data": ...}` and is written atomically
// (temporary file, flush, rename), so a crash or a power cut never leaves half a file.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// File names, one per kind of data.
abstract final class StoreKeys {
  static const scene = 'scene';
  static const schedules = 'schedules';
  static const favorites = 'favorites';
  static const settings = 'settings';
  static const nights = 'nights';
  static const entitlements = 'entitlements';
  static const installation = 'installation';

  /// Small UI/app state: last landscape per theme, onboarding, ad caps, open night.
  static const appState = 'app_state';

  static const all = [scene, schedules, favorites, settings, nights, entitlements, installation, appState];
}

class LocalStore {
  LocalStore(this.directory);

  final Directory directory;
  final Map<String, Future<void>> _queues = {};

  /// Current file format version. Readers accept older versions and migrate in code.
  static const int formatVersion = 1;

  File _file(String name) => File('${directory.path}/$name.json');

  /// Reads the `data` of a file, or null if missing or unreadable.
  Future<Object?> read(String name) async {
    await (_queues[name] ?? Future<void>.value());
    final file = _file(name);
    try {
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map && decoded.containsKey('data')) return decoded['data'];
      return null;
    } catch (e) {
      debugPrint('LocalStore: unreadable $name ($e)');
      return null;
    }
  }

  Future<Map<String, dynamic>?> readMap(String name) async {
    final data = await read(name);
    return data is Map ? Map<String, dynamic>.from(data) : null;
  }

  Future<List<Map<String, dynamic>>> readList(String name) async {
    final data = await read(name);
    if (data is! List) return const [];
    return [
      for (final e in data)
        if (e is Map) Map<String, dynamic>.from(e),
    ];
  }

  /// Writes [data] (JSON-encodable) atomically. Writes to the same file are serialized.
  Future<void> write(String name, Object? data, {int version = formatVersion}) {
    final previous = _queues[name] ?? Future<void>.value();
    final next = previous.then((_) => _writeNow(name, data, version)).catchError((Object e) {
      debugPrint('LocalStore: write $name failed ($e)');
    });
    _queues[name] = next;
    return next;
  }

  Future<void> _writeNow(String name, Object? data, int version) async {
    if (!await directory.exists()) await directory.create(recursive: true);
    final file = _file(name);
    final tmp = File('${file.path}.tmp');
    final content = jsonEncode({'version': version, 'data': data});
    await tmp.writeAsString(content, flush: true);
    await tmp.rename(file.path);
  }

  Future<void> delete(String name) async {
    await (_queues[name] ?? Future<void>.value());
    final file = _file(name);
    if (await file.exists()) await file.delete();
  }

  /// Deletes every file of the store (account and data deletion).
  Future<void> deleteAll() async {
    for (final name in StoreKeys.all) {
      await delete(name);
    }
  }

  /// Everything stored on the phone, for the data export (RGPD).
  Future<Map<String, Object?>> exportAll({Set<String> exclude = const {StoreKeys.installation}}) async {
    return {
      for (final name in StoreKeys.all)
        if (!exclude.contains(name)) name: await read(name),
    };
  }
}
