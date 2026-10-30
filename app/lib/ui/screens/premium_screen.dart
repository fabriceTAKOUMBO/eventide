// Screen 11 · Premium: what you gain, three plans (annual preselected), one button
// whose text follows the chosen plan.
import 'package:flutter/material.dart';

import '../../app/app_model.dart';
import '../../core/plan.dart';
import '../model_scope.dart';
import '../theme/vitre.dart';
import '../widgets/glass.dart';
import '../widgets/sheet_scaffold.dart';
import '../widgets/toast.dart';
import '../widgets/vicons.dart';

/// Dossier prices, used only when Google Play has not answered.
const Map<PurchaseChoice, String> kFallbackPrices = {
  PurchaseChoice.annual: '59,99 €',
  PurchaseChoice.monthly: '7,99 €',
  PurchaseChoice.lifetime: '79,99 €',
};

ProductOffer offerFor(AppModel model, PurchaseChoice choice) {
  for (final o in model.offers) {
    if (o.choice == choice) return o;
  }
  return ProductOffer(
    choice: choice,
    price: kFallbackPrices[choice]!,
    available: false,
    hasFreeTrial: choice == PurchaseChoice.annual,
  );
}

/// Button text and note of the Premium screen for a plan (mockup wording).
({String cta, String note}) premiumCallToAction(ProductOffer offer) {
  if (!offer.available) {
    return (
      cta: _ctaLabel(offer),
      note: 'Indisponible pour le moment. Réessayez plus tard.',
    );
  }
  return switch (offer.choice) {
    PurchaseChoice.annual =>
      offer.hasFreeTrial
          ? (
              cta: 'Essayer 3 jours gratuits',
              note:
                  '3 jours gratuits, puis ${offer.price} par an. Annulable à tout moment.',
            )
          : (
              cta: 'S’abonner',
              note: '${offer.price} par an, annulable à tout moment.',
            ),
    PurchaseChoice.monthly => (
      cta: 'S’abonner',
      note: '${offer.price} par mois, annulable à tout moment.',
    ),
    PurchaseChoice.lifetime => (
      cta: 'Acheter une fois',
      note: '${offer.price} en une seule fois, sans abonnement.',
    ),
  };
}

/// Demo build (« Full Relax Démo »): what the purchase button and the note say instead.
const String kDemoPremiumButton = 'Premium est déjà actif';
const String kDemoPremiumNote = 'Version démo : Premium est déjà actif.';

String _ctaLabel(ProductOffer offer) => switch (offer.choice) {
  PurchaseChoice.annual =>
    offer.hasFreeTrial ? 'Essayer 3 jours gratuits' : 'S’abonner',
  PurchaseChoice.monthly => 'S’abonner',
  PurchaseChoice.lifetime => 'Acheter une fois',
};

class PremiumScreen extends StatefulWidget {
  const PremiumScreen({super.key});

  @override
  State<PremiumScreen> createState() => _PremiumScreenState();
}

class _PremiumScreenState extends State<PremiumScreen> {
  PurchaseChoice _choice = PurchaseChoice.annual;
  bool _buying = false;
  bool _restoring = false;

  Plan _planOf(PurchaseChoice c) => switch (c) {
    PurchaseChoice.annual => Plan.annual,
    PurchaseChoice.monthly => Plan.monthly,
    PurchaseChoice.lifetime => Plan.lifetime,
  };

  Future<void> _buy() async {
    setState(() => _buying = true);
    try {
      await context.readModel.buy(_choice);
    } finally {
      if (mounted) setState(() => _buying = false);
    }
  }

