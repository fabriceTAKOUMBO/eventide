// Screen 4 · Mon mix: Sons / Musique / Décor, levels by 10 % steps or slider,
// 0 % removes, « Moment de la journée » in Décor. No microphone here (intended).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/catalog.dart';
import '../../core/scene.dart';
import '../model_scope.dart';
import '../navigation.dart';
import '../theme/vitre.dart';
import '../widgets/glass.dart';
import '../widgets/sheet_scaffold.dart';
import '../widgets/vicons.dart';

class MixSheet extends StatefulWidget {
  const MixSheet({super.key, this.initialKind = LayerKind.son});

  final LayerKind initialKind;

  @override
  State<MixSheet> createState() => _MixSheetState();
}

const Map<LayerKind, (String, String, String)> _texts = {
  LayerKind.son: ('Dans mon mix', 'Ajouter un son', 'Baissez à 0 % pour retirer un son.'),
  LayerKind.musique: ('Musique de fond', 'Ajouter une musique', 'Baissez à 0 % pour retirer une musique.'),
  LayerKind.decor: ('Sur l’image', 'Ajouter à l’image', 'Baissez à 0 % pour retirer un effet.'),
};

class _MixSheetState extends State<MixSheet> {
  late LayerKind _kind = widget.initialKind;

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final p = Vitre.of(context);
    final catalog = model.catalog;
    final scene = model.scene;
    final texts = _texts[_kind]!;
    final active = scene.layers(_kind);
    final activeIds = {for (final l in active) l.id};
    final available = [for (final item in catalog.items(_kind)) if (!activeIds.contains(item.id)) item];

    return VitreSheet(
      title: 'Mon mix',
      top: 100,
      panelAlpha: 0.72,
      backgroundBrightness: 0.62,
      actions: [
        RoundIconButton(icon: VIcons.share, label: 'Partager mon ambiance', onPressed: () => Nav.share(context)),
      ],
      scrollable: false,
      contentPadding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
            child: SegmentedTabs(
              labels: [for (final k in LayerKind.values) k.label],
              selected: _kind.index,
              onSelected: (i) => setState(() => _kind = LayerKind.values[i]),
              semanticGroupLabel: 'Type de réglage',
            ),
          ),
          Expanded(
            child: ListView(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 40 + MediaQuery.paddingOf(context).bottom),
              children: [
                if (_kind == LayerKind.decor) ...[
                  const SectionLabel('Moment de la journée', padding: EdgeInsets.fromLTRB(4, 4, 4, 10)),
                  Semantics(
                    label: 'Moment de la journée',
                    container: true,
                    explicitChildNodes: true,
                    child: Row(
                      children: [
                        for (final m in Moment.values) ...[
                          if (m.index > 0) const SizedBox(width: 8),
                          Expanded(
                            child: ChoiceChipButton(
                              label: m.label,
                              selected: scene.moment == m,
                              height: 52,
                              onTap: () => model.setMoment(m),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 22),
                ],
                if (active.isNotEmpty)
                  SectionLabel(texts.$1, padding: const EdgeInsets.fromLTRB(4, 4, 4, 10))
                else
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 4, 4, 14),
                    child: Text(
                      'Rien pour l’instant. Ajoutez un élément dans la liste ci-dessous.',
                      style: manrope(17, height: 1.35, color: p.text(0.78)),
                    ),
                  ),
                for (final layer in active)
                  _LevelRow(
                    key: ValueKey('${_kind.name}-${layer.id}'),
                    name: catalog.item(_kind, layer.id)?.name ?? layer.id,
                    level: layer.level,
                    onChanged: (v) => model.setLayerLevel(_kind, layer.id, v),
                  ),
                if (active.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                    child: Text(texts.$3, style: manrope(16, height: 1.35, color: p.text(0.66))),
                  ),
                SectionLabel(texts.$2, padding: const EdgeInsets.fromLTRB(4, 22, 4, 10)),
                for (final item in available)
                  _AddRow(
                    item: item,
                    locked: !model.rules.canUseItem(model.plan, _kind, item.id),
                    onTap: () => model.setLayerLevel(_kind, item.id, 30),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AddRow extends StatelessWidget {
  const _AddRow({required this.item, required this.locked, required this.onTap});

  final CatalogItem item;
  final bool locked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = Vitre.of(context);
    final label = 'Ajouter ${item.name.toLowerCase()}${locked ? ', avec Premium' : ''}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Pressable(
        onTap: onTap,
        borderRadius: BorderRadius.circular(28),
        semanticLabel: label,
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.fromLTRB(10, 6, 14, 6),
          decoration: BoxDecoration(
            color: p.fill(0.07),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: p.border(0.16)),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(color: p.fill(0.14), shape: BoxShape.circle),
                alignment: Alignment.center,
                child: VIcon(locked ? VIcons.lock : VIcons.plus, size: locked ? 18 : 20, color: VitreColors.white, strokeWidth: locked ? 2.1 : 2.4),
              ),
              const SizedBox(width: 14),
              Expanded(child: Text(item.name, style: manrope(18, weight: 600))),
              if (locked) Text('Premium', style: manrope(16, weight: 600, color: p.text(0.7))),
            ],
          ),
        ),
      ),
    );
  }
}

