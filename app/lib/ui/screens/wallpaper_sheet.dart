// « Fond d'écran »: the landscape as the phone's wallpaper (docs/app/architecture.md
// « Fond d'écran vidéo »). Opened from Paysages. A live wallpaper (the looping video, muted, on
// the home and lock screens), in as few words as possible.
import 'package:flutter/material.dart';

import '../../app/app_model.dart';
import '../../core/wallpaper.dart';
import '../landscape/landscape_image.dart';
import '../model_scope.dart';
import '../navigation.dart';
import '../theme/vitre.dart';
import '../widgets/glass.dart';
import '../widgets/sheet_scaffold.dart';
import '../widgets/toast.dart';
import 'home/home_menu.dart' show LandscapeThumbnail;

/// Messages of the sheet (French, as few words as possible).
abstract final class WallpaperMessages {
  /// Short enough for one line on a 384-dp-wide phone (Galaxy S24) at the default text size.
  static const liveTitle = 'Fond d’écran animé';
  static const stillTitle = 'Mettre en fond d’écran';
  static const liveText = 'Écran d’accueil et écran verrouillé, sans son.';
  static const stillText = 'Pas encore de vidéo pour ce paysage.';
  static const lockedText = 'Réservé à Premium.';
  static const nothingText = 'Pas encore d’image pour ce paysage.';
  static const unsupported = 'Ce téléphone ne permet pas les fonds d’écran animés.';
  static const unavailable = 'Vidéo pas encore téléchargée. Réessayez avec une connexion.';
  static const failed = 'Ouverture impossible. Réessayez.';
}

class WallpaperSheet extends StatefulWidget {
  const WallpaperSheet({super.key, required this.landscapeId});

  final String landscapeId;

  static const String routeName = 'fond-ecran';

  static Future<void> open(BuildContext context, String landscapeId) =>
      Navigator.of(context).push<void>(
        VitreRoute<void>(
          builder: (_) => WallpaperSheet(landscapeId: landscapeId),
          name: routeName,
        ),
      );

  @override
  State<WallpaperSheet> createState() => _WallpaperSheetState();
}

class _WallpaperSheetState extends State<WallpaperSheet> {
  bool _applying = false;

  Future<void> _apply(AppModel model) async {
    final toasts = ToastHost.maybeOf(context);
    setState(() => _applying = true);
    final result = await model.setLandscapeWallpaper(widget.landscapeId);
    if (!mounted) return;
    setState(() => _applying = false);
    final message = switch (result) {
      // Android's preview is on screen: nothing to add.
      WallpaperResult.opened => null,
      WallpaperResult.unsupported => WallpaperMessages.unsupported,
      WallpaperResult.unavailable => WallpaperMessages.unavailable,
      WallpaperResult.notAllowed => WallpaperMessages.lockedText,
      WallpaperResult.failed => WallpaperMessages.failed,
    };
    if (message != null) toasts?.show(message);
  }

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final p = Vitre.of(context);
    final landscape = model.catalog.landscape(widget.landscapeId) ?? model.catalog.defaultLandscape;
    final usable = model.rules.canUseLandscape(model.plan, landscape);
    final support = model.wallpaperSupport;
    final video = LandscapeImages.hasVideo(landscape.id);
    final still = LandscapeImages.providerFor(landscape.id) != null;
    final explanation = VitreType.small(size: 14, color: p.text(0.74));

    final children = <Widget>[
      Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: SizedBox(
              width: 64,
              height: 88,
              child: LandscapeThumbnail(landscapeId: landscape.id),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(landscape.name, style: VitreType.display(size: 26)),
                const SizedBox(height: 4),
                Text(
                  video ? 'Paysage vivant' : 'Image fixe',
                  style: VitreType.small(color: p.text(0.7)),
                ),
              ],
            ),
          ),
        ],
      ),
      const SizedBox(height: 20),
    ];

    if (!usable) {
      children.addAll([
        Text(WallpaperMessages.lockedText, style: explanation),
        const SizedBox(height: 14),
        PrimaryButton(
          label: 'Découvrir Premium',
          onPressed: () => Nav.premium(context),
        ),
      ]);
    } else if (!support.liveWallpaper) {
      children.add(Text(WallpaperMessages.unsupported, style: explanation));
    } else if (video || still) {
      children.addAll([
        PrimaryButton(
          label: video ? WallpaperMessages.liveTitle : WallpaperMessages.stillTitle,
          busy: _applying,
          onPressed: () => _apply(model),
        ),
        const SizedBox(height: 10),
        Text(
          video ? WallpaperMessages.liveText : WallpaperMessages.stillText,
          textAlign: TextAlign.center,
          style: explanation,
        ),
      ]);
    } else {
      children.add(Text(WallpaperMessages.nothingText, style: explanation));
    }

    return VitreSheet(
      title: 'Fond d’écran',
      top: 120,
      panelAlpha: 0.74,
      backgroundBrightness: 0.55,
      contentPadding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}
