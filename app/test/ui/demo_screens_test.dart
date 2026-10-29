// Demo build (« Eventide Démo ») texts on the Premium and Réglages screens.
import 'package:eventide/core/plan.dart';
import 'package:eventide/ui/navigation.dart';
import 'package:eventide/ui/screens/premium_screen.dart';
import 'package:eventide/ui/screens/settings_screen.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_harness.dart';
import 'fake_app_model.dart';
import 'ui_test_utils.dart';

void main() {
  setUpAll(loadAppFonts);

  testWidgets('Premium screen: « Version démo : Premium est déjà actif », nothing to buy', (tester) async {
    usePhoneView(tester);
    final model = FakeAppModel(plan: Plan.annual)..demoMode = true;
    await pumpApp(tester, model);
    await openRoute(tester, Routes.premium, (_) => const PremiumScreen());
    expect(find.text(kDemoPremiumNote), findsOneWidget);
    expect(findCaps('Premium est déjà actif'), findsOneWidget);
    expect(find.bySemanticsLabel('Version démo : Premium est déjà actif'), findsOneWidget);
    // Every plan card shows the same disabled button.
    await tester.tap(find.bySemanticsLabel(RegExp('^Mensuel')));
    await settle(tester);
    expect(find.text(kDemoPremiumNote), findsOneWidget);
    await tester.tap(findCaps('Premium est déjà actif'));
    await settle(tester);
    expect(model.calls.where((c) => c.startsWith('buy')), isEmpty);
    // « Restaurer » only asks the model (which answers with its demo message).
    await tester.ensureVisible(find.text('Restaurer mes achats'));
    await tester.tap(find.text('Restaurer mes achats'));
    await settle(tester);
    expect(model.calls, contains('restorePurchases'));
    expect(find.text('Achats vérifiés'), findsNothing);
    await tearDownApp(tester);
  });

  testWidgets('Réglages: discreet « Version démo », no Google Play subscription button', (tester) async {
    usePhoneView(tester);
    final model = FakeAppModel(plan: Plan.annual)..demoMode = true;
    await pumpApp(tester, model);
    await openRoute(tester, Routes.settings, (_) => const SettingsScreen());
    expect(find.text('Version démo'), findsOneWidget);
    expect(findCaps('Abonnement · Version démo'), findsOneWidget);
    expect(find.text(kDemoPremiumNote), findsOneWidget);
    expect(findCaps('Gérer sur Google Play'), findsNothing);
    await tearDownApp(tester);
  });

  testWidgets('a normal Premium user sees neither', (tester) async {
    usePhoneView(tester);
    final model = FakeAppModel(plan: Plan.annual);
    await pumpApp(tester, model);
    await openRoute(tester, Routes.settings, (_) => const SettingsScreen());
    expect(find.text('Version démo'), findsNothing);
    expect(findCaps('Gérer sur Google Play'), findsOneWidget);
    await tearDownApp(tester);
  });
}
