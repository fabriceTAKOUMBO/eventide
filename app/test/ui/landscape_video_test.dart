// Living landscapes: priority chain (video → poster → painter), when a video plays, and the
// player budget. A fake player stands for video_player (no platform channel in tests).
import 'package:eventide/core/landscape_media.dart';
import 'package:eventide/core/plan.dart';
import 'package:eventide/ui/landscape/landscape_background.dart';
import 'package:eventide/ui/landscape/landscape_image.dart';
import 'package:eventide/ui/landscape/landscape_video.dart';
import 'package:eventide/ui/model_scope.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_harness.dart';
import 'fake_app_model.dart';
import 'ui_test_utils.dart';

class FakeVideoPlayer implements LandscapeVideoPlayer {
  FakeVideoPlayer(this.source);

  final LandscapeVideoSource source;
  final ValueNotifier<LandscapeVideoStatus> _status = ValueNotifier(
    LandscapeVideoStatus.starting,
  );
  final List<String> calls = [];
  bool started = false;
  bool playing = false;
  bool disposed = false;

  @override
  ValueListenable<LandscapeVideoStatus> get status => _status;

  @override
  Size get size => const Size(720, 1280);

  @override
  Future<void> start() async {
    calls.add('start');
    started = true;
  }

  @override
  Future<void> play() async {
    calls.add('play');
    playing = true;
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    playing = false;
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose');
    disposed = true;
    playing = false;
  }

  @override
  Widget view() => const ColoredBox(key: kFakeVideo, color: Color(0xFF204060));

  /// The texture shows the loop: the video may cover the poster.
  void showFrames() => _status.value = LandscapeVideoStatus.showing;

  void fail() => _status.value = LandscapeVideoStatus.failed;
}

const Key kFakeVideo = Key('fake-video');

class FakeVideoFactory {
  final List<FakeVideoPlayer> created = [];

  LandscapeVideoPlayer call(LandscapeVideoSource source) {
    final player = FakeVideoPlayer(source);
    created.add(player);
    return player;
  }

  List<FakeVideoPlayer> get alive => [
    for (final p in created)
      if (!p.disposed) p,
  ];
}

const _cascadeVideo = AssetLandscapeVideo('assets/landscapes/cascade-foret.mp4');
const _cascadePoster = AssetImage('assets/landscapes/cascade-foret.jpg');

Widget _host(
  FakeAppModel model,
  Widget child, {
  bool reduceMotion = false,
  bool covered = false,
}) {
  return MediaQuery(
    data: MediaQueryData(
      size: const Size(390, 844),
      disableAnimations: reduceMotion,
    ),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: ModelScope(
        model: model,
        child: TickerMode(enabled: !covered, child: child),
      ),
    ),
  );
}

const _cascade = LandscapeBackground(
  landscapeId: 'cascade-foret',
  style: 'cascade',
  kenBurns: true,
);

double _videoOpacity(WidgetTester tester) =>
    tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity;

Finder _poster(ImageProvider provider) => find.byWidgetPredicate(
  (w) => w is Image && w.image == provider,
);

Future<void> _lifecycle(WidgetTester tester, List<AppLifecycleState> states) async {
  for (final state in states) {
    tester.binding.handleAppLifecycleStateChanged(state);
    await tester.pump();
  }
}

