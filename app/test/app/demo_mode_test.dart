// Demo build decisions (lib/app/demo_mode.dart) and its billing stand-in.
import 'package:eventide/app/app_model.dart';
import 'package:eventide/app/demo_mode.dart';
import 'package:eventide/core/plan.dart';
import 'package:eventide/services/billing_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DemoMode.resolve', () {
    test('on only when the dart-define and the Android demo package agree', () {
      expect(DemoMode.resolve(requested: true, nativeDemoBuild: true), isTrue);
      // Production package built by mistake with --dart-define=DEMO_MODE=true: stays normal.
      expect(DemoMode.resolve(requested: true, nativeDemoBuild: false), isFalse);
      // Demo package without the dart-define: normal app (nothing unlocked).
      expect(DemoMode.resolve(requested: false, nativeDemoBuild: true), isFalse);
      expect(DemoMode.resolve(requested: false, nativeDemoBuild: false), isFalse);
    });

    test('forced entitlements: annual Premium with the assistant included', () {
      const e = DemoMode.entitlements;
      expect(e.plan, Plan.annual);
      expect(e.premium, isTrue);
      expect(e.plan.includesAssistant, isTrue);
      expect(e.voice.mode, VoiceMode.included);
      expect(e.voice.canUseModel, isTrue);
      expect(e.expiresAt, isNull);
    });

    test('messages say « Version démo »', () {
      expect(DemoMode.premiumActive, 'Version démo : Premium est déjà actif.');
      expect(DemoMode.nothingToRestore, startsWith('Version démo'));
    });
  });

  group('DemoBilling', () {
    test('never reaches Google Play: fallback offers, unavailable; buying emits nothing', () async {
      final billing = DemoBilling();
      final events = [];
      final sub = billing.events.listen(events.add);
      await billing.initialize();
      final offers = await billing.loadOffers();
      expect(offers.map((o) => o.choice), [PurchaseChoice.annual, PurchaseChoice.monthly, PurchaseChoice.lifetime]);
      expect(offers.every((o) => !o.available), isTrue);
      await billing.buy(PurchaseChoice.annual);
      await billing.buyCredits();
      await billing.restore();
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty);
      expect(billing.creditsPrice, isNull);
      expect(billing.calls, ['buy:annual', 'credits', 'restore']);
      await sub.cancel();
    });
  });
}
