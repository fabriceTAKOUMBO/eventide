// Screen 10 · Nouvelle programmation (also edits an existing one).
import 'package:flutter/material.dart';

import '../../app/app_model.dart';
import '../../core/format.dart';
import '../../core/schedule.dart';
import '../model_scope.dart';
import '../navigation.dart';
import '../theme/vitre.dart';
import '../widgets/glass.dart';
import '../widgets/permission_dialog.dart';
import '../widgets/sheet_scaffold.dart';
import '../widgets/toast.dart';
import '../widgets/vicons.dart';
import 'home/home_menu.dart' show LandscapeThumbnail;

const List<String> _letters = ['L', 'M', 'M', 'J', 'V', 'S', 'D'];
const List<String> _names = [
  'Lundi',
  'Mardi',
  'Mercredi',
  'Jeudi',
  'Vendredi',
  'Samedi',
  'Dimanche',
];

class ScheduleEditorScreen extends StatefulWidget {
  const ScheduleEditorScreen({super.key, this.existing});

  final Schedule? existing;

  @override
  State<ScheduleEditorScreen> createState() => _ScheduleEditorScreenState();
}

enum _Ramp { five, ten, custom }

class _ScheduleEditorScreenState extends State<ScheduleEditorScreen> {
  Schedule? _draft;
  late _Ramp _ramp;
  int _custom = 15;
  bool _saving = false;

