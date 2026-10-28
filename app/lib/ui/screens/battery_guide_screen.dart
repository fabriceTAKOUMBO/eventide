// Simple guide for manufacturers that stop apps in background (dossier, screen 9).
import 'package:flutter/material.dart';

import '../theme/vitre.dart';
import '../widgets/glass.dart';
import '../widgets/sheet_scaffold.dart';

const List<(String, List<String>)> _brands = [
  (
    'Samsung',
    [
      'Ouvrez Paramètres, puis Applications, puis Eventide.',
      'Touchez Batterie et choisissez « Non restreinte ».',
    ],
  ),
  (
    'Xiaomi, Redmi, Poco',
    [
      'Ouvrez Paramètres, puis Applications, puis Gérer les applications, puis Eventide.',
      'Touchez Économiseur de batterie et choisissez « Aucune restriction ».',
      'Activez aussi « Démarrage automatique ».',
    ],
  ),
  (
    'Huawei, Honor',
    [
      'Ouvrez Paramètres, puis Batterie, puis Lancement d’applications.',
      'Désactivez la gestion automatique d’Eventide et laissez tout activé.',
    ],
  ),
  (
    'Oppo, OnePlus, Realme',
    [
      'Ouvrez Paramètres, puis Batterie, puis Plus de paramètres ou Optimisation.',
      'Choisissez Eventide puis « Ne pas optimiser » ou « Autoriser l’activité en arrière-plan ».',
    ],
  ),
  (
    'Autres téléphones',
    [
      'Ouvrez Paramètres, puis Applications, puis Eventide, puis Batterie.',
      'Choisissez l’option qui laisse l’application fonctionner sans restriction.',
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
      titleSize: 24,
      top: 70,
      panelAlpha: 0.74,
      backgroundBrightness: 0.5,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetText(
            'Certains téléphones arrêtent les applications pour économiser la batterie. Voici comment laisser Eventide démarrer à l’heure.',
          ),
          const SizedBox(height: 16),
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
                      child: Text(brand, style: manrope(19, weight: 700)),
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
                                style: manrope(
                                  17,
                                  weight: 700,
                                  color: p.text(0.84),
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                steps[i],
                                style: manrope(
                                  17,
                                  height: 1.4,
                                  color: p.text(0.84),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          Text(
            'Les noms des menus changent selon la version d’Android.',
            textAlign: TextAlign.center,
            style: manrope(16, color: p.text(0.72)),
          ),
        ],
      ),
    );
  }
}
