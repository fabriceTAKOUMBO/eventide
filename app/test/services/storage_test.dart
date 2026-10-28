import 'dart:io';

import 'package:eventide/services/storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late LocalStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('eventide_store_');
    store = LocalStore(Directory('${dir.path}/eventide'));
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('round trip with a version envelope, no temporary file left', () async {
    await store.write(StoreKeys.scene, {'paysage': 'cascade-foret'});
    expect(await store.readMap(StoreKeys.scene), {'paysage': 'cascade-foret'});
    final names = Directory('${dir.path}/eventide').listSync().map((e) => e.uri.pathSegments.last).toList();
    expect(names, ['scene.json']);
    final raw = File('${dir.path}/eventide/scene.json').readAsStringSync();
    expect(raw, contains('"version":1'));
  });

  test('missing or corrupt files read as null', () async {
    expect(await store.read(StoreKeys.settings), isNull);
    Directory('${dir.path}/eventide').createSync(recursive: true);
    File('${dir.path}/eventide/settings.json').writeAsStringSync('{not json');
    expect(await store.read(StoreKeys.settings), isNull);
    expect(await store.readList(StoreKeys.settings), isEmpty);
  });

  test('concurrent writes to one file are serialized, the last one wins', () async {
    final futures = [for (var i = 0; i < 20; i++) store.write(StoreKeys.nights, [i])];
    await Future.wait(futures);
    expect(await store.read(StoreKeys.nights), [19]);
  });

  test('export skips the installation token; deleteAll removes everything', () async {
    await store.write(StoreKeys.installation, {'token': 'secret'});
    await store.write(StoreKeys.favorites, [
      {'id': 'a'},
    ]);
    final export = await store.exportAll();
    expect(export.containsKey(StoreKeys.installation), isFalse);
    expect(export[StoreKeys.favorites], [
      {'id': 'a'},
    ]);
    await store.deleteAll();
    expect(await store.read(StoreKeys.installation), isNull);
    expect(await store.read(StoreKeys.favorites), isNull);
  });
}
