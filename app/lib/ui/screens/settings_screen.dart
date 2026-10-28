// Screen 12 · Réglages: subscription first, then Écoute, Confort, Compte.
import 'package:flutter/material.dart';

import '../../app/app_model.dart';
import '../../core/plan.dart';
import '../model_scope.dart';
import '../navigation.dart';
import '../theme/vitre.dart';
import '../widgets/glass.dart';
import '../widgets/permission_dialog.dart' show showVitreDialog;
import '../widgets/sheet_scaffold.dart';
import '../widgets/toast.dart';
import '../widgets/vicons.dart';
import 'premium_screen.dart' show offerFor;

const List<String> _months = [
  'janvier',
  'février',
  'mars',
  'avril',
  'mai',
  'juin',
  'juillet',
  'août',
  'septembre',
  'octobre',
  'novembre',
  'décembre',
];

String _date(DateTime d) {
  final l = d.toLocal();
  return '${l.day} ${_months[l.month - 1]} ${l.year}';
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final p = Vitre.of(context);
    final settings = model.settings;
    final premium = model.plan.isPremium;

    return VitreSheet(
      title: 'Réglages',
      top: 70,
      panelAlpha: 0.72,
      backgroundBrightness: 0.55,
      contentPadding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 6),
          _SubscriptionCard(model: model),
          const SectionLabel('Écoute'),
          LinkRow(
            title: 'Programmations',
            subtitle: 'Démarrer un son chaque jour à l’heure choisie',
            onTap: () => Nav.schedules(context),
          ),
          SwitchRow(
            title: 'Écran noir pendant le minuteur',
            subtitle: 'Pour ne pas être gêné la nuit',
            value: settings.blackScreenDuringTimer,
            onChanged: (v) => model.updateSettings(
              settings.copyWith(blackScreenDuringTimer: v),
            ),
          ),
          SwitchRow(
            title: 'Téléchargements en Wi-Fi seulement',
            subtitle: premium
                ? 'Pour économiser vos données'
                : 'Avec Premium, pour l’écoute sans connexion',
            value: settings.wifiOnly,
            locked: !premium,
            onLockedTap: () => Nav.premium(context),
            onChanged: (v) =>
                model.updateSettings(settings.copyWith(wifiOnly: v)),
          ),
          const SectionLabel('Confort'),
          _TextSizeCard(model: model),
          SwitchRow(
            title: 'Contraste renforcé',
            subtitle: 'Textes et boutons plus marqués',
            value: settings.highContrast,
            onChanged: (v) =>
                model.updateSettings(settings.copyWith(highContrast: v)),
          ),
          const SectionLabel('Compte'),
          if (!model.signedIn)
            LinkRow(
              title: 'Se connecter avec Google',
              subtitle: 'Retrouver vos réglages sur un autre téléphone',
              leading: const VIcon(
                VIcons.google,
                size: 24,
                color: VitreColors.white,
              ),
              onTap: model.signInWithGoogle,
            ),
          LinkRow(
            title: 'Restaurer mes achats',
            onTap: () async {
              final toasts = ToastHost.maybeOf(context);
              await model.restorePurchases();
              toasts?.show('Vérification de vos achats terminée');
            },
          ),
          LinkRow(
            title: 'Confidentialité et données',
            onTap: () => Nav.privacy(context),
          ),
          const SizedBox(height: 14),
          Text(
            'Eventide · Version 1.0',
            textAlign: TextAlign.center,
            style: manrope(16, color: p.text(0.6)),
          ),
        ],
      ),
    );
  }
}