  Schedule get draft => _draft!;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_draft == null) {
      final d = widget.existing ?? context.readModel.newScheduleDraft();
      _draft = d;
      _ramp = switch (d.rampMinutes) {
        5 => _Ramp.five,
        10 => _Ramp.ten,
        _ => _Ramp.custom,
      };
      if (_ramp == _Ramp.custom) _custom = d.rampMinutes.clamp(15, 60);
    }
  }

  void _update(Schedule s) => setState(() => _draft = s);

  int get _rampMinutes => switch (_ramp) {
    _Ramp.five => 5,
    _Ramp.ten => 10,
    _Ramp.custom => _custom,
  };

  Future<void> _save() async {
    final model = context.readModel;
    final navigator = Navigator.of(context);
    final toasts = ToastHost.maybeOf(context);
    setState(() => _saving = true);
    try {
      // The reminder is a notification: explain before asking (dossier § 4).
      await explainAndRequestPermission(
        context,
        model,
        PermissionKind.notifications,
      );
      final ok = await model.saveSchedule(
        draft.copyWith(rampMinutes: _rampMinutes),
      );
      if (ok) {
        toasts?.show('Programmation enregistrée');
        navigator.maybePop();
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final model = context.readModel;
    final navigator = Navigator.of(context);
    final confirmed = await showVitreDialog<bool>(
      context,
      icon: VIcons.trash,
      title: 'Supprimer cette programmation ?',
      message:
          'Le son ne démarrera plus à ${formatClock(draft.hour, draft.minute)}.',
      confirm: 'Supprimer',
      cancel: 'Garder',
    );
    if (confirmed != true) return;
    await model.deleteSchedule(draft.id);
    navigator.maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final p = Vitre.of(context);
    final landscape =
        model.catalog.landscape(draft.landscapeId) ??
        model.catalog.defaultLandscape;
    final summary = draft.days.isEmpty
        ? 'Choisissez au moins un jour'
        : draft.daysSummary();

    return VitreSheet(
      title: widget.existing == null
          ? 'Nouvelle programmation'
          : 'Modifier la programmation',
      titleSize: 24,
      top: 60,
      headerTop: 24,
      panelAlpha: 0.74,
      backgroundBrightness: 0.5,
      backgroundSaturation: 0.85,
      contentPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      footer: PrimaryButton(
        label: 'Enregistrer',
        busy: _saving,
        onPressed: draft.days.isEmpty ? null : _save,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionLabel(
            'Heure de départ',
            padding: EdgeInsets.fromLTRB(4, 2, 4, 2),
          ),
          Semantics(
            label: 'Heure de départ : ${formatClock(draft.hour, draft.minute)}',
            container: true,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _Stepper(
                  text: draft.hour.toString().padLeft(2, '0'),
                  upLabel: 'Une heure plus tard',
                  downLabel: 'Une heure plus tôt',
                  onUp: () =>
                      _update(draft.copyWith(hour: (draft.hour + 1) % 24)),
                  onDown: () =>
                      _update(draft.copyWith(hour: (draft.hour + 23) % 24)),
                ),
                const SizedBox(width: 6),
                ExcludeSemantics(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(':', style: manrope(52, weight: 300)),
                  ),
                ),
                const SizedBox(width: 6),
                _Stepper(
                  text: draft.minute.toString().padLeft(2, '0'),
                  upLabel: 'Cinq minutes plus tard',
                  downLabel: 'Cinq minutes plus tôt',
                  onUp: () => _update(
                    draft.copyWith(minute: ((draft.minute ~/ 5) * 5 + 5) % 60),
                  ),
                  onDown: () => _update(
                    draft.copyWith(
                      minute: ((draft.minute + 4) ~/ 5 * 5 + 55) % 60,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SectionLabel('Jours'),
          Semantics(
            label: 'Jours de la semaine',
            container: true,
            explicitChildNodes: true,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final size = ((constraints.maxWidth - 6 * 4) / 7).clamp(
                  40.0,
                  48.0,
                );
                return Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    for (var d = 1; d <= 7; d++)
                      SizedBox(
                        width: size,
                        child: ChoiceChipButton(
                          label: _letters[d - 1],
                          semanticLabel: _names[d - 1],
                          selected: draft.days.contains(d),
                          radio: false,
                          height: 48,
                          fontSize: 17,
                          onTap: () {
                            final days = {...draft.days};
                            if (!days.remove(d)) days.add(d);
                            _update(draft.copyWith(days: days));
                          },
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
            child: Text(summary, style: manrope(17, color: p.text(0.84))),
          ),
          const SectionLabel(
            'Le son monte doucement pendant',
            padding: EdgeInsets.fromLTRB(4, 18, 4, 8),
          ),
          Semantics(
            label: 'Durée du démarrage progressif',
            container: true,
            explicitChildNodes: true,
            child: Row(
              children: [
                Expanded(
                  flex: 10,
                  child: ChoiceChipButton(
                    label: '5 min',
                    selected: _ramp == _Ramp.five,
                    onTap: () => setState(() => _ramp = _Ramp.five),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 10,
                  child: ChoiceChipButton(
                    label: '10 min',
                    selected: _ramp == _Ramp.ten,
                    onTap: () => setState(() => _ramp = _Ramp.ten),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 17,
                  child: ChoiceChipButton(
                    label: 'Personnalisé',
                    selected: _ramp == _Ramp.custom,
                    onTap: () => setState(() => _ramp = _Ramp.custom),
                  ),
                ),
              ],
            ),
          ),
          if (_ramp == _Ramp.custom)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
              child: Row(
                children: [
                  RoundIconButton(
                    icon: VIcons.minus,
                    label: 'Réduire la durée',
                    size: 56,
                    onPressed: _custom > 15
                        ? () => setState(() => _custom -= 5)
                        : null,
                    opacity: _custom > 15 ? 1 : 0.4,
                  ),
                  Expanded(
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        '$_custom min',
                        textAlign: TextAlign.center,
                        style: manrope(28, weight: 700),
                      ),
                    ),
                  ),
                  RoundIconButton(
                    icon: VIcons.plus,
                    label: 'Allonger la durée',
                    size: 56,
                    onPressed: _custom < 60
                        ? () => setState(() => _custom += 5)
                        : null,
                    opacity: _custom < 60 ? 1 : 0.4,
                  ),
                ],
              ),
            ),
          const SectionLabel('Ambiance'),
          Pressable(
            onTap: () async {
              final picked = await Nav.pickLandscape(
                context,
                draft.landscapeId,
              );
              if (picked != null && mounted) {
                _update(draft.copyWith(landscapeId: picked));
              }
            },
            borderRadius: BorderRadius.circular(22),
            semanticLabel: 'Ambiance : ${landscape.name}. Toucher pour changer',
            child: Container(
              constraints: const BoxConstraints(minHeight: 68),
              padding: const EdgeInsets.fromLTRB(12, 8, 16, 8),
              decoration: BoxDecoration(
                color: p.fill(0.08),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: p.border(0.16)),
              ),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: SizedBox.square(
                      dimension: 44,
                      child: LandscapeThumbnail(landscapeId: landscape.id),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      landscape.name,
                      style: manrope(19, weight: 700),
                    ),
                  ),
                  VIcon(VIcons.chevronRight, size: 20, color: p.text(0.7)),
                ],
              ),
            ),
          ),
          const SectionLabel('Message de rappel'),
          Semantics(
            label: 'Message de rappel',
            container: true,
            explicitChildNodes: true,
            child: Row(
              children: [
                for (final r in Reminder.values) ...[
                  if (r.index > 0) const SizedBox(width: 8),
                  Expanded(
                    child: ChoiceChipButton(
                      label: r.label,
                      selected: draft.reminder == r,
                      onTap: () => _update(draft.copyWith(reminder: r)),
                    ),
                  ),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
            child: Text(
              '« ${draft.reminder.notificationText} »',
              style: manrope(17, color: p.text(0.8)),
            ),
          ),
          if (widget.existing != null) ...[
            const SizedBox(height: 20),
            LinkButton(
              label: 'Supprimer la programmation',
              underline: true,
              onPressed: _delete,
            ),
          ],
        ],
      ),
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.text,
    required this.upLabel,
    required this.downLabel,
    required this.onUp,
    required this.onDown,
  });

  final String text;
  final String upLabel;
  final String downLabel;
  final VoidCallback onUp;
  final VoidCallback onDown;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        RoundIconButton(
          icon: VIcons.chevronUp,
          label: upLabel,
          onPressed: onUp,
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 100),
          child: ExcludeSemantics(
            child: Text(
              text,
              textAlign: TextAlign.center,
              textScaler: MediaQuery.textScalerOf(context)
                  .clamp(maxScaleFactor: 1.5),
              style: manrope(
                56,
                weight: 300,
                letterSpacingEm: -0.02,
                height: 1.1,
              ),
            ),
          ),
        ),
        RoundIconButton(
          icon: VIcons.chevronDown,
          label: downLabel,
          onPressed: onDown,
        ),
      ],
    );
  }
}
