// Video players of the living landscapes: never more than two hardware decoders, counting the
// ones still being released (fast swipes must not pile decoders up), and breadcrumbs for the
// problem report.
import 'dart:async';

import 'package:eventide/core/landscape_media.dart';
import 'package:eventide/ui/landscape/landscape_video.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class _SlowPlayer implements LandscapeVideoPlayer {
  _SlowPlayer(this.source);

  final LandscapeVideoSource source;
  final Completer<void> released = Completer<void>();
  bool disposeCalled = false;

  @override
  ValueListenable<LandscapeVideoStatus> get status => ValueNotifier(LandscapeVideoStatus.starting);

  @override
  Size get size => Size.zero;

  @override
  Future<void> start() async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> dispose() {
    disposeCalled = true;
    return released.future;
  }

  @override
  Widget view() => const SizedBox();
}

const _a = AssetLandscapeVideo('assets/landscapes/a.mp4');
const _b = AssetLandscapeVideo('assets/landscapes/b.mp4');
const _c = AssetLandscapeVideo('assets/landscapes/c.mp4');

void main() {
  tearDown(() => LandscapeVideos.log = null);

  test('a player still being released keeps its slot until its decoder is freed', () {
    fakeAsync((async) {
      final players = <_SlowPlayer>[];
      final hub = LandscapeVideoHub(
        factory: (s) {
          final p = _SlowPlayer(s);
          players.add(p);
          return p;
        },
      );
      var notified = 0;
      hub.addListener(() => notified++);
      final a = hub.acquire(_a)!;
      final b = hub.acquire(_b)!;
      a.release();
      async.flushMicrotasks();
      expect(players.first.disposeCalled, isTrue);
      expect(hub.liveCount, 1);
      expect(hub.releasingCount, 1);
      expect(hub.acquire(_c), isNull, reason: 'a and b still hold two decoders');
      players.first.released.complete();
      async.flushMicrotasks();
      expect(hub.releasingCount, 0);
      expect(notified, greaterThan(0), reason: 'a waiting widget retries');
      final c = hub.acquire(_c);
      expect(c, isNotNull);
      b.release();
      c!.release();
      async.flushMicrotasks();
    });
  });

  test('a release that never answers stops counting after the timeout', () {
    fakeAsync((async) {
      final hub = LandscapeVideoHub(factory: _SlowPlayer.new, releaseTimeout: const Duration(seconds: 3));
      hub.acquire(_a)!.release();
      hub.acquire(_b)!.release();
      async.flushMicrotasks();
      expect(hub.acquire(_c), isNull);
      async.elapse(const Duration(seconds: 3));
      expect(hub.releasingCount, 0);
      expect(hub.acquire(_c), isNotNull);
    });
  });

  test('opened and released players are noted for the problem report', () {
    fakeAsync((async) {
      final lines = <String>[];
      LandscapeVideos.log = lines.add;
      final hub = LandscapeVideoHub(factory: _SlowPlayer.new);
      hub.acquire(_a)!.release();
      async.flushMicrotasks();
      expect(lines, hasLength(2));
      expect(lines.first, contains('ouverte AssetLandscapeVideo(assets/landscapes/a.mp4)'));
      expect(lines.last, contains('libérée'));
      async.elapse(const Duration(seconds: 3));
    });
  });
}
