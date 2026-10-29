// Screen 12 · Réglages: subscription first, then Écoute, Confort, Compte.
import 'package:flutter/material.dart';

import '../../app/app_model.dart';
import '../../core/plan.dart';
import '../../core/problem_report.dart' show exitSummary;
import '../model_scope.dart';
import '../navigation.dart';
import '../theme/vitre.dart';
import '../widgets/glass.dart';
import '../widgets/sheet_scaffold.dart';
import '../widgets/toast.dart';
import '../widgets/vicons.dart';
import 'premium_screen.dart' show kDemoPremiumNote, offerFor;

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
            onTap: () => Nav.schedules(context),
          ),
          SwitchRow(
            title: 'Écran noir pendant le minuteur',
            value: settings.blackScreenDuringTimer,
            onChanged: (v) => model.updateSettings(
              settings.copyWith(blackScreenDuringTimer: v),
            ),
          ),
          SwitchRow(
            title: 'Télécharger en Wi-Fi seulement',
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
            value: settings.highContrast,
            onChanged: (v) =>
                model.updateSettings(settings.copyWith(highContrast: v)),
          ),
          const SectionLabel('Compte'),
          if (!model.signedIn)
            LinkRow(
              title: 'Se connecter avec Google',
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
              // Demo build: the model already said that there is nothing to restore.
              if (!model.demoMode) toasts?.show('Achats vérifiés');
            },
          ),
          LinkRow(
            title: 'Confidentialité',
            onTap: () => Nav.privacy(context),
          ),
          _ProblemReportRow(model: model),
          const SizedBox(height: 18),
          Text(
            'Eventide · Version 1.0',
            textAlign: TextAlign.center,
            style: VitreType.small(size: 13, color: p.text(0.56)),
          ),
          if (model.demoMode)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                'Version démo',
                textAlign: TextAlign.center,
                style: VitreType.small(size: 13, color: p.text(0.5)),
              ),
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
        CapsText(
          'Version gratuite',
          style: VitreType.eyebrow(color: p.text(0.74)),
        ),
        const SizedBox(height: 6),
        Text('Passez à Premium', style: VitreType.title(size: 30)),
        const SizedBox(height: 16),
        PrimaryButton(
          label: 'Essayer 3 jours gratuits',
          onPressed: () => Nav.premium(context),
        ),
        const SizedBox(height: 10),
        Text(
          'Puis ${annual.price} par an. Annulable à tout moment.',
          textAlign: TextAlign.center,
          style: VitreType.small(color: p.text(0.74)),
        ),
      ]);
    } else {
      final planName = model.demoMode
          ? 'Version démo'
          : switch (plan) {
              Plan.annual => 'Annuel',
              Plan.monthly => 'Mensuel',
              Plan.lifetime => 'À vie',
              Plan.free => 'Version gratuite',
            };
      final String status;
      if (model.demoMode) {
        status = kDemoPremiumNote;
      } else if (plan == Plan.lifetime) {
        status = 'Payé une fois, sans abonnement.';
      } else if (e.expiresAt == null) {
        status = 'Abonnement actif.';
      } else if (e.autoRenewing) {
        status = 'Renouvelé le ${_date(e.expiresAt!)}.';
      } else {
        status = 'Se termine le ${_date(e.expiresAt!)}, sans renouvellement.';
      }
      children.addAll([
        CapsText(
          'Abonnement · $planName',
          style: VitreType.eyebrow(color: p.text(0.74)),
        ),
        const SizedBox(height: 6),
        Text('Premium', style: VitreType.title(size: 30)),
        const SizedBox(height: 6),
        Text(status, style: VitreType.small(size: 14, color: p.text(0.82))),
        const SizedBox(height: 14),
        // Demo build and lifetime: nothing to manage on Google Play.
        if (model.demoMode || plan == Plan.lifetime)
          const SizedBox.shrink()
        else
          SecondaryButton(
            label: 'Gérer sur Google Play',
            semanticLabel: 'Gérer mon abonnement sur Google Play',
            onPressed: model.openManageSubscription,
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

/// « Signaler un problème »: the last abnormal end of the app (if Android recorded one) and the
/// plain-text report, shared only if the user wants (docs/app/architecture.md « Rapport de
/// problème »).
class _ProblemReportRow extends StatelessWidget {
  const _ProblemReportRow({required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final last = model.lastAbnormalExit;
    return LinkRow(
      title: 'Signaler un problème',
      subtitle: last == null ? null : 'Dernier arrêt : ${exitSummary(last)}',
      onTap: () async {
        final toasts = ToastHost.maybeOf(context);
        final shared = await model.shareProblemReport();
        if (!shared) toasts?.show('Rapport impossible. Réessayez.');
      },
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
              style: VitreType.label(size: size),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
        decoration: BoxDecoration(
          color: p.fill(0.07),
          borderRadius: BorderRadius.circular(22),
        ),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                liveRegion: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Taille du texte', style: VitreType.label()),
                    const SizedBox(height: 2),
                    Text(
                      s.textSizeLabel,
                      style: VitreType.small(color: p.text(0.7)),
                    ),
                  ],
                ),
              ),
            ),
            button('A−', 15, 'Réduire le texte', -1),
            const SizedBox(width: 8),
            button('A+', 20, 'Agrandir le texte', 1),
          ],
        ),
      ),
    );
  }
}