/// One active element: name, percentage, − / slider / +.
class _LevelRow extends StatefulWidget {
  const _LevelRow({super.key, required this.name, required this.level, required this.onChanged});

  final String name;
  final int level;
  final ValueChanged<int> onChanged;

  @override
  State<_LevelRow> createState() => _LevelRowState();
}

class _LevelRowState extends State<_LevelRow> {
  int? _dragValue;

  int get _value => _dragValue ?? widget.level;

  void _step(int delta) {
    final v = ((_value + delta) / 10).round() * 10;
    widget.onChanged(v.clamp(0, 100));
  }

  @override
  Widget build(BuildContext context) {
    final p = Vitre.of(context);
    final lower = widget.name.toLowerCase();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(child: Text(widget.name, style: manrope(19, weight: 700))),
                Text('$_value %', style: manrope(17, color: p.text(0.78))),
              ],
            ),
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              RoundIconButton(icon: VIcons.minus, iconSize: 22, label: 'Baisser $lower', onPressed: () => _step(-10)),
              const SizedBox(width: 8),
              Expanded(
                child: LevelSlider(
                  value: _value,
                  label: widget.name,
                  onChanged: (v) {
                    setState(() => _dragValue = v);
                    // Live volume while dragging, without removing the element.
                    widget.onChanged(v < 1 ? 1 : v);
                  },
                  onChangeEnd: (v) {
                    setState(() => _dragValue = null);
                    widget.onChanged(v);
                  },
                  onStep: _step,
                ),
              ),
              const SizedBox(width: 8),
              RoundIconButton(icon: VIcons.plus, iconSize: 22, label: 'Augmenter $lower', onPressed: () => _step(10)),
            ],
          ),
        ],
      ),
    );
  }
}

/// Mockup slider: 10 px white track, 28 px white thumb, 48 px touch height.
class LevelSlider extends StatelessWidget {
  const LevelSlider({
    super.key,
    required this.value,
    required this.label,
    required this.onChanged,
    required this.onChangeEnd,
    required this.onStep,
  });

  final int value;
  final String label;
  final ValueChanged<int> onChanged;
  final ValueChanged<int> onChangeEnd;
  final ValueChanged<int> onStep;

  @override
  Widget build(BuildContext context) {
    final p = Vitre.of(context);
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      int toValue(double dx) => (((dx - 14) / (width - 28)) * 100).round().clamp(0, 100);
      return Semantics(
        slider: true,
        label: label,
        value: '$value %',
        increasedValue: '${(value + 10).clamp(0, 100)} %',
        decreasedValue: '${(value - 10).clamp(0, 100)} %',
        onIncrease: () => onStep(10),
        onDecrease: () => onStep(-10),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) => onChangeEnd(toValue(d.localPosition.dx)),
          onHorizontalDragStart: (d) {
            HapticFeedback.selectionClick();
            onChanged(toValue(d.localPosition.dx));
          },
          onHorizontalDragUpdate: (d) => onChanged(toValue(d.localPosition.dx)),
          onHorizontalDragEnd: (_) => onChangeEnd(value),
          child: SizedBox(
            height: 48,
            child: CustomPaint(
              painter: _SliderPainter(
                fraction: value / 100,
                track: p.fill(0.2),
                border: p.highContrast ? p.border(0.6) : null,
              ),
            ),
          ),
        ),
      );
    });
  }
}

class _SliderPainter extends CustomPainter {
  _SliderPainter({required this.fraction, required this.track, this.border});

  final double fraction;
  final Color track;
  final Color? border;

  @override
  void paint(Canvas canvas, Size size) {
    const inset = 14.0;
    final trackRect = RRect.fromLTRBR(inset, 19, size.width - inset, 29, const Radius.circular(5));
    canvas.drawRRect(trackRect, Paint()..color = track);
    if (border != null) {
      canvas.drawRRect(trackRect, Paint()
        ..color = border!
        ..style = PaintingStyle.stroke);
    }
    final x = inset + (size.width - inset * 2) * fraction;
    canvas.drawRRect(RRect.fromLTRBR(inset, 19, x, 29, const Radius.circular(5)), Paint()..color = Colors.white);
    canvas.drawCircle(Offset(x, 24), 14, Paint()
      ..color = const Color(0x80000000)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
    canvas.drawCircle(Offset(x, 24), 14, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_SliderPainter old) => old.fraction != fraction || old.track != track || old.border != border;
}
