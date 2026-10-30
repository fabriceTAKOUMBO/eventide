// Entry widget of the UI. `main.dart` calls `runApp(EventideApp(model: controller))`.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app_model.dart';
import '../core/settings.dart';
import 'landscape/landscape_image.dart';
import 'model_scope.dart';
import 'navigation.dart';
import 'screens/home/home_screen.dart';
import 'screens/offline_screen.dart';
import 'screens/premium_screen.dart';
import 'screens/standby_screen.dart';
import 'screens/welcome_screen.dart';
import 'theme/vitre.dart';
import 'widgets/toast.dart';

class EventideApp extends StatefulWidget {
  const EventideApp({super.key, required this.model});

  final AppModel model;

  @override
  State<EventideApp> createState() => _EventideAppState();
}

class _EventideAppState extends State<EventideApp> {
  final GlobalKey<NavigatorState> _navigator = GlobalKey<NavigatorState>();
  final RouteTracker _routes = RouteTracker();
  final ToastController _toasts = ToastController();
  StreamSubscription<AppEvent>? _events;
  late AppSettings _settings;

  @override
  void initState() {
    super.initState();
    _settings = widget.model.settings;
    widget.model.addListener(_onModelChanged);
    _listen();
    _usePosters();
    LandscapeImages.discoverAssets();
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    );
  }

  @override
  void didUpdateWidget(EventideApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.model != widget.model) {
      oldWidget.model.removeListener(_onModelChanged);
      widget.model.addListener(_onModelChanged);
      _settings = widget.model.settings;
      _events?.cancel();
      _listen();
      _usePosters();
    }
  }

  /// Posters downloaded for Premium (bundled ones are found from the asset manifest), and the
  /// videos on the content server (the published catalog's, contract § 13).
  void _usePosters() {
    final model = widget.model;
    LandscapeImages.resolver = (id) {
      final path = model.landscapePosterFile(id);
      return path == null ? null : FileImage(File(path));
    };
    LandscapeImages.remoteVideos = () => model.remoteLandscapeVideos;
  }

  /// Only the settings (text size, contrast) change the app shell.
  void _onModelChanged() {
    final settings = widget.model.settings;
    if (settings != _settings) setState(() => _settings = settings);
  }

  void _listen() {
    _events = widget.model.events.listen(_onEvent);
  }

  @override
  void dispose() {
    widget.model.removeListener(_onModelChanged);
    _events?.cancel();
    _toasts.dispose();
    super.dispose();
  }

  void _open(String name, WidgetBuilder builder, {bool fadeOnly = false}) {
    final nav = _navigator.currentState;
    if (nav == null || _routes.topName == name) return;
    if (_routes.contains(name)) {
      nav.popUntil((r) => r.settings.name == name);
      return;
    }
    nav.push(
      VitreRoute<void>(builder: builder, name: name, fadeOnly: fadeOnly),
    );
  }

  void _onEvent(AppEvent event) {
    final model = widget.model;
    switch (event) {
      case OpenPremiumEvent():
        _open(Routes.premium, (_) => const PremiumScreen());
      case OpenStandbyEvent():
        _open(Routes.standby, (_) => const StandbyScreen(), fadeOnly: true);
      case OfflineEvent():
        // Never interrupt a sound already playing; otherwise show « Hors connexion »
        // in place of the home screen.
        if (!model.playing && !model.rules.offlineAllowed(model.plan)) {
          _navigator.currentState?.popUntil((r) => r.isFirst);
        } else {
          _toasts.show('Pas de connexion');
        }
      case ToastEvent(:final message):
        _toasts.show(message);
      case SharedMixOpenedEvent(:final lockedItems):
        _navigator.currentState?.popUntil((r) => r.isFirst);
        _toasts.show(
          lockedItems == 0
              ? 'Mix reçu'
              : lockedItems == 1
              ? 'Mix reçu · 1 élément réservé à Premium'
              : 'Mix reçu · $lockedItems éléments réservés à Premium',
          check: lockedItems == 0,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    return MaterialApp(
      title: 'Full Relax',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigator,
      navigatorObservers: [_routes],
      theme: vitreMaterialTheme(),
      color: VitreColors.page,
      builder: (context, child) {
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            textScaler: MultipliedTextScaler(
              media.textScaler,
              settings.textScale,
            ),
          ),
          child: Vitre(
            palette: VitrePalette(highContrast: settings.highContrast),
            child: ModelScope(
              model: widget.model,
              child: ToastHost(
                controller: _toasts,
                child: Stack(
                  children: [
                    Positioned.fill(child: child ?? const SizedBox.shrink()),
                    ToastOverlay(controller: _toasts),
                  ],
                ),
              ),
            ),
          ),
        );
      },
      home: const RootGate(),
    );
  }
}

/// First screen: Bienvenue once, Hors connexion for the free plan without network
/// (never while a sound plays), otherwise the home screen.
class RootGate extends StatelessWidget {
  const RootGate({super.key});

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final Widget screen;
    if (!model.onboarded) {
      screen = const WelcomeScreen(key: ValueKey('welcome'));
    } else if (!model.online &&
        !model.rules.offlineAllowed(model.plan) &&
        !model.playing) {
      screen = const OfflineScreen(key: ValueKey('offline'));
    } else {
      screen = const HomeScreen(key: ValueKey('home'));
    }
    return AnimatedSwitcher(
      duration: motion(context, const Duration(milliseconds: 400)),
      child: screen,
    );
  }
}
