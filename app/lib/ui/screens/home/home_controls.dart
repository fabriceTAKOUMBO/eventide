// Home screen controls: top bar (moon, timer chip, gear, themes), right edge
// (favorite, arrows, pager) and the timer menu.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../core/format.dart';
import '../../../core/scene.dart';
import '../../theme/vitre.dart';
import '../../widgets/glass.dart';
import '../../widgets/vicons.dart';

/// Timer choices of the chip menu (dossier § 6: default 1 h).
const List<(TimerSetting, String)> kTimerChoices = [
  (TimerDuration(15), '15 min'),
  (TimerDuration(30), '30 min'),
  (TimerDuration(60), '1 h'),
  (TimerDuration(120), '2 h'),
  (TimerNight(), 'Toute la nuit'),
  (TimerNone(), 'Sans minuteur'),
];

String timerChoiceLabel(TimerSetting timer) {
  for (final (t, label) in kTimerChoices) {
    if (t == timer) return label;
  }
  return timerChipLabel(timer);
}

class HomeTopBar extends StatelessWidget {
  const HomeTopBar({
    super.key,
    required this.timer,
    required this.timerMenuOpen,
    required this.onSleep,
    required this.onSettings,
    required this.onTimer,
    required this.themes,
    required this.themeIndex,
    required this.onTheme,
  });

  final TimerSetting timer;
  final bool timerMenuOpen;
  final VoidCallback onSleep;
  final VoidCallback onSettings;
  final VoidCallback onTimer;
  final List<String> themes;
  final int themeIndex;
  final ValueChanged<int> onTheme;

