// Bottom glass menu of the home screen, expanded (~300 px) or collapsed (~100 px).
import 'package:flutter/material.dart';

import '../../landscape/landscape_painter.dart';
import '../../landscape/landscape_image.dart';
import '../../theme/vitre.dart';
import '../../widgets/glass.dart';
import '../../widgets/vicons.dart';

/// What the menu shows; built by the home screen from the model.
class HomeMenuData {
  const HomeMenuData({
    required this.landscapeId,
    required this.style,
    required this.name,
    required this.subtitle,
    required this.locked,
    required this.playing,
    required this.loading,
    required this.scheduleTop,
    required this.scheduleMain,
    required this.scheduleLabel,
  });

  final String landscapeId;
  final String style;
  final String name;

  /// Active sounds (« Eau vive · Oiseaux »), or a loading message.
  final String subtitle;
  final bool locked;
  final bool playing;
  final bool loading;

  /// « Démarrage » / « Ce soir ».
  final String scheduleTop;

  /// « Programmer » / « 22 h 00 ».
  final String scheduleMain;
  final String scheduleLabel;
}

class HomeMenu extends StatelessWidget {
  const HomeMenu({
    super.key,
    required this.data,
    required this.expanded,
    required this.onToggleExpanded,
    required this.onPlay,
    required this.onUnlock,
    required this.onLandscapes,
    required this.onMix,
    required this.onSchedule,
  });

  final HomeMenuData data;
  final bool expanded;
  final VoidCallback onToggleExpanded;
  final VoidCallback onPlay;
  final VoidCallback onUnlock;
  final VoidCallback onLandscapes;
  final VoidCallback onMix;
  final VoidCallback onSchedule;

  @override
  Widget build(BuildContext context) {
    final d = motion(context, const Duration(milliseconds: 300));
    final body = expanded ? _expanded(context) : _collapsed(context);
    if (d == Duration.zero) {
      return GlassPanel(
        alpha: 0.55,
        radius: BorderRadius.circular(36),
        child: body,
      );
    }
    return GlassPanel(
      alpha: 0.55,
      radius: BorderRadius.circular(36),
      child: AnimatedSize(
        duration: d,
        curve: Curves.easeOutCubic,
        alignment: Alignment.bottomCenter,
        child: AnimatedSwitcher(
          duration: d,
          layoutBuilder: (current, previous) => Stack(
            alignment: Alignment.bottomCenter,
            children: [
              ...previous.map(
                (w) => Positioned(left: 0, right: 0, bottom: 0, child: w),
              ),
              ?current,
            ],
          ),
          child: body,
        ),
      ),
    );
  }

