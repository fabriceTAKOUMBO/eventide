// Screen 7 · Sommeil. Only what is measured: duration of the night and listening time
// (no fall-asleep latency nor awakenings: no reliable measure, dossier screen 7).
import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/sleep.dart';
import '../model_scope.dart';
import '../navigation.dart';
import '../theme/vitre.dart';
import '../widgets/glass.dart';
import '../widgets/sheet_scaffold.dart';
import '../widgets/vicons.dart';

const List<String> _dayLetters = ['L', 'M', 'M', 'J', 'V', 'S', 'D'];
const List<String> _dayNames = ['lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi', 'dimanche'];

class SleepScreen extends StatelessWidget {
  const SleepScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final p = Vitre.of(context);
    final stats = model.sleepStats;
    final night = stats.lastNight;
    final history = model.rules.sleepHistory(model.plan);
    final tracking = model.scene.sleepTracking;

    return VitreSheet(
      title: 'Sommeil',
      top: 80,
      panelAlpha: 0.72,
      backgroundBrightness: 0.5,
      backgroundSaturation: 0.85,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: _SmallButton(
              icon: VIcons.alarm,
              label: 'Programmer',
              semanticLabel: 'Programmer un démarrage automatique',
              onTap: () => Nav.schedules(context),
            ),
          ),
          const SizedBox(height: 4),
          if (night == null)
            DashedBorderBox(
              radius: 28,
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Pas encore de nuit', style: manrope(22, weight: 600)),
                  const SizedBox(height: 6),
                  Text(
                    tracking
                        ? 'Touchez « Commencer la nuit » ce soir : la durée de votre nuit apparaîtra ici demain matin.'
                        : 'Activez le suivi du sommeil, puis touchez « Commencer la nuit » ce soir.',
                    style: manrope(17, height: 1.4, color: p.text(0.8)),
                  ),
                ],
              ),
            )
          else
            _LastNightCard(night: night),
          const SizedBox(height: 12),
          if (history)
            _HistoryCard(stats: stats)
          else
            GlassCard(
              radius: 28,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      VIcon(VIcons.lock, size: 20, color: p.text(0.9)),
                      const SizedBox(width: 8),
                      Expanded(child: Text('7 derniers jours', style: manrope(17, weight: 600, color: p.text(0.78)))),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text('L’historique de vos nuits est inclus dans Premium.', style: manrope(17, height: 1.4, color: p.text(0.86))),
                  const SizedBox(height: 14),
                  SecondaryButton(label: 'Découvrir Premium', height: 56, fontSize: 18, onPressed: () => Nav.premium(context)),
                ],
              ),
            ),
          if (night != null) ...[
            const SizedBox(height: 12),
            GlassCard(
              radius: 24,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Row(
                children: [
                  Expanded(child: Text('Écoute', style: manrope(16, color: p.text(0.76)))),
                  Text(
                    formatDuration(Duration(minutes: night.listenedMinutes)),
                    style: manrope(24, weight: 700),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 20),
          PrimaryButton(label: 'Commencer la nuit', icon: VIcons.moon, onPressed: model.startNight),
          const SizedBox(height: 16),
          Text(
            'Mesures indicatives, calculées sur votre téléphone. Ne remplace pas un avis médical.',
            textAlign: TextAlign.center,
            style: manrope(16, height: 1.35, color: p.text(0.72)),
          ),
          const SizedBox(height: 18),
          SwitchRow(
            title: 'Suivi du sommeil',
            subtitle: 'Durée de vos nuits, sur ce téléphone',
            value: tracking,
            onChanged: model.setSleepTracking,
          ),
        ],
      ),
    );
  }
}

class _SmallButton extends StatelessWidget {
  const _SmallButton({required this.icon, required this.label, required this.semanticLabel, required this.onTap});

  final VIconData icon;
  final String label;
  final String semanticLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = Vitre.of(context);
    return Pressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      semanticLabel: semanticLabel,
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: p.fill(0.08),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: p.border(0.22)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            VIcon(icon, size: 22, color: VitreColors.white),
            const SizedBox(width: 8),
            Flexible(child: Text(label, style: manrope(17, weight: 700))),
          ],
        ),
      ),
    );
  }
}

class _LastNightCard extends StatelessWidget {
  const _LastNightCard({required this.night});

  final Night night;

  @override
  Widget build(BuildContext context) {
    final p = Vitre.of(context);
    final start = night.start.toLocal();
    final end = night.end.toLocal();
    return GlassCard(
      radius: 28,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Cette nuit', style: manrope(17, weight: 600, color: p.text(0.78))),
          const SizedBox(height: 4),
          Text(formatDuration(night.duration), style: manrope(56, weight: 300, letterSpacingEm: -0.02, height: 1.1)),
          const SizedBox(height: 4),
          Text(
            'Couché ${formatClock(start.hour, start.minute)} · Réveil ${formatClock(end.hour, end.minute)}',
            style: manrope(17, color: p.text(0.78)),
          ),
        ],
      ),
    );
  }
}

class _HistoryCard extends StatelessWidget {
  const _HistoryCard({required this.stats});

  final SleepStats stats;

  @override
  Widget build(BuildContext context) {
    final p = Vitre.of(context);
    final days = stats.last7Days;
    const maxHours = 8.5;
    return GlassCard(
      radius: 28,
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            runSpacing: 4,
            children: [
              Text('7 derniers jours', style: manrope(17, weight: 600, color: p.text(0.78))),
              if (stats.average7 != null) Text('Moyenne ${formatDuration(stats.average7!)}', style: manrope(17, weight: 700)),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 96,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (var i = 0; i < days.length; i++)
                  Semantics(
                    label: days[i].duration == null
                        ? '${_dayNames[days[i].day.weekday - 1]} : pas de nuit'
                        : '${_dayNames[days[i].day.weekday - 1]} : ${formatDuration(days[i].duration!)}',
                    excludeSemantics: true,
                    child: Container(
                      width: 28,
                      height: days[i].duration == null
                          ? 6
                          : (days[i].duration!.inMinutes / 60 / maxHours * 96).clamp(6, 96).toDouble(),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        color: i == days.length - 1 ? VitreColors.white : p.fill(days[i].duration == null ? 0.12 : 0.32),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          ExcludeSemantics(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (var i = 0; i < days.length; i++)
                  SizedBox(
                    width: 34,
                    child: Text(
                      _dayLetters[days[i].day.weekday - 1],
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      style: manrope(
                        16,
                        weight: i == days.length - 1 ? 700 : 500,
                        color: i == days.length - 1 ? VitreColors.white : p.text(0.72),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
