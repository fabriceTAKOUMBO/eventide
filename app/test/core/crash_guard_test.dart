// Crash-loop guard (lib/core/crash_guard.dart, docs/app/architecture.md § 19): a process killed
// natively leaves its start sentinel; the next start reads it.
import 'dart:convert';

import 'package:eventide/core/crash_guard.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late MemoryGuardStore store;
  late List<String> log;

  /// A new process on the same phone (same file).
  CrashGuard start({String build = '1.0.0+s1'}) =>
      CrashGuard(store: store, build: build, log: log.add)..load();

  setUp(() {
    store = MemoryGuardStore();
    log = [];
  });

  test('first start: nothing to report', () {
    final guard = start();
    expect(guard.safeStart, isFalse);
    expect(guard.unfinishedStarts, 0);
    expect(log, isEmpty);
  });

  test('a start that dies before running stably makes the next start safe', () {
    final first = start()..uiStarting();
    expect(jsonDecode(store.content!)['starts'], 1, reason: 'written before the first landscape is drawn');
    first.dispose(); // killed: markStable never runs

    final second = start();
    expect(second.safeStart, isTrue);
    expect(log.single, contains('démarrage protégé'));
    second
      ..uiStarting()
      ..markStable();
    expect(jsonDecode(store.content!)['starts'], 0);

    expect(start().safeStart, isFalse, reason: 'a stable start ends the alert');
  });

  test('two crashed starts in a row: still safe, and counted', () {
    start()
      ..uiStarting()
      ..dispose();
    start()
      ..uiStarting()
      ..dispose();
    final third = start();
    expect(third.safeStart, isTrue);
    expect(third.unfinishedStarts, 2);
  });

  test('the start is stable after 20 s in the app, by itself; uiStarting counts once per process', () {
    fakeAsync((async) {
      final guard = start()
        ..uiStarting()
        ..uiStarting();
      expect(jsonDecode(store.content!)['starts'], 1);
      async.elapse(const Duration(seconds: 19));
      expect(jsonDecode(store.content!)['starts'], 1);
      async.elapse(const Duration(seconds: 1));
      expect(jsonDecode(store.content!)['starts'], 0);
      guard.dispose();
    });
  });

  test('no landscape drawn (scheduled start without the UI): never a safe start afterwards', () {
    start().dispose();
    expect(start().safeStart, isFalse);
  });

  test('what an older version wrote for the live 3D scenes is ignored: only the start counts', () {
    // Same build, a file of the WebView era (version 2): a start that died while a scene ran live.
    store.content = jsonEncode({
      'version': 2,
      'build': '1.0.0+s1',
      'starts': 1,
      'dead': ['jardin-zen'],
      'live': [
        {'what': 'scène 3D', 'subject': 'ondes', 'detail': 'high'},
      ],
    });
    final guard = start();
    expect(guard.safeStart, isTrue);
    expect(log.single, contains('démarrage protégé'));
    final saved = jsonDecode(store.content!) as Map<String, dynamic>;
    expect(saved.keys, unorderedEquals(['version', 'build', 'starts']));
    expect(saved['starts'], 1);
  });

  test('an unreadable or foreign file is ignored', () {
    store.content = '{not json';
    expect(start().safeStart, isFalse);
    store.content = jsonEncode({'build': 'other', 'starts': 3});
    final guard = start();
    expect(guard.safeStart, isFalse);
    expect(guard.unfinishedStarts, 0);
  });

  test('the default guard (tests, previews) stores nothing and never marks anything', () {
    final guard = CrashGuard();
    expect(guard.enabled, isFalse);
    guard
      ..load()
      ..uiStarting();
    expect(guard.unfinishedStarts, 0);
    expect(guard.safeStart, isFalse);
  });
}
