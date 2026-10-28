// Screen 9 · Programmations: start the sound softly at a set time.
import 'package:flutter/material.dart';

import '../../app/app_model.dart';
import '../../core/format.dart';
import '../../core/schedule.dart';
import '../model_scope.dart';
import '../navigation.dart';
import '../theme/vitre.dart';
import '../widgets/glass.dart';
import '../widgets/sheet_scaffold.dart';
import '../widgets/vicons.dart';

class SchedulesScreen extends StatelessWidget {
  const SchedulesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final p = Vitre.of(context);
    final schedules = model.schedules;
    final max = model.rules.maxSchedules(model.plan);
    final limitReached = max != null && schedules.length >= max;

    return VitreSheet(
      title: 'Programmations',
      top: 80,
      panelAlpha: 0.72,
      backgroundBrightness: 0.5,
      backgroundSaturation: 0.85,
      contentPadding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 16),
            child: SheetText(
              'Le son démarre doucement à l’heure choisie, pour vous rappeler de vous détendre ou d’aller dormir.',
            ),
          ),
          if (!model.exactAlarmAllowed)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: DashedBorderBox(
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  alignment: WrapAlignment.end,
                  spacing: 12,
                  runSpacing: 10,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 200),
                      child: Text(
                        'Pour démarrer à l’heure, Android demande votre autorisation.',
                        style: manrope(16, height: 1.35, color: p.text(0.88)),
                      ),
                    ),
                    _AllowButton(onTap: () => model.requestPermission(PermissionKind.exactAlarm)),
                  ],
                ),
              ),
            ),
          for (final s in schedules) _ScheduleRow(schedule: s),
          const SizedBox(height: 4),
          SecondaryButton(
            label: 'Ajouter une programmation',
            icon: limitReached ? VIcons.lock : VIcons.plus,
            semanticLabel: limitReached ? 'Ajouter une programmation, avec Premium' : 'Ajouter une programmation',
            onPressed: () {
              if (limitReached) {
                Nav.premium(context);
              } else {
                Nav.scheduleEditor(context);
              }
            },
          ),
          if (max != null) ...[
            const SizedBox(height: 12),
            Text(
              'Version gratuite : $max programmation. Premium n’a pas de limite.',
              textAlign: TextAlign.center,
              style: manrope(16, height: 1.35, color: p.text(0.72)),
            ),
          ],
          const SizedBox(height: 18),
          LinkButton(
            label: 'Le son ne démarre pas ? Voir le guide',
            underline: true,
            fontSize: 17,
            alpha: 0.88,
            onPressed: () => Nav.batteryGuide(context),
          ),
        ],
      ),
    );
  }
}

class _AllowButton extends StatelessWidget {
  const _AllowButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: VitreColors.white,
      borderRadius: BorderRadius.circular(24),
      child: Semantics(
        button: true,
        label: 'Autoriser',
        excludeSemantics: true,
        onTap: onTap,
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
            alignment: Alignment.center,
            child: Text('Autoriser', style: manrope(17, weight: 700, color: VitreColors.ink)),
          ),
        ),
      ),
    );
  }
}

class _ScheduleRow extends StatelessWidget {
  const _ScheduleRow({required this.schedule});

  final Schedule schedule;

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final p = Vitre.of(context);
    final time = formatClock(schedule.hour, schedule.minute);
    final landscape = model.catalog.landscape(schedule.landscapeId)?.name ?? '';
    final ramp = formatDuration(Duration(minutes: schedule.rampMinutes));
    final line1 = '${schedule.daysSummary()} · ${schedule.reminder.label}';
    final line2 = '$landscape · monte doucement sur $ramp';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        constraints: const BoxConstraints(minHeight: 116),
        decoration: BoxDecoration(
          color: p.fill(0.07),
          borderRadius: BorderRadius.circular(26),
          border: Border.all(color: p.border(0.14)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                button: true,
                label: 'Modifier la programmation de $time, $line1, $line2',
                excludeSemantics: true,
                onTap: () => Nav.scheduleEditor(context, existing: schedule),
                child: InkWell(
                  borderRadius: const BorderRadius.horizontal(left: Radius.circular(26)),
                  onTap: () => Nav.scheduleEditor(context, existing: schedule),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 16, 4, 16),
                    child: Opacity(
                      opacity: schedule.active ? 1 : 0.6,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(time, style: manrope(40, weight: 300, letterSpacingEm: -0.02, height: 1.1)),
                          const SizedBox(height: 4),
                          Text(line1, style: manrope(17, weight: 600)),
                          const SizedBox(height: 2),
                          Text(line2, style: manrope(16, color: p.text(0.76))),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Semantics(
              toggled: schedule.active,
              label: 'Programmation de $time',
              excludeSemantics: true,
              onTap: () => model.setScheduleActive(schedule.id, !schedule.active),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => model.setScheduleActive(schedule.id, !schedule.active),
                child: SizedBox(
                  width: 82,
                  height: 82,
                  child: Center(child: VitreSwitchVisual(value: schedule.active)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
