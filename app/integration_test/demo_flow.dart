// The demo user flow, shared by the on-device integration test (demo_flow_test.dart, real app
// and plugins, CI emulators) and its host twin (test/app/demo_flow_host_test.dart, the real
// RealAppModel and UI on fake services), so that every step is also checked without a device.
//
//   Bienvenue « Commencer » → Accueil play/pause → Mon mix: a Premium sound → Paysages: a
//   Premium landscape → Réglages → Programmations: a schedule two to three minutes ahead →
//   Réglages « Version démo » → Accueil, nothing loaded.
//
// The caller pumps EventideApp with reduced motion (procedural landscapes and decor tickers
// stand still, so frames settle) before calling runDemoFlow.
import 'package:eventide/app/app_controller.dart';
import 'package:eventide/core/catalog.dart';
import 'package:eventide/core/plan.dart';
import 'package:eventide/core/schedule.dart';
import 'package:eventide/services/native_bridge.dart';
import 'package:eventide/ui/screens/home/home_screen.dart';
import 'package:eventide/ui/screens/landscapes_sheet.dart';
import 'package:eventide/ui/screens/mix_sheet.dart';
import 'package:eventide/ui/screens/premium_screen.dart';
import 'package:eventide/ui/screens/schedule_editor_screen.dart';
import 'package:eventide/ui/screens/schedules_screen.dart';
import 'package:eventide/ui/screens/settings_screen.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// What the flow observed (the device test reports it in logcat for the workflow).
class DemoFlowResult {
  DemoFlowResult({required this.audioPlayed, required this.schedule, required this.scheduleAt});

  /// False when the sound could not start (no audio output on a headless emulator).
  final bool audioPlayed;
  final Schedule schedule;
  final DateTime scheduleAt;
}

/// Pumps frames until [condition] holds.
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  required String what,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final end = DateTime.now().add(timeout);
  var pumps = 0;
  while (!condition()) {
    // Real time on a device; on the host each pump also advances the fake clock by 200 ms.
    if (DateTime.now().isAfter(end) || pumps > timeout.inMilliseconds ~/ 200) {
      fail('Timed out after ${timeout.inSeconds} s waiting for $what');
    }
    await tester.pump(const Duration(milliseconds: 200));
    pumps++;
  }
}

