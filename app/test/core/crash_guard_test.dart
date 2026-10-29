// Crash-loop guard (lib/core/crash_guard.dart, docs/app/architecture.md § 19): a process killed
// natively leaves its sentinels; the next start reads them.
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

  test('first start: nothing to report, no scene marked', () {
    final guard = start();
    expect(guard.safeStart, isFalse);
    expect(guard.deadSubjects, isEmpty);
    expect(guard.interrupted, isEmpty);
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

  test('a live 3D scene interrupted by a crash: shown as its poster from then on, and said in the log', () {
    final first = start()..uiStarting();
    final done = first.beginLive('scène 3D', 'jardin-zen', 'high');
    first.endLive(done); // paused or released normally
    first.beginLive('scène 3D', 'ondes', 'high');
    expect(log, ['en direct : scène 3D jardin-zen high', 'en direct : scène 3D ondes high']);
    expect(jsonDecode(store.content!)['live'], [
      {'what': 'scène 3D', 'subject': 'ondes', 'detail': 'high'},
    ]);
    first.dispose(); // killed natively while the scene ran

    log.clear();
    final second = start();
    expect(second.isDead('ondes'), isTrue);
    expect(second.isDead('jardin-zen'), isFalse);
    expect(second.interrupted.single.subject, 'ondes');
    expect(log, contains(contains('lancement précédent arrêté pendant : scène 3D ondes high ; ce paysage sera montré en image fixe')));
    second.markStable();

    // Still a poster at the following starts, until the build (app or runtime) changes.
    expect(start().isDead('ondes'), isTrue);
    expect(start(build: '1.0.1+s1').isDead('ondes'), isFalse);
  });

  test('live work that ends normally leaves nothing', () {
    final guard = start();
    final token = guard.beginLive('scène 3D', 'aurore', 'low');
    guard.endLive(token);
    guard.endLive(token);
    expect(start().deadSubjects, isEmpty);
  });
  test('an unreadable or foreign file is ignored', () {
    store.content = '{not json';
    expect(start().safeStart, isFalse);
    store.content = jsonEncode({'build': 'other', 'starts': 3, 'dead': ['ondes'], 'live': []});
    final guard = start();
    expect(guard.safeStart, isFalse);
    expect(guard.deadSubjects, isEmpty);
  });

  test('the default guard (tests, previews) stores nothing and never marks anything', () {
    final guard = CrashGuard();
    expect(guard.enabled, isFalse);
    guard
      ..load()
      ..uiStarting();
    expect(guard.beginLive('scène 3D', 'ondes', 'high'), 0);
    expect(guard.isDead('ondes'), isFalse);
    expect(guard.safeStart, isFalse);
  });
}
