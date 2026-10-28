// Screen 1 · Bienvenue: one sentence, one button. No permission is asked here.
import 'package:flutter/material.dart';

import '../landscape/landscape_image.dart';
import '../model_scope.dart';
import '../theme/vitre.dart';
import '../widgets/brand.dart';
import '../widgets/glass.dart';

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final p = Vitre.of(context);
    final landscape =
        model.catalog.landscape(model.scene.landscapeId) ??
        model.catalog.defaultLandscape;
    final media = MediaQuery.of(context);
    return Scaffold(
      backgroundColor: VitreColors.page,
      body: Stack(
        children: [
          Positioned.fill(
            child: LandscapeImage(
              landscapeId: landscape.id,
              style: landscape.style,
              kenBurns: true,
              brightness: 0.92,
              saturation: 1.04,
            ),
          ),
          const Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x66000000),
                      Color(0x00000000),
                      Color(0x00000000),
                      Color(0x80000000),
                    ],
                    stops: [0, 0.22, 0.5, 1],
                  ),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: IntrinsicHeight(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        14,
                        media.padding.top + 40,
                        14,
                        18 + media.padding.bottom,
                      ),
                      child: Column(
                        children: [
                          const BrandLogo(size: 104),
                          const SizedBox(height: 16),
                          const Wordmark(fontSize: 40),
                          const Spacer(),
                          const SizedBox(height: 24),
                          GlassPanel(
                            padding: const EdgeInsets.fromLTRB(22, 28, 22, 16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Semantics(
                                  header: true,
                                  child: Text(
                                    'Bienvenue',
                                    style: manrope(
                                      34,
                                      weight: 600,
                                      letterSpacingEm: -0.02,
                                      height: 1.15,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  'Des sons de nature pour vous détendre et mieux dormir.',
                                  style: manrope(
                                    19,
                                    height: 1.4,
                                    color: p.text(0.84),
                                  ),
                                ),
                                const SizedBox(height: 26),
                                PrimaryButton(
                                  label: 'Commencer',
                                  busy: _busy,
                                  onPressed: () =>
                                      _run(model.completeOnboarding),
                                ),
                                const SizedBox(height: 8),
                                LinkButton(
                                  label: 'J’ai déjà un compte',
                                  fontSize: 18,
                                  alpha: 1,
                                  height: 56,
                                  onPressed: _busy
                                      ? null
                                      : () => _run(() async {
                                          await model.signInWithGoogle();
                                          if (!model.onboarded) {
                                            await model.completeOnboarding();
                                          }
                                        }),
                                ),
                                const SizedBox(height: 2),
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 6),
                                  child: Text(
                                    'Gratuit pour commencer, sans carte bancaire.',
                                    textAlign: TextAlign.center,
                                    style: manrope(16, color: p.text(0.72)),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
