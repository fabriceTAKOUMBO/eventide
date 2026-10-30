// Simple guide for manufacturers that stop apps in background (dossier, screen 9).
import 'package:flutter/material.dart';

import '../model_scope.dart';
import '../theme/vitre.dart';
import '../widgets/glass.dart';
import '../widgets/sheet_scaffold.dart';

// Menu paths in the words of each phone (« › » between menus).
const List<(String, List<String>)> _brands = [
  (
    'Samsung',
    [
      'Paramètres › Applications › Full Relax',
      'Batterie › « Non restreinte »',
    ],
  ),
  (
    'Xiaomi, Redmi, Poco',
    [
      'Paramètres › Applications › Gérer les applications › Full Relax',
      'Économiseur de batterie › « Aucune restriction »',
      'Activez « Démarrage automatique »',
    ],
  ),
  (
    'Huawei, Honor',
    [
      'Paramètres › Batterie › Lancement d’applications',
      'Full Relax : désactivez la gestion automatique, laissez tout activé',
    ],
  ),
  (
    'Oppo, OnePlus, Realme',
    [
      'Paramètres › Batterie › Plus de paramètres (ou Optimisation)',
      'Full Relax › « Ne pas optimiser » (ou « Autoriser l’activité en arrière-plan »)',
    ],
  ),
  (
    'Autres téléphones',
    [
      'Paramètres › Applications › Full Relax › Batterie',
      '« Sans restriction »',
    ],
  ),
];

class BatteryGuideScreen extends StatelessWidget {
  const BatteryGuideScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final p = Vitre.of(context);
    return VitreSheet(
      title: 'Si le son ne démarre pas',
      titleSize: 28,
      top: 70,
      panelAlpha: 0.74,
      backgroundBrightness: 0.5,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetText(
            'Laissez Full Relax fonctionner en arrière-plan :',
          ),
          const SizedBox(height: 14),
          for (final (brand, steps) in _brands)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: GlassCard(
                radius: 24,
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      header: true,
                      child: CapsText(
                        brand,
                        style: VitreType.eyebrow(color: p.text(0.74)),
                      ),
                    ),
                    const SizedBox(height: 8),
                    for (var i = 0; i < steps.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 26,
                              child: Text(
                                '${i + 1}.',
                                style: VitreType.label(
                                  size: 15,
                                  color: p.text(0.84),
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                steps[i],
                                style: VitreType.body(color: p.text(0.86)),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 8),
          // Opens the app's page in Android settings (first step of every guide).
          PrimaryButton(
            label: 'Ouvrir les réglages',
            onPressed: () => context.readModel.openBatteryGuide(),
          ),
        ],
      ),
    );
  }
}
