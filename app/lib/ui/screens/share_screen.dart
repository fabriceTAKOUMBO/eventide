// Screen 6 · Partage: send the current mix to a relative.
import 'package:flutter/material.dart';

import '../../core/catalog.dart';
import '../landscape/landscape_image.dart';
import '../model_scope.dart';
import '../theme/vitre.dart';
import '../widgets/glass.dart';
import '../widgets/sheet_scaffold.dart';
import '../widgets/vicons.dart';

class ShareScreen extends StatefulWidget {
  const ShareScreen({super.key});

  @override
  State<ShareScreen> createState() => _ShareScreenState();
}

class _ShareScreenState extends State<ShareScreen> {
  bool _copied = false;
  bool _sending = false;

  Future<void> _send() async {
    setState(() => _sending = true);
    try {
      await context.readModel.shareMix();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _copy() async {
    await context.readModel.copyShareLink();
    if (mounted) setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final p = Vitre.of(context);
    final scene = model.scene;
    final landscape = model.catalog.landscape(scene.landscapeId) ?? model.catalog.defaultLandscape;
    final names = [
      for (final kind in LayerKind.values)
        for (final l in scene.layers(kind)) model.catalog.item(kind, l.id)?.name,
    ].whereType<String>().join(' · ');
    return VitreSheet(
      title: 'Partager',
      top: 96,
      panelAlpha: 0.7,
      backgroundBrightness: 0.6,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            constraints: const BoxConstraints(minHeight: 290),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(28),
              color: VitreColors.thumbFallback,
              boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 40, offset: Offset(0, 16))],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: LandscapeImage(landscapeId: landscape.id, style: landscape.style, moment: scene.moment),
                  ),
                  const Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [Color(0xD9000000), Color(0x00000000)],
                          stops: [0, 0.6],
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 180, 20, 18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(landscape.name, style: manrope(26, weight: 600, letterSpacingEm: -0.015, height: 1.2)),
                        const SizedBox(height: 4),
                        Text(names.isEmpty ? 'Sans son' : names, style: manrope(17, color: p.text(0.82))),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              'Votre proche retrouve exactement vos sons et vos réglages.',
              style: manrope(18, height: 1.4, color: p.text(0.84)),
            ),
          ),
          const SizedBox(height: 24),
          PrimaryButton(label: 'Envoyer à un proche', icon: VIcons.share, busy: _sending, onPressed: _send),
          const SizedBox(height: 12),
          Semantics(
            liveRegion: true,
            child: SecondaryButton(
              label: _copied ? 'Lien copié' : 'Copier le lien',
              icon: _copied ? VIcons.check : VIcons.copy,
              onPressed: _copy,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Le lien ouvre l’application, ou la page de téléchargement si elle n’est pas encore installée.',
            textAlign: TextAlign.center,
            style: manrope(16, height: 1.35, color: p.text(0.72)),
          ),
        ],
      ),
    );
  }
}
