// The 3D scenes of « Imaginaire » (contract § 12; lib/ui/landscape/imaginaire_view.dart), driven
// through a fake surface (no WebView in tests): poster → ready → paused/resumed → released;
// errors, renderer loss and timeouts fall back to the poster; one live scene in the app.
import 'dart:async';
import 'dart:convert';

import 'package:eventide/core/crash_guard.dart';
import 'package:eventide/core/plan.dart';
import 'package:eventide/core/scene.dart';
import 'package:eventide/ui/landscape/imaginaire_surface.dart';
import 'package:eventide/ui/landscape/imaginaire_view.dart';
import 'package:eventide/ui/landscape/landscape_background.dart';
import 'package:eventide/ui/landscape/landscape_image.dart';
import 'package:eventide/ui/model_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_harness.dart';
import 'fake_app_model.dart';
import 'ui_test_utils.dart';

class FakeSceneSurface implements ImaginaireSurface {
  final List<String> calls = [];
  final StreamController<SceneEvent> _events = StreamController<SceneEvent>.broadcast();
  bool loaded = false;
  bool disposed = false;

  void emit(SceneEvent event) => _events.add(event);

  @override
  Stream<SceneEvent> get events => _events.stream;

  @override
  Future<void> load() async => loaded = true;

  @override
  Future<void> run(String javaScript) async => calls.add(javaScript);

  @override
  Widget view() => const SizedBox.expand(key: ValueKey('fake-scene'));

  @override
  Future<void> dispose() async {
    disposed = true;
    await _events.close();
  }
}

class FakeSurfaces {
  final List<FakeSceneSurface> created = [];

  List<FakeSceneSurface> get alive => [
    for (final s in created)
      if (!s.disposed) s,
  ];

  ImaginaireSurface call() {
    final surface = FakeSceneSurface();
    created.add(surface);
    return surface;
  }
}

const _posterKey = ValueKey('poster');

Widget _host(Widget child, {bool covered = false, bool reduceMotion = false}) => MediaQuery(
  data: MediaQueryData(size: const Size(390, 844), disableAnimations: reduceMotion),
  child: Directionality(
    textDirection: TextDirection.ltr,
    child: TickerMode(enabled: !covered, child: child),
  ),
);

ImaginaireView _view({
  String id = 'foret-lucioles',
  Map<String, int> decor = const {'lucioles': 60, 'brume': 30},
  Moment moment = Moment.nuit,
  bool live = true,
  Key? key,
}) => ImaginaireView(
  key: key,
  sceneId: id,
  poster: const ColoredBox(key: _posterKey, color: Color(0xFF203020)),
  decor: decor,
  moment: moment,
  live: live,
);

double _posterOpacity(WidgetTester tester, [Finder? within]) => tester
    .widget<AnimatedOpacity>(
      find.descendant(of: within ?? find.byType(ImaginaireView), matching: find.byKey(const ValueKey('imaginaire-poster'))),
    )
    .opacity;

ImaginairePhase _phase(WidgetTester tester) => tester.state<ImaginaireViewState>(find.byType(ImaginaireView)).phase;

