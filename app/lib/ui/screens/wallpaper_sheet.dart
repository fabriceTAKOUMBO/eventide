// « Fond d'écran »: the landscape as the phone's wallpaper (docs/app/architecture.md
// « Fond d'écran vidéo »). Opened from Paysages. Two ways, each explained in plain words:
// a live wallpaper (the looping video, muted, on the home screen; the lock screen depends on
// the phone), and a copy of the video in the Gallery, for lock screens that only take a
// Gallery video (One UI, about 15 s at most).
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

/// Messages of the sheet (French, plain words).
abstract final class WallpaperMessages {
  static const liveTitle = 'Mettre en fond d’écran (vidéo animée)';
  static const stillTitle = 'Mettre en fond d’écran';
  static const liveText =
      'Le paysage bouge doucement sur l’écran d’accueil, sans aucun son. Android affiche un '
      'aperçu : touchez « Définir comme fond d’écran » pour confirmer. Sur l’écran verrouillé, '
      'cela dépend du téléphone. La vidéo se met en pause dès qu’elle n’est plus visible, pour '
      'économiser la batterie.';
  static const stillText =
      'Ce paysage n’a pas de vidéo sur ce téléphone : son image fixe sera utilisée.';
  static const galleryTitle = 'Enregistrer dans la Galerie';
  static const galleryText =
      'Pour l’écran verrouillé des téléphones Samsung : la vidéo est copiée dans la Galerie '
      '(dossier Movies/Eventide). Choisissez-la ensuite dans Paramètres › Fond d’écran. '
      'One UI n’accepte qu’environ 15 secondes de vidéo pour l’écran verrouillé.';
  static const lockedText = 'Ce paysage fait partie de Premium.';
  static const nothingText = 'Ce paysage n’a pas encore d’image à mettre en fond d’écran.';
  static const unsupported = 'Ce téléphone ne permet pas les fonds d’écran animés.';
  static const unavailable =
      'La vidéo de ce paysage n’est pas encore sur le téléphone. Réessayez avec une connexion.';
  static const failed = 'Le fond d’écran n’a pas pu être ouvert. Réessayez.';
  static const saved = 'Vidéo enregistrée dans la Galerie (Movies/Eventide).';
  static const notSaved = 'La vidéo n’a pas pu être enregistrée dans la Galerie.';
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
  bool _saving = false;

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

  Future<void> _save(AppModel model) async {
    final toasts = ToastHost.maybeOf(context);
    setState(() => _saving = true);
    final ok = await model.saveLandscapeVideoToGallery(widget.landscapeId);
    if (!mounted) return;
    setState(() => _saving = false);
    toasts?.show(ok ? WallpaperMessages.saved : WallpaperMessages.notSaved, check: ok);
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
    final explanation = manrope(16, height: 1.4, color: p.text(0.78));

    final children = <Widget>[
      Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: SizedBox(
              width: 64,
              height: 88,
              child: LandscapeThumbnail(landscapeId: landscape.id, style: landscape.style),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(landscape.name, style: manrope(21, weight: 700, height: 1.2)),
                const SizedBox(height: 2),
                Text(
                  video ? 'Paysage vivant, sans son' : 'Image du paysage',
                  style: manrope(16, color: p.text(0.72)),
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
          height: 60,
          fontSize: 19,
          onPressed: () => Nav.premium(context),
        ),
      ]);
    } else if (!support.any) {
      children.add(Text(WallpaperMessages.unsupported, style: explanation));
    } else {
      if (support.liveWallpaper) {
        if (video || still) {
          children.addAll([
            PrimaryButton(
              label: video ? WallpaperMessages.liveTitle : WallpaperMessages.stillTitle,
              height: 60,
              fontSize: 18,
              busy: _applying,
              onPressed: () => _apply(model),
            ),
            const SizedBox(height: 10),
            Text(video ? WallpaperMessages.liveText : WallpaperMessages.stillText, style: explanation),
          ]);
        } else {
          children.add(Text(WallpaperMessages.nothingText, style: explanation));
        }
      } else {
        children.add(Text(WallpaperMessages.unsupported, style: explanation));
      }
      if (support.gallery && video) {
        children.addAll([
          const SizedBox(height: 24),
          SecondaryButton(
            label: WallpaperMessages.galleryTitle,
            height: 56,
            fontSize: 18,
            busy: _saving,
            onPressed: () => _save(model),
          ),
          const SizedBox(height: 10),
          Text(WallpaperMessages.galleryText, style: explanation),
        ]);
      }
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