  @override
  Widget build(BuildContext context) {
    final p = Vitre.of(context);
    final chipLabel = timerChipLabel(timer);
    final aria = timer is TimerNone
        ? 'Minuteur désactivé, toucher pour le régler'
        : 'Minuteur ${timerChoiceLabel(timer)}, toucher pour le régler';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              RoundIconButton(icon: VIcons.moon, label: 'Sommeil', onPressed: onSleep, blur: 20),
              Expanded(
                child: Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Semantics(
                      button: true,
                      expanded: timerMenuOpen,
                      label: aria,
                      excludeSemantics: true,
                      onTap: onTimer,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(24),
                        child: BackdropFilter(
                          filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                          child: Material(
                            color: p.fill(0.08),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(24),
                              side: BorderSide(color: p.border(0.22)),
                            ),
                            child: InkWell(
                              onTap: onTimer,
                              borderRadius: BorderRadius.circular(24),
                              child: Container(
                                height: 48,
                                padding: const EdgeInsets.fromLTRB(16, 0, 14, 0),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const VIcon(VIcons.timer, size: 22, color: VitreColors.white),
                                    const SizedBox(width: 8),
                                    Text(
                                      chipLabel,
                                      maxLines: 1,
                                      textScaler: MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.6),
                                      style: manrope(17, weight: 700),
                                    ),
                                    const SizedBox(width: 8),
                                    Opacity(
                                      opacity: 0.75,
                                      child: VIcon(timerMenuOpen ? VIcons.chevronUp : VIcons.chevronDown, size: 16, color: VitreColors.white),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              RoundIconButton(icon: VIcons.settings, label: 'Réglages', onPressed: onSettings, blur: 20),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Semantics(
          label: 'Thème des paysages',
          container: true,
          child: SizedBox(
            height: 52,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(27),
                    child: BackdropFilter(
                      filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                      child: SegmentedTabs(
                        labels: themes,
                        selected: themeIndex,
                        onSelected: onTheme,
                        expand: false,
                        dark: true,
                        height: 52,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Favorite, previous/next arrows and the pager dots of the current theme.
class HomeRightEdge extends StatelessWidget {
  const HomeRightEdge({
    super.key,
    required this.favorite,
    required this.onFavorite,
    required this.onPrevious,
    required this.onNext,
    required this.dots,
    required this.current,
    required this.pagerLabel,
  });

  final bool favorite;
  final VoidCallback onFavorite;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  /// One entry per landscape of the theme: true when playable (filled dot),
  /// false for Premium (hollow dot).
  final List<bool> dots;
  final int current;
  final String pagerLabel;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      const buttons = 48.0 * 3 + 10 * 3;
      final pagerHeight = 20.0 + 22 + (dots.length - 1) * 16;
      final showPager = constraints.maxHeight >= buttons + pagerHeight;
      final column = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          RoundIconButton(
            icon: favorite ? VIcons.heartFilled : VIcons.heart,
            iconSize: 26,
            label: favorite ? 'Retirer des favoris' : 'Ajouter aux favoris',
            onPressed: onFavorite,
            dark: !favorite,
            background: favorite ? VitreColors.white : null,
            foreground: favorite ? VitreColors.ink : VitreColors.white,
            borderAlpha: 0.3,
            blur: 14,
            selected: favorite,
          ),
          const SizedBox(height: 10),
          RoundIconButton(
            icon: VIcons.arrowUp,
            iconSize: 26,
            label: 'Paysage précédent',
            onPressed: onPrevious,
            dark: true,
            blur: 14,
            opacity: onPrevious == null ? 0.22 : 0.92,
          ),
          if (showPager) ...[
            const SizedBox(height: 10),
            _Pager(dots: dots, current: current, label: pagerLabel),
          ],
          const SizedBox(height: 10),
          RoundIconButton(
            icon: VIcons.arrowDown,
            iconSize: 26,
            label: 'Paysage suivant',
            onPressed: onNext,
            dark: true,
            blur: 14,
            opacity: onNext == null ? 0.22 : 0.92,
          ),
        ],
      );
      if (constraints.maxHeight >= buttons) return column;
      return FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.topRight, child: column);
    });
  }
}

class _Pager extends StatelessWidget {
  const _Pager({required this.dots, required this.current, required this.label});

  final List<bool> dots;
  final int current;
  final String label;

  @override
  Widget build(BuildContext context) {
    final p = Vitre.of(context);
    final d = motion(context, const Duration(milliseconds: 250));
    return Semantics(
      label: label,
      image: true,
      excludeSemantics: true,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
            decoration: BoxDecoration(color: p.glass(0.45), borderRadius: BorderRadius.circular(14)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < dots.length; i++) ...[
                  if (i > 0) const SizedBox(height: 8),
                  AnimatedContainer(
                    duration: d,
                    width: 8,
                    height: i == current ? 22 : 8,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(4),
                      color: i == current
                          ? VitreColors.white
                          : dots[i]
                              ? p.text(0.55)
                              : Colors.transparent,
                      border: i != current && !dots[i] ? Border.all(color: p.text(0.6), width: 1.5) : null,
                    ),
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

/// Popup menu of timer durations under the chip.
class TimerMenu extends StatelessWidget {
  const TimerMenu({super.key, required this.current, required this.onPick});

  final TimerSetting current;
  final ValueChanged<TimerSetting> onPick;

  @override
  Widget build(BuildContext context) {
    final p = Vitre.of(context);
    return Semantics(
      label: 'Durée du minuteur',
      container: true,
      explicitChildNodes: true,
      child: GlassPanel(
        alpha: 0.78,
        borderAlpha: 0.18,
        radius: BorderRadius.circular(28),
        padding: const EdgeInsets.all(8),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (timer, label) in kTimerChoices)
                Semantics(
                  inMutuallyExclusiveGroup: true,
                  checked: timer == current,
                  button: true,
                  label: label,
                  excludeSemantics: true,
                  onTap: () => onPick(timer),
                  child: Material(
                    color: timer == current ? p.fill(0.16) : Colors.transparent,
                    borderRadius: BorderRadius.circular(20),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap: () => onPick(timer),
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 52),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                        child: Row(
                          children: [
                            Expanded(child: Text(label, style: manrope(18, weight: 600))),
                            const SizedBox(width: 8),
                            Opacity(
                              opacity: timer == current ? 1 : 0,
                              child: const VIcon(VIcons.check, size: 20, color: VitreColors.white),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