  Future<void> _restore() async {
    final toasts = ToastHost.maybeOf(context);
    final demo = context.readModel.demoMode;
    setState(() => _restoring = true);
    try {
      // Demo build: the model answers with its own message, nothing is checked.
      await context.readModel.restorePurchases();
      if (!demo) toasts?.show('Vérification de vos achats terminée');
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final p = Vitre.of(context);
    final offer = offerFor(model, _choice);
    final demo = model.demoMode;
    final current = model.plan == _planOf(_choice);
    final action = premiumCallToAction(offer);

    return VitreSheet(
      title: 'Premium',
      titleSize: 36,
      top: 60,
      headerTop: 24,
      panelAlpha: 0.72,
      backgroundBrightness: 0.55,
      contentPadding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final text in const [
            'Tous les paysages',
            'Tous les sons et mélodies',
            'Favoris et programmations illimités',
            'Écoute hors connexion',
            'Sans publicité',
          ])
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 32),
              child: Row(
                children: [
                  Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: p.fill(0.14),
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: const VIcon(
                      VIcons.check,
                      size: 15,
                      color: VitreColors.white,
                      strokeWidth: 3,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text(text, style: VitreType.body(size: 16))),
                ],
              ),
            ),
          const SizedBox(height: 20),
          Semantics(
            label: 'Choisir une formule',
            container: true,
            explicitChildNodes: true,
            child: Column(
              children: [
                for (final choice in PurchaseChoice.values) ...[
                  _PlanCard(
                    choice: choice,
                    offer: offerFor(model, choice),
                    selected: choice == _choice,
                    onTap: () => setState(() => _choice = choice),
                  ),
                  const SizedBox(height: 10),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),
          PrimaryButton(
            label: demo
                ? kDemoPremiumButton
                : current
                ? 'Formule actuelle'
                : action.cta,
            semanticLabel: demo ? 'Version démo : $kDemoPremiumButton' : null,
            busy: _buying,
            onPressed: demo || current || !offer.available ? null : _buy,
          ),
          // Price and trial terms under the button (Google Play); nothing to add on the
          // current plan, whose button already says so.
          if (demo || !current) ...[
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Text(
                demo ? kDemoPremiumNote : action.note,
                textAlign: TextAlign.center,
                style: VitreType.small(color: p.text(0.74)),
              ),
            ),
          ],
          const SizedBox(height: 8),
          LinkButton(
            label: _restoring ? 'Vérification…' : 'Restaurer mes achats',
            underline: true,
            onPressed: _restoring ? null : _restore,
          ),
        ],
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.choice,
    required this.offer,
    required this.selected,
    required this.onTap,
  });

  final PurchaseChoice choice;
  final ProductOffer offer;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = Vitre.of(context);
    final (name, sub, unit, badge) = switch (choice) {
      PurchaseChoice.annual => (
        'Annuel',
        offer.hasFreeTrial ? 'Essai gratuit de 3 jours' : 'Le plus avantageux',
        'par an',
        '−37 %',
      ),
      PurchaseChoice.monthly => (
        'Mensuel',
        'Sans engagement',
        'par mois',
        null,
      ),
      PurchaseChoice.lifetime => (
        'À vie',
        'Paiement unique',
        'une seule fois',
        null,
      ),
    };
    final radius = BorderRadius.circular(26);
    final stacked = isLargeText(context);
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      button: true,
      label:
          '$name, ${offer.price} $unit. $sub${badge == null ? '' : ', moins 37 %'}',
      container: true,
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: selected ? p.fill(0.14) : p.fill(0.06),
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(
            color: selected ? VitreColors.white : p.border(0.2),
            width: selected ? 2 : 1,
          ),
        ),
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 76),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: selected ? VitreColors.white : p.text(0.5),
                      width: 2,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: selected
                      ? Container(
                          width: 12,
                          height: 12,
                          decoration: const BoxDecoration(
                            color: VitreColors.white,
                            shape: BoxShape.circle,
                          ),
                        )
                      : null,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(name, style: VitreType.label(size: 17)),
                          if (badge != null)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 9,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: VitreColors.white,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                badge,
                                style: VitreType.label(
                                  size: 13,
                                  weight: 600,
                                  color: VitreColors.ink,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        sub,
                        style: VitreType.small(
                          height: 1.25,
                          color: p.text(0.72),
                        ),
                      ),
                      // Large text: the price goes under the name.
                      if (stacked) ...[
                        const SizedBox(height: 6),
                        Text(
                          '${offer.price} $unit',
                          style: VitreType.label(size: 17),
                        ),
                      ],
                    ],
                  ),
                ),
                if (!stacked) ...[
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(offer.price, style: VitreType.label(size: 17)),
                      Text(
                        unit,
                        style: VitreType.small(color: p.text(0.72)),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
