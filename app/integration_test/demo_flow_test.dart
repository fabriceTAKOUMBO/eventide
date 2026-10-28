// End-to-end check of the demo build (« Eventide Démo ») on a real Android system: the CI
// emulators, Android 14 and 16 (.github/workflows/app.yml). It drives the real app, started by
// the same code as main() (startEventide), with the real plugins; the steps are in
// demo_flow.dart. It leaves the app installed and running (--keep-app-running) with a schedule
// armed two to three minutes ahead: the workflow then sends the app to the background and checks
// that the alarm fires and starts the media service (or posts the « Lancer » notification).
//
//   cp ../content/audio/sons/*.ogg assets/audio/sons/          # Premium audio, demo only
//   cp ../content/audio/musiques/*.ogg assets/audio/musiques/
//   flutter drive --driver=test_driver/integration_test.dart \
//     --target=integration_test/demo_flow_test.dart \
//     --dart-define=DEMO_MODE=true --android-project-arg=eventide.demo=true --keep-app-running
//
// Exact alarms and notifications are allowed beforehand by the workflow:
//   adb shell appops set be.cinaf.eventide.demo SCHEDULE_EXACT_ALARM allow
//   adb shell pm grant be.cinaf.eventide.demo android.permission.POST_NOTIFICATIONS
//
// Lines starting with « EVENTIDE_IT » (logcat tag flutter) are read by the workflow.
import 'package:eventide/app/bootstrap.dart';
import 'package:eventide/ui/app.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'demo_flow.dart';

void report(String line) => debugPrint('EVENTIDE_IT $line');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'demo build on Android: onboarding, play/pause, Premium sound and landscape, schedule, settings',
    timeout: const Timeout(Duration(minutes: 6)),
    (tester) async {
      // Reduced motion: Ken Burns, decor tickers and route transitions stand still.
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);

      final started = await startEventide();
      await tester.pumpWidget(EventideApp(model: started.model));
      await settle(tester);

      // The Premium audio is bundled in the demo build only (copied from content/audio by CI).
      final assets = (await AssetManifest.loadFromAssetBundle(rootBundle)).listAssets();
      expect(
        assets,
        containsAll(<String>['assets/audio/sons/vagues.ogg', 'assets/audio/musiques/harpe.ogg']),
        reason: 'the demo build bundles the Premium audio (cp ../content/audio/... first)',
      );

      await runDemoFlow(tester, started.model, stopPlayback: started.handler.stop, report: report);
    },
  );
}