void main() {
  late FakeSurfaces surfaces;
  late List<String> log;

  setUp(() {
    surfaces = FakeSurfaces();
    log = [];
    Imaginaire.debugReset();
    Imaginaire.surfaceFactory = surfaces.call;
    Imaginaire.log = log.add;
    LandscapeImages.debugSetSceneRuntime(true);
  });

  tearDown(() {
    Imaginaire.debugReset();
    Imaginaire.surfaceFactory = WebViewSceneSurface.new;
    LandscapeImages.debugSetSceneRuntime(false);
    CrashGuard.current = CrashGuard();
  });

  group('page messages and calls', () {
    test('messages of the EventideScene channel', () {
      expect(parseSceneMessage('{"type":"ready"}'), isA<SceneReady>());
      final error = parseSceneMessage('{"type":"error","detail":"WebGL indisponible"}');
      expect((error! as SceneError).detail, 'WebGL indisponible');
      expect((parseSceneMessage('{"type":"error"}')! as SceneError).detail, isNotEmpty);
      final stats = parseSceneMessage('{"type":"stats","fps":28.5,"ms":12}')! as SceneStats;
      expect((stats.fps, stats.ms), (28.5, 12.0));
      for (final junk in ['', 'ready', '[]', '{"type":"other"}', '{"type":"stats","fps":"x"}']) {
        expect(parseSceneMessage(junk), isNull, reason: junk);
      }
    });

    test('calls of the runtime API, arguments JSON-encoded', () {
      final start = SceneCalls.start(
        'lac-lune',
        decor: {'etoiles': 60},
        moment: Moment.soir,
        quality: SceneQuality.high,
      );
      expect(start, startsWith('eventide.start("lac-lune", '));
      final options = jsonDecode(start.substring('eventide.start("lac-lune", '.length, start.length - 2));
      expect(options, {
        'decor': {'etoiles': 60},
        'moment': 'soir',
        'quality': 'high',
        'fps': 30,
      });
      expect(SceneCalls.setDecor('brume', 140), 'eventide.setDecor("brume", 100);');
      expect(SceneCalls.setMoment(Moment.aube), 'eventide.setMoment("aube");');
      expect(SceneCalls.setPaused(true), 'eventide.setPaused(true);');
      expect(SceneCalls.setQuality(SceneQuality.low), 'eventide.setQuality("low");');
      expect(SceneCalls.setDecor('x"); alert(1); ("', 10), contains(r'"x\"); alert(1); (\""'));
    });

    test('only the bundled page may load', () {
      expect(WebViewSceneSurface.isLocalPage('file:///android_asset/flutter_assets/assets/imaginaire/index.html'), isTrue);
      expect(WebViewSceneSurface.isLocalPage('https://cdn.example/three.js'), isFalse);
      expect(WebViewSceneSurface.isLocalPage('file:///data/user/0/x.html'), isFalse);
    });
  });

  group('state machine', () {
    testWidgets('poster → ready → paused when covered → resumed → released after 20 s', (tester) async {
      await tester.pumpWidget(_host(_view()));
      final surface = surfaces.created.single;
      expect(surface.loaded, isTrue);
      expect(_phase(tester), ImaginairePhase.loading);
      expect(_posterOpacity(tester), 1, reason: 'the poster until the first frame');

      surface.emit(const SceneLoaded());
      await tester.pump();
      final start = surface.calls.single;
      expect(start, startsWith('eventide.start("foret-lucioles"'));
      expect(start, contains('"decor":{"lucioles":60,"brume":30}'));
      expect(start, contains('"moment":"nuit"'));
      expect(start, contains('"quality":"high"'));

      surface.emit(const SceneReady());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 450));
      expect(_phase(tester), ImaginairePhase.live);
      expect(_posterOpacity(tester), 0);
      expect(find.byKey(const ValueKey('fake-scene')), findsOneWidget);
      expect(log, contains('scène 3D : foret-lucioles prête'));

      // Another screen on top (TickerMode off): paused on its last frame.
      await tester.pumpWidget(_host(_view(), covered: true));
      expect(surface.calls.last, 'eventide.setPaused(true);');
      expect(_phase(tester), ImaginairePhase.paused);
      expect(_posterOpacity(tester), 0, reason: 'the last frame stays');
      await tester.pump(const Duration(seconds: 19));
      expect(surface.disposed, isFalse);
      // Back within 20 s: resumed where it was.
      await tester.pumpWidget(_host(_view()));
      expect(surface.calls.last, 'eventide.setPaused(false);');
      expect(_phase(tester), ImaginairePhase.live);
      // Covered for good: released after 20 s, the poster comes back.
      await tester.pumpWidget(_host(_view(), covered: true));
      await tester.pump(const Duration(seconds: 20));
      await tester.pump();
      expect(surface.disposed, isTrue);
      expect(_phase(tester), ImaginairePhase.poster);
      expect(_posterOpacity(tester), 1);
      expect(Imaginaire.liveCount, 0);
      // Seen again: a new scene.
      await tester.pumpWidget(_host(_view()));
      expect(surfaces.created, hasLength(2));
      await tester.pumpWidget(const SizedBox());
      expect(surfaces.created.last.disposed, isTrue);
    });

    testWidgets('decor and moment changes go to the running scene', (tester) async {
      await tester.pumpWidget(_host(_view()));
      final surface = surfaces.created.single
        ..emit(const SceneLoaded())
        ..emit(const SceneReady());
      await tester.pump();
      surface.calls.clear();
      await tester.pumpWidget(_host(_view(decor: const {'lucioles': 40, 'feuilles': 20}, moment: Moment.aube)));
      expect(surface.calls, [
        'eventide.setDecor("lucioles", 40);',
        'eventide.setDecor("feuilles", 20);',
        'eventide.setDecor("brume", 0);',
        'eventide.setMoment("aube");',
      ]);
      expect(surfaces.created, hasLength(1), reason: 'never reloaded for a change');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an error: back to the poster, a line in the report, not tried again this run', (tester) async {
      await tester.pumpWidget(_host(_view()));
      surfaces.created.single.emit(const SceneError('WebGL indisponible'));
      await tester.pump();
      expect(surfaces.created.single.disposed, isTrue);
      expect(_phase(tester), ImaginairePhase.poster);
      expect(log.last, 'scène 3D : foret-lucioles en image fixe (WebGL indisponible)');
      expect(Imaginaire.failedThisRun, {'foret-lucioles'});
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_host(_view()));
      expect(surfaces.created, hasLength(1));
      expect(find.byKey(_posterKey), findsOneWidget);
      // Another scene still runs.
      await tester.pumpWidget(_host(_view(id: 'ondes', decor: const {'etoiles': 40})));
      expect(surfaces.created, hasLength(2));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the renderer crashed: poster; reclaimed by Android: released, back when seen again', (tester) async {
      await tester.pumpWidget(_host(_view()));
      surfaces.created.single
        ..emit(const SceneLoaded())
        ..emit(const SceneReady())
        ..emit(const SceneGone(crashed: false));
      await tester.pump();
      expect(surfaces.created.single.disposed, isTrue);
      expect(Imaginaire.failedThisRun, isEmpty);
      expect(log.last, contains('libéré par Android'));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_host(_view()));
      expect(surfaces.created, hasLength(2));
      surfaces.created.last.emit(const SceneGone(crashed: true));
      await tester.pump();
      expect(surfaces.created.last.disposed, isTrue);
      expect(Imaginaire.failedThisRun, {'foret-lucioles'});
      expect(log.last, contains('moteur de rendu planté'));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('not ready in time: poster', (tester) async {
      await tester.pumpWidget(_host(_view()));
      surfaces.created.single.emit(const SceneLoaded());
      await tester.pump(const Duration(seconds: 12));
      await tester.pump();
      expect(surfaces.created.single.disposed, isTrue);
      expect(_phase(tester), ImaginairePhase.poster);
      expect(log.last, contains('pas prête après 12 s'));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('poster only: reduced motion, no runtime, not live, or a scene the crash guard marked', (tester) async {
      await tester.pumpWidget(_host(_view(), reduceMotion: true));
      await tester.pumpWidget(_host(_view(live: false)));
      LandscapeImages.debugSetSceneRuntime(false);
      await tester.pumpWidget(_host(_view(key: const ValueKey('a'))));
      await tester.pumpWidget(const SizedBox());
      LandscapeImages.debugSetSceneRuntime(true);
      final store = MemoryGuardStore(
        jsonEncode({'build': 'b', 'starts': 0, 'dead': ['foret-lucioles'], 'live': []}),
      );
      CrashGuard.current = CrashGuard(store: store, build: 'b')..load();
      await tester.pumpWidget(_host(_view(key: const ValueKey('b'))));
      expect(surfaces.created, isEmpty);
      expect(find.byKey(_posterKey), findsOneWidget);
      // The covered scene is never created either.
      CrashGuard.current = CrashGuard();
      await tester.pumpWidget(_host(_view(key: const ValueKey('c')), covered: true));
      expect(surfaces.created, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('one live scene in the whole app: a newer view takes it', (tester) async {
      await tester.pumpWidget(_host(Column(
        children: [
          Expanded(child: _view(key: const ValueKey('first'))),
        ],
      )));
      expect(surfaces.alive, hasLength(1));
      await tester.pumpWidget(_host(Column(
        children: [
          Expanded(child: _view(key: const ValueKey('first'))),
          Expanded(child: _view(key: const ValueKey('second'), id: 'ondes', decor: const {'etoiles': 40})),
        ],
      )));
      await tester.pump();
      expect(surfaces.created, hasLength(2));
      expect(surfaces.created.first.disposed, isTrue, reason: 'the older one went back to its poster');
      expect(surfaces.alive, hasLength(1));
      expect(Imaginaire.liveCount, 1);
      await tester.pumpWidget(const SizedBox());
      expect(Imaginaire.liveCount, 0);
    });

    testWidgets('app in background or screen off: paused at once, released after 20 s', (tester) async {
      await tester.pumpWidget(_host(_view()));
      final surface = surfaces.created.single
        ..emit(const SceneLoaded())
        ..emit(const SceneReady());
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(surface.calls.last, 'eventide.setPaused(true);');
      await tester.pump(const Duration(seconds: 21));
      expect(surface.disposed, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(surfaces.created, hasLength(2), reason: 'back in the foreground: live again');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the crash guard marks the scene while it runs, not while paused', (tester) async {
      final store = MemoryGuardStore();
      CrashGuard.current = CrashGuard(store: store, build: 'b')..load();
      List<Object?> live() => (jsonDecode(store.content!) as Map)['live'] as List;
      await tester.pumpWidget(_host(_view()));
      surfaces.created.single.emit(const SceneLoaded());
      await tester.pump();
      expect(live(), [
        {'what': 'scène 3D', 'subject': 'foret-lucioles', 'detail': 'high'},
      ]);
      await tester.pumpWidget(_host(_view(), covered: true));
      expect(live(), isEmpty);
      await tester.pumpWidget(_host(_view()));
      expect(live(), hasLength(1));
      await tester.pumpWidget(const SizedBox());
      expect(live(), isEmpty);
    });

    testWidgets('a slow phone: low quality, asked once', (tester) async {
      await tester.pumpWidget(_host(_view()));
      final surface = surfaces.created.single
        ..emit(const SceneLoaded())
        ..emit(const SceneReady())
        ..emit(const SceneStats(fps: 14, ms: 60))
        ..emit(const SceneStats(fps: 12, ms: 70));
      await tester.pump();
      expect(surface.calls.where((c) => c == 'eventide.setQuality("low");'), hasLength(1));
      expect(log.last, contains('qualité basse'));
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('in the app', () {
    testWidgets('a 3D scene on the home screen: its decor (plan allowing), the swipe shows posters', (tester) async {
      usePhoneView(tester, reduceMotion: false);
      final model = FakeAppModel(plan: Plan.free)..selectLandscape('foret-lucioles');
      await pumpApp(tester, model);
      LandscapeImages.debugSetSceneRuntime(true);
      await tester.pump();
      expect(surfaces.created, hasLength(1));
      final view = tester.widget<ImaginaireView>(find.byType(ImaginaireView));
      expect(view.sceneId, 'foret-lucioles');
      expect(view.decor, {'lucioles': 60, 'brume': 30});
      surfaces.created.single
        ..emit(const SceneLoaded())
        ..emit(const SceneReady());
      await tester.pump();

      // A swipe: the incoming scene (locked here) is a poster while the finger moves.
      final gesture = await tester.startGesture(const Offset(195, 300));
      await gesture.moveBy(const Offset(0, -40));
      await tester.pump();
      await gesture.moveBy(const Offset(0, -160));
      await tester.pump();
      expect(find.byType(ImaginaireView), findsNWidgets(2));
      expect(surfaces.created, hasLength(1), reason: 'the incoming scene is a poster');
      await gesture.up();
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 150));
      }
      expect(model.browsedLandscapeId, 'lac-lune');
      // Settled: the new scene runs live, the old one is gone; one WebView at most.
      expect(surfaces.created, hasLength(2));
      expect(surfaces.alive, hasLength(1));
      // Locked for this free user: its Premium decor (étoiles) is left out, the free brume shown.
      expect(tester.widget<ImaginaireView>(find.byType(ImaginaireView)).decor, {'brume': 30});
      await tearDownApp(tester);
      expect(surfaces.alive, isEmpty);
    });

    testWidgets('a filmed landscape never makes a WebView', (tester) async {
      final model = FakeAppModel(plan: Plan.annual);
      await tester.pumpWidget(
        _host(ModelScope(model: model, child: const LandscapeBackground(landscapeId: 'cascade-foret'))),
      );
      expect(find.byType(ImaginaireView), findsNothing);
      model.selectLandscape('jardin-zen');
      await tester.pumpWidget(
        _host(ModelScope(model: model, child: const LandscapeBackground(landscapeId: 'jardin-zen'))),
      );
      expect(find.byType(ImaginaireView), findsOneWidget);
      expect(surfaces.created, hasLength(1));
      expect(model.videoRequests, isNot(contains('jardin-zen')), reason: 'a 3D scene never asks for its video on screen');
      await tester.pumpWidget(const SizedBox());
    });
  });
}
