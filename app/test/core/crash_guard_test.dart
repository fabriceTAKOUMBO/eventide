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
  CrashGuard start({String build = '1.0.0+p2'}) =>
      CrashGuard(store: store, build: build, log: log.add)..load();

  setUp(() {
    store = MemoryGuardStore();
    log = [];
  });

  test('first start: nothing to report, nothing drawn simplified', () {
    final guard = start();
    expect(guard.safeStart, isFalse);
    expect(guard.deadStyles, isEmpty);
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

  test('a drawing interrupted by a crash: its style is drawn simplified from then on, and said in the log', () {
    final first = start()..uiStarting();
    final done = first.beginDrawing('paysage', 'pierres', '672×1456');
    first.endDrawing(done);
    first.beginDrawing('paysage', 'lisiere', '672×1456');
    expect(log, ['dessin : paysage pierres 672×1456', 'dessin : paysage lisiere 672×1456']);
    expect(jsonDecode(store.content!)['drawing'], [
      {'what': 'paysage', 'style': 'lisiere', 'detail': '672×1456'},
    ]);
    first.dispose();

    log.clear();
    final second = start();
    expect(second.isDead('lisiere'), isTrue);
    expect(second.isDead('pierres'), isFalse);
    expect(second.interrupted.single.style, 'lisiere');
    expect(log, contains(contains('lancement précédent arrêté pendant : paysage lisiere 672×1456')));
    second.markStable();

    // Still simplified at the following starts, until the build changes.
    expect(start().isDead('lisiere'), isTrue);
    expect(start(build: '1.0.1+p2').isDead('lisiere'), isFalse);
  });

  test('a drawing that ends normally leaves nothing', () {
    final guard = start();
    final token = guard.beginDrawing('image de la carte', 'berge', '720×720 nuit');
    guard.endDrawing(token);
    guard.endDrawing(token);
    expect(start().deadStyles, isEmpty);
  });

  test('an unreadable or foreign file is ignored', () {
    store.content = '{not json';
    expect(start().safeStart, isFalse);
    store.content = jsonEncode({'build': 'other', 'starts': 3, 'dead': ['cafe'], 'drawing': []});
    final guard = start();
    expect(guard.safeStart, isFalse);
    expect(guard.deadStyles, isEmpty);
  });

  test('the default guard (tests, previews) stores nothing and never marks anything', () {
    final guard = CrashGuard();
    expect(guard.enabled, isFalse);
    guard
      ..load()
      ..uiStarting();
    expect(guard.beginDrawing('paysage', 'lisiere', '1×1'), 0);
    expect(guard.isDead('lisiere'), isFalse);
    expect(guard.safeStart, isFalse);
  });
}
