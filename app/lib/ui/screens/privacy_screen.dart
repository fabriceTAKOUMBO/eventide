// Confidentialité et données (not in the mockup, dossier § 4): what stays on the
// phone, the online policy, ad choices (free plan), export and deletion.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../model_scope.dart';
import '../theme/vitre.dart';
import '../widgets/glass.dart';
import '../widgets/permission_dialog.dart';
import '../widgets/sheet_scaffold.dart';
import '../widgets/toast.dart';
import '../widgets/vicons.dart';

class PrivacyScreen extends StatefulWidget {
  const PrivacyScreen({super.key});

  @override
  State<PrivacyScreen> createState() => _PrivacyScreenState();
}

class _PrivacyScreenState extends State<PrivacyScreen> {
  bool _exporting = false;
  bool _deleting = false;

  Future<void> _export() async {
    final model = context.readModel;
    setState(() => _exporting = true);
    String data;
    try {
      data = await model.exportData();
    } catch (_) {
      data = '';
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
    if (!mounted) return;
    if (data.isEmpty) {
      ToastHost.show(
        context,
        'L’export n’a pas pu être préparé. Réessayez plus tard.',
      );
      return;
    }
    final copy = await showVitreDialog<bool>(
      context,
      icon: VIcons.download,
      title: 'Vos données',
      message: 'Voici tout ce qu’Eventide garde à votre sujet. Vous pouvez le copier pour le conserver.',
      confirm: 'Copier',
      cancel: 'Fermer',
      extra: Container(
        constraints: const BoxConstraints(maxHeight: 220),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0x66000000),
          borderRadius: BorderRadius.circular(16),
        ),
        child: SingleChildScrollView(
          child: SelectableText(
            data,
            style: manrope(14, color: VitreColors.whiteA(0.86)),
          ),
        ),
      ),
    );
    if (copy == true) {
      await Clipboard.setData(ClipboardData(text: data));
      if (mounted) ToastHost.show(context, 'Données copiées', check: true);
    }
  }

  Future<void> _delete() async {
    final model = context.readModel;
    final confirmed = await showVitreDialog<bool>(
      context,
      icon: VIcons.trash,
      title: 'Supprimer mes données ?',
      message: 'Vos favoris, vos programmations et vos nuits seront effacés de ce téléphone et de nos serveurs. Vos achats restent liés à votre compte Google Play.',
      confirm: 'Supprimer',
      cancel: 'Garder mes données',
    );
    if (confirmed != true || !mounted) return;
    setState(() => _deleting = true);
    try {
      await model.deleteAccountData();
      if (mounted) ToastHost.show(context, 'Vos données ont été supprimées');
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Vitre.of(context);
    final model = context.model;
    Widget section(String title, String body) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlassCard(
        radius: 24,
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: manrope(19, weight: 700)),
            const SizedBox(height: 6),
            Text(body, style: manrope(17, height: 1.4, color: p.text(0.84))),
          ],
        ),
      ),
    );
    return VitreSheet(
      title: 'Confidentialité et données',
      titleSize: 24,
      top: 70,
      panelAlpha: 0.74,
      backgroundBrightness: 0.5,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          section(
            'Sur votre téléphone',
            'Vos mix, vos favoris, vos programmations et vos nuits restent sur ce téléphone. Les mesures du sommeil sont calculées ici.',
          ),
          section(
            'Ce qui passe par nos serveurs',
            'Vos achats sont vérifiés avec Google Play. Un mix partagé est enregistré sans donnée personnelle.',
          ),
          section(
            'Jamais',
            'Aucune vente de vos données. Aucune publicité pendant l’écoute. Aucun accès au micro.',
          ),
          const SizedBox(height: 4),
          LinkRow(
            title: 'Politique de confidentialité',
            subtitle: 'Le texte complet, en ligne',
            onTap: model.openPrivacyPolicy,
          ),
          // Ads only exist in the free version (Google's consent form).
          if (!model.plan.isPremium)
            LinkRow(
              title: 'Choix publicitaires',
              subtitle: 'Revoir votre consentement aux publicités',
              onTap: model.openAdPrivacyOptions,
            ),
          const SizedBox(height: 18),
          PrimaryButton(
            label: 'Exporter mes données',
            icon: VIcons.download,
            busy: _exporting,
            onPressed: _export,
          ),
          const SizedBox(height: 12),
          SecondaryButton(
            label: 'Supprimer mes données',
            icon: VIcons.trash,
            busy: _deleting,
            onPressed: _delete,
          ),
        ],
      ),
    );
  }
}