class _SubscriptionCard extends StatelessWidget {
  const _SubscriptionCard({required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final p = Vitre.of(context);
    final e = model.entitlements;
    final plan = e.plan;
    final children = <Widget>[];
    if (!plan.isPremium) {
      final annual = offerFor(model, PurchaseChoice.annual);
      children.addAll([
        Text(
          'Mon abonnement · Version gratuite',
          style: manrope(16, weight: 700, color: p.text(0.8)),
        ),
        const SizedBox(height: 4),
        Text(
          'Passez à Premium',
          style: manrope(27, weight: 600, letterSpacingEm: -0.015, height: 1.2),
        ),
        const SizedBox(height: 8),
        Text(
          'Tous les paysages, sans publicité, avec écoute sans connexion et assistant vocal.',
          style: manrope(17, height: 1.38, color: p.text(0.88)),
        ),
        const SizedBox(height: 16),
        PrimaryButton(
          label: 'Essayer 3 jours gratuits',
          height: 60,
          fontSize: 19,
          onPressed: () => Nav.premium(context),
        ),
        const SizedBox(height: 10),
        Text(
          'Puis ${annual.price} par an. Annulable à tout moment.',
          textAlign: TextAlign.center,
          style: manrope(16, color: p.text(0.78)),
        ),
      ]);
    } else {
      final planName = switch (plan) {
        Plan.annual => 'Annuel',
        Plan.monthly => 'Mensuel',
        Plan.lifetime => 'À vie',
        Plan.free => 'Version gratuite',
      };
      final String status;
      if (plan == Plan.lifetime) {
        status = 'Payé une fois. L’assistant vocal fonctionne avec des crédits, vendus à part.';
      } else if (e.expiresAt == null) {
        status = 'Abonnement actif.';
      } else if (e.autoRenewing) {
        status = 'Renouvelé le ${_date(e.expiresAt!)}.';
      } else {
        status = 'Se termine le ${_date(e.expiresAt!)}, sans renouvellement.';
      }
      children.addAll([
        Text(
          'Mon abonnement · $planName',
          style: manrope(16, weight: 700, color: p.text(0.8)),
        ),
        const SizedBox(height: 4),
        Text(
          'Premium',
          style: manrope(27, weight: 600, letterSpacingEm: -0.015),
        ),
        const SizedBox(height: 8),
        Text(status, style: manrope(17, height: 1.38, color: p.text(0.88))),
        const SizedBox(height: 14),
        if (plan == Plan.lifetime)
          PrimaryButton(
            label: 'Crédits d’assistant',
            height: 60,
            fontSize: 19,
            onPressed: () => Nav.credits(context),
          )
        else
          SecondaryButton(
            label: 'Gérer mon abonnement sur Google Play',
            height: 56,
            fontSize: 17,
            onPressed: () => showVitreDialog<bool>(
              context,
              icon: VIcons.settings,
              title: 'Gérer mon abonnement',
              message: 'Ouvrez l’application Google Play, touchez votre photo en haut à droite, puis « Paiements et abonnements » et « Abonnements ». Vous pouvez y changer ou annuler votre formule.',
              confirm: 'J’ai compris',
            ),
          ),
      ]);
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: LinearGradient(
          begin: const Alignment(-0.6, -1),
          end: const Alignment(0.6, 1),
          colors: [p.fill(0.2), p.fill(0.07)],
        ),
        border: Border.all(color: p.border(0.32)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x4D000000),
            blurRadius: 32,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

class _TextSizeCard extends StatelessWidget {
  const _TextSizeCard({required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final p = Vitre.of(context);
    final s = model.settings;
    Widget button(String text, double size, String label, int delta) {
      final enabled = delta < 0 ? s.textSize > 0 : s.textSize < 2;
      return Opacity(
        opacity: enabled ? 1 : 0.4,
        child: Pressable(
          onTap: enabled
              ? () => model.updateSettings(
                  s.copyWith(textSize: s.textSize + delta),
                )
              : null,
          borderRadius: BorderRadius.circular(26),
          semanticLabel: label,
          child: Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: p.fill(0.08),
              shape: BoxShape.circle,
              border: Border.all(color: p.border(0.22)),
            ),
            alignment: Alignment.center,
            child: Text(
              text,
              textScaler: TextScaler.noScaling,
              style: manrope(size, weight: 700),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          color: p.fill(0.07),
          borderRadius: BorderRadius.circular(22),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Semantics(
                    liveRegion: true,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Taille du texte',
                          style: manrope(18, weight: 700),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          s.textSizeLabel,
                          style: manrope(16, color: p.text(0.72)),
                        ),
                      ],
                    ),
                  ),
                ),
                button('A−', 16, 'Réduire le texte', -1),
                const SizedBox(width: 8),
                button('A+', 22, 'Agrandir le texte', 1),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Voici un exemple de texte.',
              style: manrope(18, weight: 500, color: p.text(0.92)),
            ),
          ],
        ),
      ),
    );
  }
}
