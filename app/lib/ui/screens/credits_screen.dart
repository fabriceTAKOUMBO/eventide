// Crédits d’assistant (not in the mockup): for lifetime buyers, whose plan has no
// voice assistant included.
import 'package:flutter/material.dart';

import '../model_scope.dart';
import '../theme/vitre.dart';
import '../widgets/glass.dart';
import '../widgets/sheet_scaffold.dart';
import '../widgets/vicons.dart';

class CreditsScreen extends StatefulWidget {
  const CreditsScreen({super.key});

  @override
  State<CreditsScreen> createState() => _CreditsScreenState();
}

class _CreditsScreenState extends State<CreditsScreen> {
  bool _buying = false;

  Future<void> _buy() async {
    setState(() => _buying = true);
    try {
      await context.readModel.buyCredits();
    } finally {
      if (mounted) setState(() => _buying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final p = Vitre.of(context);
    final credits = model.entitlements.voice.creditsRemaining;
    return VitreSheet(
      title: 'Crédits d’assistant',
      top: 96,
      panelAlpha: 0.72,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GlassCard(
            child: Row(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: const BoxDecoration(
                    color: VitreColors.white,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: const VIcon(
                    VIcons.mic,
                    size: 28,
                    color: VitreColors.ink,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Demandes restantes',
                        style: manrope(17, weight: 600, color: p.text(0.78)),
                      ),
                      Text(
                        '$credits',
                        style: manrope(40, weight: 300, height: 1.1),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          SheetText(
            'Votre achat à vie comprend tout, sauf l’assistant vocal. Un pack de crédits vous permet de régler l’application en parlant.',
          ),
          const SizedBox(height: 12),
          SheetText(
            'Chaque demande utilise un crédit. Les réglages simples, comme « pause » ou « plus fort », restent gratuits.',
            size: 17,
            alpha: 0.78,
          ),
          const SizedBox(height: 26),
          PrimaryButton(
            label: 'Acheter un pack de crédits',
            busy: _buying,
            onPressed: _buy,
          ),
          const SizedBox(height: 12),
          Text(
            'Le prix s’affiche dans Google Play avant de payer.',
            textAlign: TextAlign.center,
            style: manrope(16, color: p.text(0.72)),
          ),
        ],
      ),
    );
  }
}
