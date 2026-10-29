// Screen 13 · Hors connexion (free plan only, after a real failed attempt).
import 'package:flutter/material.dart';

import '../landscape/landscape_background.dart';
import '../model_scope.dart';
import '../navigation.dart';
import '../theme/vitre.dart';
import '../widgets/glass.dart';
import '../widgets/toast.dart';
import '../widgets/vicons.dart';

class OfflineScreen extends StatefulWidget {
  const OfflineScreen({super.key});

  @override
  State<OfflineScreen> createState() => _OfflineScreenState();
}

class _OfflineScreenState extends State<OfflineScreen> {
  bool _retrying = false;

  Future<void> _retry() async {
    final model = context.readModel;
    final toasts = ToastHost.maybeOf(context);
    final navigator = Navigator.of(context);
    setState(() => _retrying = true);
    try {
      final ok = await model.retryConnection();
      if (!ok) {
        toasts?.show('Toujours pas de connexion');
      } else if (navigator.canPop()) {
        // Shown as a pushed screen: go back where the user was.
        navigator.maybePop();
      }
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final p = Vitre.of(context);
    final landscape =
        model.catalog.landscape(model.browsedLandscapeId) ??
        model.catalog.defaultLandscape;
    final media = MediaQuery.of(context);
    return Scaffold(
      backgroundColor: VitreColors.page,
      body: Stack(
        children: [
          Positioned.fill(
            child: LandscapeBackground(
              landscapeId: landscape.id,
              style: landscape.style,
              brightness: 0.5,
              saturation: 0.35,
              blurSigma: 2,
            ),
          ),
          const Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x59000000), Color(0x00000000)],
                    stops: [0, 0.3],
                  ),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: SingleChildScrollView(
              reverse: true,
              padding: EdgeInsets.fromLTRB(
                14,
                media.padding.top + 24,
                14,
                18 + media.padding.bottom,
              ),
              child: GlassPanel(
                alpha: 0.6,
                padding: const EdgeInsets.fromLTRB(22, 30, 22, 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          color: p.fill(0.1),
                          shape: BoxShape.circle,
                          border: Border.all(color: p.border(0.24)),
                        ),
                        alignment: Alignment.center,
                        child: const VIcon(
                          VIcons.wifiOff,
                          size: 34,
                          color: VitreColors.white,
                          strokeWidth: 1.7,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Semantics(
                      header: true,
                      child: Text(
                        'Pas de connexion',
                        style: VitreType.title(size: 36),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'La version gratuite a besoin d’internet. Premium s’écoute hors connexion.',
                      style: VitreType.body(size: 16, color: p.text(0.84)),
                    ),
                    const SizedBox(height: 24),
                    PrimaryButton(
                      label: 'Réessayer',
                      busy: _retrying,
                      onPressed: _retry,
                    ),
                    const SizedBox(height: 10),
                    SecondaryButton(
                      label: 'Découvrir Premium',
                      onPressed: () => Nav.premium(context),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