  Widget _chevron({required bool collapse}) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Center(
        child: Pressable(
          onTap: onToggleExpanded,
          borderRadius: BorderRadius.circular(22),
          semanticLabel: collapse
              ? 'Réduire le menu pour voir plus de paysage'
              : 'Afficher le menu complet',
          child: SizedBox(
            width: collapse ? 140 : 96,
            height: 44,
            child: Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.only(top: 5),
                child: VIcon(
                  collapse ? VIcons.menuCollapse : VIcons.menuExpand,
                  size: 22,
                  color: VitreColors.whiteA(0.85),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _title(
    BuildContext context, {
    required double size,
    int maxLines = 1,
  }) => Text(
    data.name,
    maxLines: maxLines,
    overflow: TextOverflow.ellipsis,
    style: VitreType.display(size: size, height: 1.05),
  );

  Widget _subtitle(BuildContext context) {
    final p = Vitre.of(context);
    if (data.locked) {
      return Row(
        children: [
          const VIcon(VIcons.lock, size: 15, color: VitreColors.white),
          const SizedBox(width: 6),
          Flexible(
            child: Text('Avec Premium', style: VitreType.label(size: 14)),
          ),
        ],
      );
    }
    return Row(
      children: [
        if (data.loading) ...[
          SizedBox.square(
            dimension: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: p.text(0.8),
            ),
          ),
          const SizedBox(width: 8),
        ],
        Flexible(
          child: Text(
            data.subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: VitreType.small(size: 14, color: p.text(0.76)),
          ),
        ),
      ],
    );
  }

  Widget _mainButton(BuildContext context, double size) {
    final iconSize = size * 0.44;
    final Widget icon;
    final String label;
    final VoidCallback onTap;
    if (data.locked) {
      icon = VIcon(VIcons.lock, size: iconSize * 0.95, color: VitreColors.ink);
      label = 'Débloquer ce paysage avec Premium';
      onTap = onUnlock;
    } else {
      icon = VIcon(
        data.playing ? VIcons.pause : VIcons.play,
        size: iconSize,
        color: VitreColors.ink,
      );
      label = data.playing ? 'Mettre en pause' : 'Lancer la lecture';
      onTap = onPlay;
    }
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Color(0x59000000),
            blurRadius: 24,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Material(
        color: VitreColors.white,
        shape: const CircleBorder(),
        child: Semantics(
          button: true,
          label: label,
          container: true,
          excludeSemantics: true,
          onTap: onTap,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Stack(
              alignment: Alignment.center,
              children: [
                icon,
                if (data.loading && !data.locked)
                  SizedBox.square(
                    dimension: size - 6,
                    child: const CircularProgressIndicator(
                      strokeWidth: 2.4,
                      color: Color(0x660A0F0D),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _expanded(BuildContext context) {
    final p = Vitre.of(context);
    return Stack(
      key: const ValueKey('expanded'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 28, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _title(context, size: 30, maxLines: 2),
                        const SizedBox(height: 4),
                        _subtitle(context),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  _mainButton(context, 72),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _Tile(
                      label: 'Paysages',
                      semanticLabel: 'Choisir un paysage',
                      onTap: onLandscapes,
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: SizedBox.square(
                          dimension: 38,
                          child: LandscapeThumbnail(
                            landscapeId: data.landscapeId,
                            style: data.style,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _Tile(
                      label: 'Mon mix',
                      semanticLabel: 'Régler mon mix : sons, musique et décor',
                      onTap: onMix,
                      leading: Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: p.fill(0.12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        alignment: Alignment.center,
                        child: const VIcon(
                          VIcons.mixer,
                          size: 24,
                          color: VitreColors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Pressable(
                      onTap: onSchedule,
                      borderRadius: BorderRadius.circular(34),
                      semanticLabel: data.scheduleLabel,
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 68),
                        padding: const EdgeInsets.fromLTRB(18, 6, 12, 6),
                        decoration: BoxDecoration(
                          color: p.fill(0.1),
                          borderRadius: BorderRadius.circular(34),
                          border: Border.all(color: p.border(0.2)),
                        ),
                        child: Row(
                          children: [
                            const VIcon(
                              VIcons.alarm,
                              size: 26,
                              color: VitreColors.white,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    CapsText(
                                      data.scheduleTop,
                                      style: VitreType.eyebrow(
                                        color: p.text(0.74),
                                      ),
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      data.scheduleMain,
                                      style: VitreType.label(
                                        size: 17,
                                        height: 1.15,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        _chevron(collapse: true),
      ],
    );
  }

  Widget _collapsed(BuildContext context) {
    return Stack(
      key: const ValueKey('collapsed'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 28, 14, 14),
          child: Row(
            children: [
              Expanded(child: _title(context, size: 26, maxLines: 2)),
              const SizedBox(width: 10),
              _mainButton(context, 64),
            ],
          ),
        ),
        _chevron(collapse: false),
      ],
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.label,
    required this.semanticLabel,
    required this.onTap,
    required this.leading,
  });

  final String label;
  final String semanticLabel;
  final VoidCallback onTap;
  final Widget leading;

  @override
  Widget build(BuildContext context) {
    final p = Vitre.of(context);
    return Pressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(22),
      semanticLabel: semanticLabel,
      child: Container(
        constraints: const BoxConstraints(minHeight: 68),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: p.fill(0.09),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: p.border(0.18)),
        ),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 10),
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(label, style: VitreType.label()),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Small landscape picture (menu tile, schedule rows, grid).
class LandscapeThumbnail extends StatelessWidget {
  const LandscapeThumbnail({
    super.key,
    required this.landscapeId,
    required this.style,
  });

  final String landscapeId;
  final String style;

  @override
  Widget build(BuildContext context) {
    final provider = LandscapeImages.thumbnailFor(landscapeId);
    if (provider != null) {
      return Image(
        image: provider,
        fit: BoxFit.cover,
        alignment: Alignment(0, landscapeFocusY(style) * 2 - 1),
        errorBuilder: (c, e, s) => ProceduralLandscape(style: style),
      );
    }
    return ProceduralLandscape(style: style);
  }
}
