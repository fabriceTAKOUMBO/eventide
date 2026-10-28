// Routes between screens. Every screen is pushed on top of where the user came from,
// so closing always returns there (dossier § 4).
import 'package:flutter/material.dart';

import '../core/schedule.dart';
import 'screens/battery_guide_screen.dart';
import 'screens/credits_screen.dart';
import 'screens/landscapes_sheet.dart';
import 'screens/mix_sheet.dart';
import 'screens/premium_screen.dart';
import 'screens/privacy_screen.dart';
import 'screens/schedule_editor_screen.dart';
import 'screens/schedules_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/share_screen.dart';
import 'screens/sleep_screen.dart';
import 'screens/standby_screen.dart';
import 'screens/voice_screen.dart';
import 'theme/vitre.dart';

abstract final class Routes {
  static const landscapes = 'paysages';
  static const mix = 'mon-mix';
  static const voice = 'voix';
  static const share = 'partage';
  static const sleep = 'sommeil';
  static const standby = 'veille';
  static const schedules = 'programmations';
  static const scheduleEditor = 'nouvelle-programmation';
  static const premium = 'premium';
  static const settings = 'reglages';
  static const privacy = 'confidentialite';
  static const credits = 'credits';
  static const batteryGuide = 'guide-batterie';
}

/// Keeps the names of the routes on the stack (to avoid opening Premium twice…).
class RouteTracker extends NavigatorObserver {
  final List<Route<dynamic>> _stack = [];

  List<String?> get names => [for (final r in _stack) r.settings.name];
  String? get topName => _stack.isEmpty ? null : _stack.last.settings.name;
  bool contains(String name) => _stack.any((r) => r.settings.name == name);

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute) _stack.add(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _stack.remove(route);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _stack.remove(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : _stack.indexOf(oldRoute);
    if (index >= 0 && newRoute is PageRoute) {
      _stack[index] = newRoute;
    } else if (oldRoute != null) {
      _stack.remove(oldRoute);
    }
  }
}

/// Opaque page with a short fade and rise; instant with reduced motion.
class VitreRoute<T> extends PageRouteBuilder<T> {
  VitreRoute({
    required WidgetBuilder builder,
    required String name,
    this.fadeOnly = false,
  }) : super(
         settings: RouteSettings(name: name),
         transitionDuration: const Duration(milliseconds: 320),
         reverseTransitionDuration: const Duration(milliseconds: 220),
         pageBuilder: (context, animation, secondary) => builder(context),
         transitionsBuilder: (context, animation, secondary, child) {
           if (Vitre.reduceMotion(context)) return child;
           final curved = CurvedAnimation(
             parent: animation,
             curve: Curves.easeOutCubic,
             reverseCurve: Curves.easeInCubic,
           );
           if (fadeOnly) return FadeTransition(opacity: curved, child: child);
           return FadeTransition(
             opacity: curved,
             child: SlideTransition(
               position: Tween(
                 begin: const Offset(0, 0.05),
                 end: Offset.zero,
               ).animate(curved),
               child: child,
             ),
           );
         },
       );

  final bool fadeOnly;
}

/// Entry points used by the screens.
abstract final class Nav {
  static Future<T?> _push<T>(
    BuildContext context,
    String name,
    WidgetBuilder builder, {
    bool fadeOnly = false,
  }) => Navigator.of(context)
      .push<T>(VitreRoute<T>(builder: builder, name: name, fadeOnly: fadeOnly));

  static Future<void> landscapes(BuildContext context) =>
      _push(context, Routes.landscapes, (_) => const LandscapesSheet());

  /// Picker mode for a schedule: returns the chosen landscape id.
  static Future<String?> pickLandscape(
    BuildContext context,
    String selectedId,
  ) => _push<String>(
    context,
    Routes.landscapes,
    (_) => LandscapesSheet(pickFor: selectedId),
  );

  static Future<void> mix(BuildContext context) =>
      _push(context, Routes.mix, (_) => const MixSheet());
  static Future<void> voice(BuildContext context) =>
      _push(context, Routes.voice, (_) => const VoiceScreen());
  static Future<void> share(BuildContext context) =>
      _push(context, Routes.share, (_) => const ShareScreen());
  static Future<void> sleep(BuildContext context) =>
      _push(context, Routes.sleep, (_) => const SleepScreen());
  static Future<void> standby(BuildContext context) => _push(
    context,
    Routes.standby,
    (_) => const StandbyScreen(),
    fadeOnly: true,
  );
  static Future<void> schedules(BuildContext context) =>
      _push(context, Routes.schedules, (_) => const SchedulesScreen());
  static Future<void> scheduleEditor(
    BuildContext context, {
    Schedule? existing,
  }) => _push(
    context,
    Routes.scheduleEditor,
    (_) => ScheduleEditorScreen(existing: existing),
  );
  static Future<void> premium(BuildContext context) =>
      _push(context, Routes.premium, (_) => const PremiumScreen());
  static Future<void> settings(BuildContext context) =>
      _push(context, Routes.settings, (_) => const SettingsScreen());
  static Future<void> privacy(BuildContext context) =>
      _push(context, Routes.privacy, (_) => const PrivacyScreen());
  static Future<void> credits(BuildContext context) =>
      _push(context, Routes.credits, (_) => const CreditsScreen());
  static Future<void> batteryGuide(BuildContext context) =>
      _push(context, Routes.batteryGuide, (_) => const BatteryGuideScreen());
}