void main() {
  late FakeVideoFactory factory;

  setUpAll(loadAppFonts);

  setUp(() {
    factory = FakeVideoFactory();
    LandscapeVideos.debugReset(factory: factory.call);
    LandscapeImages.debugSetVideos(
      bundled: {'cascade-foret', 'sous-bois', 'berge-mousseuse', 'torrent-montagne'},
      remote: {'pluie-ville'},
    );
  });

  tearDown(() {
    LandscapeVideos.debugReset();
    LandscapeImages.debugSetVideos();
  });

  group('priority chain', () {
    testWidgets('video over its poster, faded in once its first frames are on screen', (
      tester,
    ) async {
      await tester.runAsync(LandscapeImages.discoverAssets);
      final model = FakeAppModel()..videos['cascade-foret'] = _cascadeVideo;
      await tester.pumpWidget(_host(model, _cascade));
      await tester.pump();

      final player = factory.created.single;
      expect(player.source, _cascadeVideo);
      expect(player.started, isTrue);
      expect(player.playing, isTrue);
      // Muted loop, no Ken Burns: the poster stays exactly where the video appears.
      expect(find.byType(KenBurns), findsNothing);
      expect(_poster(_cascadePoster), findsOneWidget);
      expect(_videoOpacity(tester), 0, reason: 'poster until the first frames');

      player.showFrames();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(_videoOpacity(tester), 1);
      expect(find.byKey(kFakeVideo), findsOneWidget);
      expect(_poster(_cascadePoster), findsOneWidget, reason: 'still underneath');

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(player.disposed, isTrue);
      expect(LandscapeVideos.hub.liveCount, 0);
    });

    testWidgets('poster when the model has no video to give (no network, Wi-Fi only)', (
      tester,
    ) async {
      await tester.runAsync(LandscapeImages.discoverAssets);
      final model = FakeAppModel();
      await tester.pumpWidget(_host(model, _cascade));
      await tester.pump();
      expect(model.videoRequests, ['cascade-foret']);
      expect(factory.created, isEmpty);
      expect(_poster(_cascadePoster), findsOneWidget);
      expect(find.byType(AnimatedOpacity), findsNothing);
      expect(find.byType(KenBurns), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('procedural painter, with Ken Burns, for a landscape without video', (
      tester,
    ) async {
      LandscapeImages.debugSetVideos(bundled: {'cascade-foret'});
      final model = FakeAppModel();
      await tester.pumpWidget(
        _host(
          model,
          const LandscapeBackground(
            landscapeId: 'sous-bois',
            style: 'sous-bois',
            kenBurns: true,
          ),
        ),
      );
      await tester.pump();
      expect(model.videoRequests, isEmpty);
      expect(factory.created, isEmpty);
      expect(find.byType(ProceduralLandscape), findsOneWidget);
      expect(find.byType(KenBurns), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a failing video leaves the still picture, without retrying', (tester) async {
      final model = FakeAppModel()..videos['cascade-foret'] = _cascadeVideo;
      await tester.pumpWidget(_host(model, _cascade));
      await tester.pump();
      factory.created.single.fail();
      await tester.pump();
      await tester.pump();
      expect(factory.created.single.disposed, isTrue);
      expect(find.byType(AnimatedOpacity), findsNothing);
      expect(factory.created, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('when a video plays', () {
    testWidgets('reduced motion (accessibility): still picture, no player at all', (
      tester,
    ) async {
      final model = FakeAppModel()..videos['cascade-foret'] = _cascadeVideo;
      await tester.pumpWidget(_host(model, _cascade, reduceMotion: true));
      await tester.pump();
      expect(factory.created, isEmpty);
      expect(model.videoRequests, isEmpty);
      expect(find.byType(KenBurns), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('background: released; back: poster (frame 0), then the loop from the start', (
      tester,
    ) async {
      final model = FakeAppModel()..videos['cascade-foret'] = _cascadeVideo;
      await tester.pumpWidget(_host(model, _cascade));
      await tester.pump();
      final first = factory.created.single..showFrames();
      await tester.pump();

      // Notification shade, system dialog: paused on its frame, kept.
      await _lifecycle(tester, [AppLifecycleState.inactive]);
      expect(first.playing, isFalse);
      expect(first.disposed, isFalse);
      await _lifecycle(tester, [AppLifecycleState.resumed]);
      expect(first.playing, isTrue);

      // Background: nothing plays, the player is released.
      await _lifecycle(tester, [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]);
      expect(first.disposed, isTrue);
      expect(LandscapeVideos.hub.liveCount, 0);
      expect(find.byKey(kFakeVideo), findsNothing);

      await _lifecycle(tester, [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]);
      expect(factory.created, hasLength(2));
      final second = factory.created.last;
      expect(second.playing, isTrue);
      expect(_videoOpacity(tester), 0, reason: 'the poster shows until frames flow');
      second.showFrames();
      await tester.pump(const Duration(milliseconds: 300));
      expect(_videoOpacity(tester), 1);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('covered (standby, another screen): paused at once, released after 20 s', (
      tester,
    ) async {
      final model = FakeAppModel()..videos['cascade-foret'] = _cascadeVideo;
      await tester.pumpWidget(_host(model, _cascade));
      await tester.pump();
      final player = factory.created.single;
      expect(player.playing, isTrue);

      await tester.pumpWidget(_host(model, _cascade, covered: true));
      expect(player.playing, isFalse);
      expect(player.disposed, isFalse);
      await tester.pump(const Duration(seconds: 10));
      // Uncovered soon: the same player goes on from the same frame.
      await tester.pumpWidget(_host(model, _cascade));
      expect(player.playing, isTrue);
      expect(factory.created, hasLength(1));

      await tester.pumpWidget(_host(model, _cascade, covered: true));
      await tester.pump(const Duration(seconds: 21));
      expect(player.disposed, isTrue);
      expect(LandscapeVideos.hub.liveCount, 0);

      await tester.pumpWidget(_host(model, _cascade));
      await tester.pump();
      expect(factory.created, hasLength(2));
      expect(factory.created.last.playing, isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the sound never drives the video: pausing the sound leaves it playing', (
      tester,
    ) async {
      final model = FakeAppModel()..videos['cascade-foret'] = _cascadeVideo;
      await tester.pumpWidget(_host(model, _cascade));
      await tester.pump();
      final player = factory.created.single..showFrames();
      await tester.pump();
      final pausesBefore = player.calls.where((c) => c == 'pause').length;

      await model.play();
      await tester.pump();
      await model.pause(); // play button, notification, voice, focus loss, timer end
      await tester.pump();
      await model.togglePlay();
      await tester.pump();
      model.setPlaying(false);
      await tester.pump();

      expect(player.playing, isTrue);
      expect(player.calls.where((c) => c == 'pause'), hasLength(pausesBefore));
      expect(player.disposed, isFalse);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a locked Premium landscape never asks for its video (free plan)', (
      tester,
    ) async {
      final model = FakeAppModel()
        ..videos['pluie-ville'] = const FileLandscapeVideo('/data/pluie-ville.mp4');
      await tester.pumpWidget(
        _host(
          model,
          const LandscapeBackground(
            landscapeId: 'pluie-ville',
            style: 'ville-pluie',
            kenBurns: true,
          ),
        ),
      );
      await tester.pump();
      expect(model.videoRequests, isEmpty);
      expect(factory.created, isEmpty);
      // Shown as today: still picture with its slow motion.
      expect(find.byType(KenBurns), findsOneWidget);

      // Premium bought: the same widget now asks for and plays the video.
      model.plan = Plan.annual;
      await tester.pump();
      await tester.pump();
      expect(model.videoRequests, ['pluie-ville']);
      expect(factory.created.single.source, const FileLandscapeVideo('/data/pluie-ville.mp4'));
      expect(find.byType(KenBurns), findsNothing);

      // Back to free (subscription expired): released, nothing asked any more.
      model.plan = Plan.free;
      await tester.pump();
      expect(factory.created.single.disposed, isTrue);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('player budget', () {
    test('one player per source, shared; never more than two; disposed when unused', () async {
      final hub = LandscapeVideoHub(factory: factory.call);
      final a1 = hub.acquire(_cascadeVideo)!;
      final a2 = hub.acquire(_cascadeVideo)!;
      expect(identical(a1.player, a2.player), isTrue);
      final b = hub.acquire(const AssetLandscapeVideo('assets/landscapes/sous-bois.mp4'))!;
      expect(hub.liveCount, 2);
      expect(hub.acquire(const AssetLandscapeVideo('assets/landscapes/x.mp4')), isNull);

      a1.playing = true;
      a2.playing = false;
      expect((a1.player as FakeVideoPlayer).playing, isTrue);
      a1.release();
      expect((a2.player as FakeVideoPlayer).playing, isFalse, reason: 'a2 wants it paused');
      expect((a2.player as FakeVideoPlayer).disposed, isFalse);
      a2.release();
      expect((a2.player as FakeVideoPlayer).disposed, isTrue);
      expect(hub.liveCount, 1);
      b.release();
      expect(hub.liveCount, 0);
    });

    testWidgets('home swipes: the incoming landscape preloads, then one player is left', (
      tester,
    ) async {
      usePhoneView(tester, reduceMotion: false);
      final model = FakeAppModel(plan: Plan.annual);
      for (final id in ['cascade-foret', 'sous-bois', 'berge-mousseuse', 'torrent-montagne']) {
        model.videos[id] = AssetLandscapeVideo('assets/landscapes/$id.mp4');
      }
      await pumpApp(tester, model);
      expect(factory.alive.map((p) => p.source), [_cascadeVideo]);

      Future<void> swipeUp() async {
        final gesture = await tester.startGesture(const Offset(195, 300));
        await gesture.moveBy(const Offset(0, -40));
        await tester.pump();
        await gesture.moveBy(const Offset(0, -160));
        await tester.pump();
        await tester.pump();
        // During the gesture: the current landscape and the incoming one.
        expect(LandscapeVideos.hub.liveCount, 2);
        await gesture.up();
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 150));
        }
      }

      await swipeUp();
      expect(model.browsedLandscapeId, 'sous-bois');
      expect(LandscapeVideos.hub.liveCount, 1);
      final preloaded = factory.created[1];
      expect(preloaded.source, const AssetLandscapeVideo('assets/landscapes/sous-bois.mp4'));
      expect(preloaded.disposed, isFalse, reason: 'the preloaded player became the current one');
      expect(preloaded.playing, isTrue);
      expect(factory.created.first.disposed, isTrue);

      await swipeUp();
      await swipeUp();
      expect(model.browsedLandscapeId, 'torrent-montagne');
      expect(factory.alive.map((p) => p.source), [
        const AssetLandscapeVideo('assets/landscapes/torrent-montagne.mp4'),
      ]);
      expect(factory.created, hasLength(4));
      await tearDownApp(tester);
    });

    testWidgets('a cancelled swipe releases the preloaded neighbour', (tester) async {
      usePhoneView(tester, reduceMotion: false);
      final model = FakeAppModel(plan: Plan.annual);
      model.videos['cascade-foret'] = _cascadeVideo;
      model.videos['sous-bois'] = const AssetLandscapeVideo('assets/landscapes/sous-bois.mp4');
      await pumpApp(tester, model);
      final gesture = await tester.startGesture(const Offset(195, 300));
      await gesture.moveBy(const Offset(0, -30));
      await tester.pump();
      await gesture.moveBy(const Offset(0, -10));
      await tester.pump();
      await tester.pump();
      expect(LandscapeVideos.hub.liveCount, 2);
      await gesture.up(); // 40 px: below the 50 px threshold, back to where it was
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 150));
      }
      expect(model.browsedLandscapeId, 'cascade-foret');
      expect(factory.alive.map((p) => p.source), [_cascadeVideo]);
      await tearDownApp(tester);
    });
  });
}