/// A few frames: routes keep their duration even when transitions are instant.
Future<void> settle(WidgetTester tester, [int frames = 6]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

bool present(Finder finder) => finder.evaluate().isNotEmpty;

Future<void> tapWhenPresent(WidgetTester tester, Finder finder, String what) async {
  await pumpUntil(tester, () => present(finder), what: what);
  await tester.ensureVisible(finder.first);
  await settle(tester, 2);
  await tester.tap(finder.first);
  await settle(tester);
}

/// Taps an item of a lazily built list inside [container], scrolling it into view first.
Future<void> tapInList(WidgetTester tester, Finder finder, Finder container, String what) async {
  await pumpUntil(tester, () => present(container), what: '$what (list)');
  await tester.scrollUntilVisible(
    finder,
    120,
    scrollable: find.descendant(of: container, matching: find.byType(Scrollable)).first,
  );
  await settle(tester, 2);
  await tester.tap(finder.first);
  await settle(tester);
}

void popRoute(WidgetTester tester) => tester.state<NavigatorState>(find.byType(Navigator).first).pop();

Future<DemoFlowResult> runDemoFlow(
  WidgetTester tester,
  RealAppModel model, {
  required Future<void> Function() stopPlayback,
  void Function(String line) report = _ignore,
}) async {
  // ---- Demo build: Premium on the phone.
  expect(
    model.demoMode,
    isTrue,
    reason: 'demo mode is off: build with --dart-define=DEMO_MODE=true AND --android-project-arg=eventide.demo=true',
  );
  expect(model.plan, Plan.annual);
  expect(model.entitlements.premium, isTrue);
  report('demo_mode=on plan=${model.plan.name}');

  // ---- 1. Bienvenue → « Commencer » (already done if this install was used before). Buttons
  // are drawn in capitals: found by their TalkBack label, which keeps the words as written.
  final start = find.bySemanticsLabel('Commencer');
  await pumpUntil(
    tester,
    () => present(start) || present(find.byType(HomeScreen)),
    what: 'the first screen',
  );
  if (present(start)) {
    await tapWhenPresent(tester, start, '« Commencer »');
  }
  await pumpUntil(tester, () => present(find.byType(HomeScreen)), what: 'Accueil');
  expect(model.onboarded, isTrue);

  // ---- 2. Accueil: play, then pause. A headless emulator may have no audio output: the start
  // then fails, and the app must stay usable and say so (never crash).
  await tapWhenPresent(tester, find.bySemanticsLabel('Lancer la lecture'), 'the play button');
  await settle(tester, 3);
  await pumpUntil(tester, () => !model.loadingAudio, what: 'the audio start', timeout: const Duration(seconds: 40));
  final audioPlayed = model.playing;
  if (audioPlayed) {
    report('audio=playing');
    await tapWhenPresent(tester, find.bySemanticsLabel('Mettre en pause'), 'the pause button');
    await pumpUntil(tester, () => !model.playing, what: 'pause');
  } else {
    report('audio=unavailable (the sound could not start on this device; the UI stays usable)');
  }
  expect(present(find.bySemanticsLabel('Lancer la lecture')), isTrue);

  // ---- 3. Mon mix: a Premium sound, without the Premium screen.
  await tapWhenPresent(tester, find.bySemanticsLabel('Régler mon mix : sons, musique et décor'), 'Mon mix');
  await tapInList(tester, find.bySemanticsLabel('Ajouter vagues'), find.byType(MixSheet), '« Ajouter vagues »');
  await pumpUntil(tester, () => model.scene.hasLayer(LayerKind.son, 'vagues'), what: 'vagues in the mix');
  expect(present(find.byType(PremiumScreen)), isFalse, reason: 'Premium is unlocked in the demo');
  report('premium_sound=vagues');
  popRoute(tester);
  await settle(tester);

  // ---- 4. Paysages: a Premium landscape.
  await tapWhenPresent(tester, find.bySemanticsLabel('Choisir un paysage'), 'Paysages');
  await pumpUntil(tester, () => present(find.byType(LandscapesSheet)), what: 'the landscapes sheet');
  // Nature has one (free) landscape: the Premium one is in « Urbain » (a filmed storm).
  await tapWhenPresent(
    tester,
    find.descendant(of: find.byType(LandscapesSheet), matching: find.bySemanticsLabel('Urbain')),
    'the Urbain tab',
  );
  await tapWhenPresent(tester, find.bySemanticsLabel(RegExp(r'^Pluie sur la ville')), 'Pluie sur la ville');
  await pumpUntil(tester, () => model.scene.landscapeId == 'pluie-ville', what: 'the Premium landscape');
  expect(present(find.byType(PremiumScreen)), isFalse);
  await pumpUntil(tester, () => !present(find.byType(LandscapesSheet)), what: 'the sheet to close');
  report('premium_landscape=pluie-ville');

  // ---- 5. Réglages → Programmations: a new schedule, then moved two to three minutes ahead
  // (the editor moves by 5 minutes).
  await tapWhenPresent(tester, find.bySemanticsLabel('Réglages'), 'Réglages');
  await pumpUntil(tester, () => present(find.byType(SettingsScreen)), what: 'Réglages');
  await tapWhenPresent(tester, find.text('Programmations'), 'Programmations');
  await pumpUntil(tester, () => present(find.byType(SchedulesScreen)), what: 'Programmations');
  final before = model.schedules.length;
  await tapWhenPresent(tester, find.bySemanticsLabel('Ajouter une programmation'), '« Ajouter une programmation »');
  await pumpUntil(tester, () => present(find.byType(ScheduleEditorScreen)), what: 'the schedule editor');
  await tapWhenPresent(tester, find.bySemanticsLabel('Enregistrer'), '« Enregistrer »');
  // Notifications not seen as granted yet: « Plus tard » (a test cannot answer Android's dialog).
  if (present(find.text('Plus tard'))) {
    await tapWhenPresent(tester, find.text('Plus tard'), '« Plus tard »');
  }
  await pumpUntil(tester, () => model.schedules.length == before + 1, what: 'the saved schedule');
  await pumpUntil(tester, () => !present(find.byType(ScheduleEditorScreen)), what: 'the editor to close');

  final now = DateTime.now();
  final at = DateTime(now.year, now.month, now.day, now.hour, now.minute).add(const Duration(minutes: 3));
  final draft = model.schedules.last;
  expect(draft.landscapeId, 'pluie-ville', reason: 'a new schedule starts on the current landscape');
  final schedule = draft.copyWith(hour: at.hour, minute: at.minute, days: Schedule.everyDay, rampMinutes: 5);
  expect(await model.saveSchedule(schedule), isTrue);
  await settle(tester);
  expect(model.nextScheduledStart, at);
  expect(model.alarmMode, isNot(AlarmMode.none), reason: 'the native side must arm an alarm');
  report(
    'schedule_id=${schedule.id} schedule_at_ms=${at.millisecondsSinceEpoch} '
    'alarm_mode=${model.alarmMode.name} exact_allowed=${model.exactAlarmAllowed}',
  );
  popRoute(tester); // Programmations → Réglages
  await settle(tester);

  // ---- 6. Réglages: the discreet « Version démo » mention, no purchase.
  await pumpUntil(tester, () => present(find.byType(SettingsScreen)), what: 'Réglages again');
  expect(find.text('Version démo'), findsOneWidget);
  expect(find.textContaining('Version démo : Premium est déjà actif'), findsWidgets);
  popRoute(tester); // Réglages → Accueil
  await settle(tester);
  expect(present(find.byType(HomeScreen)), isTrue);

  // Nothing loaded any more, so that the scheduled start plays its own landscape and ramp.
  await stopPlayback();
  await settle(tester);
  report('flow=ok');
  return DemoFlowResult(audioPlayed: audioPlayed, schedule: schedule, scheduleAt: at);
}

void _ignore(String line) {}
