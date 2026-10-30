// Screen 1 · Bienvenue: one sentence, one button. No permission is asked here.
import 'package:flutter/material.dart';

import '../landscape/landscape_background.dart';
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
            child: LandscapeBackground(
              landscapeId: landscape.id,
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
                                    style: VitreType.title(size: 42),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Sons de nature, pour se détendre et mieux dormir.',
                                  style: VitreType.body(
                                    size: 16,
                                    color: p.text(0.84),
                                  ),
                                ),
                                const SizedBox(height: 24),
                                PrimaryButton(
                                  label: 'Commencer',
                                  busy: _busy,
                                  onPressed: () =>
                                      _run(model.completeOnboarding),
                                ),
                                const SizedBox(height: 8),
                                LinkButton(
                                  label: 'J’ai déjà un compte',
                                  fontSize: 15,
                                  alpha: 1,
                                  height: 52,
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
                                    'Gratuit, sans carte bancaire',
                                    textAlign: TextAlign.center,
                                    style: VitreType.small(color: p.text(0.7)),
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
