// Demo build (« Eventide Démo »): Premium unlocked on the phone, for showing and testing the app
// without Google Play or a backend. See docs/app/architecture.md, « Version démo ».
//
// It can never be confused with production: the Android build must be made with the Gradle
// property `eventide.demo=true` (separate package `be.cinaf.eventide.demo`, launcher label
// « Eventide Démo », manifest flag read by NativeBridge.isDemoBuild()) AND the Dart side must be
// compiled with `--dart-define=DEMO_MODE=true`. A production package built by mistake with the
// dart-define stays a normal app.
import '../core/plan.dart';

abstract final class DemoMode {
  /// Demo mode is on only when both the dart-define and the native build flag say so.
  static bool resolve({required bool requested, required bool nativeDemoBuild}) =>
      requested && nativeDemoBuild;

  /// Plan forced in demo mode: annual, i.e. Premium with the voice assistant included.
  static const Plan plan = Plan.annual;

  /// Entitlements forced in demo mode, whatever is cached or answered by a server.
  static const Entitlements entitlements = Entitlements(
    plan: plan,
    premium: true,
    voice: VoiceQuota(mode: VoiceMode.included),
  );

  /// Shown on purchase buttons and the Premium screen.
  static const String premiumActive = 'Version démo : Premium est déjà actif.';

  /// « Restaurer mes achats » in demo mode.
  static const String nothingToRestore = 'Version démo : Premium est déjà actif, il n’y a rien à restaurer.';

  /// Discreet mention at the bottom of Réglages.
  static const String settingsMention = 'Version démo';
}
