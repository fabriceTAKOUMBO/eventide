// Glass building blocks of the « Vitre » design system.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/vitre.dart';
import 'vicons.dart';

/// True when text is shown above 150 % (system size × in-app size): layouts with a
/// wide trailing element then stack it under the text.
bool isLargeText(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(20) > 30;

/// Dark translucent panel with backdrop blur, hairline border and deep shadow.
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.alpha = 0.55,
    this.borderAlpha = 0.16,
    this.radius = const BorderRadius.all(Radius.circular(36)),
    this.blur = 30,
    this.padding = EdgeInsets.zero,
    this.shadow = true,
    this.topBorderOnly = false,
  });

  final Widget child;
  final double alpha;
  final double borderAlpha;
  final BorderRadius radius;
  final double blur;
  final EdgeInsetsGeometry padding;
  final bool shadow;

  /// Sheet variant: only the top border.
  final bool topBorderOnly;

  @override
  Widget build(BuildContext context) {
    final p = Vitre.of(context);
    final side = BorderSide(color: p.border(borderAlpha));
    final border = topBorderOnly
        ? Border(top: side)
        : Border.fromBorderSide(side);
    Widget content = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: p.glass(alpha),
        borderRadius: radius,
        border: border,
      ),
      child: child,
    );
    if (blur > 0) {
      content = BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: blur / 2, sigmaY: blur / 2),
        child: content,
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: shadow
            ? const [
                BoxShadow(
                  color: Color(0x80000000),
                  blurRadius: 60,
                  offset: Offset(0, 24),
                ),
              ]
            : null,
      ),
      child: ClipRRect(borderRadius: radius, child: content),
    );
  }
}

/// Plain pressable surface with ink feedback, minimum 48 px, labelled for TalkBack.
class Pressable extends StatelessWidget {
  const Pressable({
    super.key,
    required this.child,
    required this.onTap,
    this.borderRadius = const BorderRadius.all(Radius.circular(24)),
    this.semanticLabel,
    this.button = true,
    this.selected,
    this.toggled,
    this.enabled = true,
    this.tooltip,
  });

  final Widget child;
  final VoidCallback? onTap;
  final BorderRadius borderRadius;
  final String? semanticLabel;
  final bool button;
  final bool? selected;
  final bool? toggled;
  final bool enabled;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final active = enabled && onTap != null;
    Widget w = Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: active
            ? () {
                HapticFeedback.selectionClick();
                onTap!();
              }
            : null,
        borderRadius: borderRadius,
        splashColor: VitreColors.whiteA(0.12),
        highlightColor: VitreColors.whiteA(0.06),
        child: child,
      ),
    );
    if (semanticLabel != null) {
      w = Semantics(
        button: button,
        enabled: active,
        selected: selected,
        toggled: toggled,
        label: semanticLabel,
        container: true,
        excludeSemantics: true,
        onTap: active ? onTap : null,
        child: w,
      );
    }
    if (tooltip != null) {
      w = Tooltip(message: tooltip!, excludeFromSemantics: true, child: w);
    }
    return w;
  }
}

/// Round 48 px glass icon button (close, moon, gear, arrows…). Always labelled.
class RoundIconButton extends StatelessWidget {
  const RoundIconButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.size = 48,
    this.iconSize = 24,
    this.background,
    this.foreground,
    this.borderAlpha = 0.22,
    this.fillAlpha = 0.08,
    this.dark = false,
    this.blur = 0,
    this.opacity = 1,
    this.selected,
  });

  final VIconData icon;
  final String label;
  final VoidCallback? onPressed;
  final double size;
  final double iconSize;
  final Color? background;
  final Color? foreground;
  final double borderAlpha;
  final double fillAlpha;

  /// Dark glass background instead of white tint (right edge controls of home).
  final bool dark;
  final double blur;
  final double opacity;
  final bool? selected;

  @override
  Widget build(BuildContext context) {
    final p = Vitre.of(context);
    final radius = BorderRadius.circular(size / 2);
    final bg = background ?? (dark ? p.glass(0.35) : p.fill(fillAlpha));
    Widget body = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: radius,
        border: Border.all(color: p.border(borderAlpha)),
      ),
      alignment: Alignment.center,
      child: VIcon(
        icon,
        size: iconSize,
        color: foreground ?? VitreColors.white,
      ),
    );
    if (blur > 0) {
      body = ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: blur / 2, sigmaY: blur / 2),
          child: body,
        ),
      );
    }
    return Opacity(
      opacity: opacity,
      child: Pressable(
        onTap: onPressed,
        borderRadius: radius,
        semanticLabel: label,
        selected: selected,
        tooltip: label,
        child: body,
      ),
    );
  }
}

/// White primary button (56 px, fully rounded, label in spaced capitals). Grows with large
/// text; TalkBack reads the label as written.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.height = 56,
    this.fontSize = VitreType.buttonSize,
    this.busy = false,
    this.semanticLabel,
  });

  final String label;
  final VoidCallback? onPressed;
  final VIconData? icon;
  final double height;
  final double fontSize;
  final bool busy;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !busy;
    final radius = BorderRadius.circular(height / 2);
    return Opacity(
      opacity: onPressed == null ? 0.5 : 1,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: const [
            BoxShadow(
              color: Color(0x59000000),
              blurRadius: 24,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: Material(
          color: VitreColors.white,
          borderRadius: radius,
          child: Semantics(
            button: true,
            enabled: enabled,
            label: semanticLabel ?? label,
            container: true,
            excludeSemantics: true,
            onTap: enabled ? onPressed : null,
            child: InkWell(
              borderRadius: radius,
              onTap: enabled
                  ? () {
                      HapticFeedback.lightImpact();
                      onPressed!();
                    }
                  : null,
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: height),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 8,
                  ),
                  child: Center(
                    child: busy
                        ? const SizedBox.square(
                            dimension: 26,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.6,
                              color: VitreColors.ink,
                            ),
                          )
                        : _IconLabel(
                            icon: icon,
                            label: label,
                            style: VitreType.button(
                              size: fontSize,
                              color: VitreColors.ink,
                            ),
                            iconSize: 20,
                            color: VitreColors.ink,
                          ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Glass secondary button with a white hairline border (label in spaced capitals).
class SecondaryButton extends StatelessWidget {
  const SecondaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.height = 52,
    this.fontSize = VitreType.buttonSize,
    this.borderAlpha = 0.28,
    this.fillAlpha = 0.08,
    this.semanticLabel,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final VIconData? icon;
  final double height;
  final double fontSize;
  final double borderAlpha;
  final double fillAlpha;
  final String? semanticLabel;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final p = Vitre.of(context);
    final radius = BorderRadius.circular(height / 2);
    return Opacity(
      opacity: onPressed == null ? 0.5 : 1,
      child: Pressable(
        onTap: busy ? null : onPressed,
        borderRadius: radius,
        semanticLabel: semanticLabel ?? label,
        child: Container(
          constraints: BoxConstraints(minHeight: height),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          decoration: BoxDecoration(
            color: p.fill(fillAlpha),
            borderRadius: radius,
            border: Border.all(color: p.border(borderAlpha)),
          ),
          alignment: Alignment.center,
          child: busy
              ? const SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.4,
                    color: VitreColors.white,
                  ),
                )
              : _IconLabel(
                  icon: icon,
                  label: label,
                  style: VitreType.button(size: fontSize),
                  iconSize: 19,
                  color: VitreColors.white,
                ),
        ),
      ),
    );
  }
}

/// Text-only link button (« Restaurer mes achats », « J’ai déjà un compte »).
class LinkButton extends StatelessWidget {
  const LinkButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.underline = false,
    this.fontSize = 14,
    this.weight = 500,
    this.alpha = 0.86,
    this.height = 48,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool underline;
  final double fontSize;
  final int weight;
  final double alpha;
  final double height;

  @override
  Widget build(BuildContext context) {
    final p = Vitre.of(context);
    final color = p.text(alpha);
    return Pressable(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(height / 2),
      semanticLabel: label,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: height, minWidth: 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Center(
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: VitreType.label(
                size: fontSize,
                weight: weight,
                color: color,
                decoration: underline ? TextDecoration.underline : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _IconLabel extends StatelessWidget {
  const _IconLabel({
    required this.icon,
    required this.label,
    required this.style,
    required this.iconSize,
    required this.color,
  });

  final VIconData? icon;
  final String label;
  final TextStyle style;
  final double iconSize;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final text = CapsText(label, textAlign: TextAlign.center, style: style);
    if (icon == null) return text;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        VIcon(icon!, size: iconSize, color: color),
        const SizedBox(width: 12),
        Flexible(child: text),
      ],
    );
  }
}

/// Section label in spaced capitals (« ÉCOUTE », « JOURS »…), a header for TalkBack.
class SectionLabel extends StatelessWidget {
  const SectionLabel(
    this.text, {
    super.key,
    this.padding = const EdgeInsets.fromLTRB(4, 18, 4, 10),
  });

  final String text;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Semantics(
        header: true,
        child: CapsText(
          text,
          style: VitreType.eyebrow(color: Vitre.of(context).text(0.7)),
        ),
      ),
    );
  }
}

/// Large switch of the mockup (60 × 36, white track when on, dark knob).
class VitreSwitchVisual extends StatelessWidget {
  const VitreSwitchVisual({super.key, required this.value});

  final bool value;

  @override
  Widget build(BuildContext context) {
    final p = Vitre.of(context);
    final d = motion(context, const Duration(milliseconds: 180));
    return AnimatedContainer(
      duration: d,
      width: 60,
      height: 36,
      decoration: BoxDecoration(
        color: value ? VitreColors.white : p.fill(0.22),
        borderRadius: BorderRadius.circular(18),
        border: p.highContrast && !value
            ? Border.all(color: p.border(0.5))
            : null,
      ),
      child: AnimatedAlign(
        duration: d,
        curve: Curves.easeOutCubic,
        alignment: value ? Alignment.centerRight : Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: value ? VitreColors.ink : VitreColors.white,
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
      ),
    );
  }
}

/// Settings row with title, subtitle and a large switch; the whole row toggles.
class SwitchRow extends StatelessWidget {
  const SwitchRow({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.locked = false,
    this.onLockedTap,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool locked;
  final VoidCallback? onLockedTap;

  @override
  Widget build(BuildContext context) {
    final p = Vitre.of(context);
    final radius = BorderRadius.circular(22);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        toggled: locked ? null : value,
        button: locked,
        label: locked ? '$title, avec Premium' : title,
        hint: subtitle,
        container: true,
        excludeSemantics: true,
        onTap: locked
            ? onLockedTap
            : (onChanged == null ? null : () => onChanged!(!value)),
        child: Material(
          color: p.fill(0.07),
          borderRadius: radius,
          child: InkWell(
            borderRadius: radius,
            onTap: locked
                ? onLockedTap
                : (onChanged == null ? null : () => onChanged!(!value)),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: subtitle == null ? 58 : 66),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                child: Builder(
                  builder: (context) {
                    final texts = Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(title, style: VitreType.label()),
                        if (subtitle != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            subtitle!,
                            style: VitreType.small(color: p.text(0.7)),
                          ),
                        ],
                      ],
                    );
                    final control = locked
                        ? VIcon(VIcons.lock, size: 24, color: p.text(0.9))
                        : VitreSwitchVisual(value: value);
                    // Large text: the switch goes under the words, which keep
                    // the full width (no word split in two).
                    if (isLargeText(context)) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [texts, const SizedBox(height: 10), control],
                      );
                    }
                    return Row(
                      children: [
                        Expanded(child: texts),
                        const SizedBox(width: 12),
                        control,
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Navigation row with a chevron.
class LinkRow extends StatelessWidget {
  const LinkRow({
    super.key,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.leading,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final Widget? leading;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final p = Vitre.of(context);
    final radius = BorderRadius.circular(22);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        button: true,
        label: title,
        hint: subtitle,
        container: true,
        excludeSemantics: true,
        onTap: onTap,
        child: Material(
          color: p.fill(0.07),
          borderRadius: radius,
          child: InkWell(
            borderRadius: radius,
            onTap: onTap,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: subtitle == null ? 58 : 66,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    if (leading != null) ...[
                      leading!,
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(title, style: VitreType.label()),
                          if (subtitle != null) ...[
                            const SizedBox(height: 2),
                            Text(
                              subtitle!,
                              style: VitreType.small(color: p.text(0.7)),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    trailing ??
                        VIcon(
                          VIcons.chevronRight,
                          size: 20,
                          color: p.text(0.7),
                        ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// White-or-glass chip (moment, ramp, reminder, day pills).
class ChoiceChipButton extends StatelessWidget {
  const ChoiceChipButton({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.height = 52,
    this.fontSize = 15,
    this.semanticLabel,
    this.radio = true,
    this.width,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final double height;
  final double fontSize;
  final String? semanticLabel;
  final bool radio;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final p = Vitre.of(context);
    final radius = BorderRadius.circular(height / 2);
    return Semantics(
      inMutuallyExclusiveGroup: radio ? true : null,
      checked: radio ? selected : null,
      toggled: radio ? null : selected,
      button: true,
      label: semanticLabel ?? label,
      container: true,
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: selected ? VitreColors.white : p.fill(0.08),
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(
            color: selected ? VitreColors.white : p.border(0.22),
          ),
        ),
        child: InkWell(
          borderRadius: radius,
          onTap: onTap == null
              ? null
              : () {
                  HapticFeedback.selectionClick();
                  onTap!();
                },
          child: Container(
            width: width,
            constraints: BoxConstraints(minHeight: height, minWidth: 48),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            alignment: Alignment.center,
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: VitreType.label(
                size: fontSize,
                color: selected ? VitreColors.ink : VitreColors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Segmented control (Mon mix tabs, home themes).
class SegmentedTabs extends StatelessWidget {
  const SegmentedTabs({
    super.key,
    required this.labels,
    required this.selected,
    required this.onSelected,
    this.height = 52,
    this.expand = true,
    this.fontSize = 15,
    this.semanticGroupLabel,
    this.backgroundAlpha,
    this.dark = false,
  });

  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelected;
  final double height;
  final bool expand;
  final double fontSize;
  final String? semanticGroupLabel;
  final double? backgroundAlpha;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final p = Vitre.of(context);
    final inner = height - 8;
    final items = <Widget>[
      for (var i = 0; i < labels.length; i++) _segment(context, i, inner),
    ];
    return Semantics(
      container: true,
      label: semanticGroupLabel,
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: dark
              ? p.glass(backgroundAlpha ?? 0.42)
              : p.fill(backgroundAlpha ?? 0.08),
          borderRadius: BorderRadius.circular(height / 2),
          border: Border.all(color: p.border(dark ? 0.18 : 0.14)),
        ),
        child: expand
            ? Row(children: [for (final w in items) Expanded(child: w)])
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < items.length; i++) ...[
                    if (i > 0) const SizedBox(width: 4),
                    items[i],
                  ],
                ],
              ),
      ),
    );
  }

  Widget _segment(BuildContext context, int i, double inner) {
    final p = Vitre.of(context);
    final on = i == selected;
    final radius = BorderRadius.circular(inner / 2);
    return Semantics(
      selected: on,
      button: true,
      label: labels[i],
      container: true,
      excludeSemantics: true,
      onTap: () => onSelected(i),
      child: Material(
        color: on ? VitreColors.white : Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: () {
            HapticFeedback.selectionClick();
            onSelected(i);
          },
          child: Container(
            constraints: BoxConstraints(minHeight: inner),
            padding: EdgeInsets.symmetric(
              horizontal: expand ? 4 : 18,
              vertical: 4,
            ),
            alignment: Alignment.center,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                labels[i],
                textAlign: TextAlign.center,
                maxLines: 1,
                style: VitreType.label(
                  size: fontSize,
                  color: on ? VitreColors.ink : p.text(0.86),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Card with a light glass fill used inside sheets.
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(20, 18, 20, 18),
    this.radius = 28,
    this.fillAlpha = 0.07,
    this.borderAlpha = 0.14,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final double fillAlpha;
  final double borderAlpha;

  @override
  Widget build(BuildContext context) {
    final p = Vitre.of(context);
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: p.fill(fillAlpha),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: p.border(borderAlpha)),
      ),
      child: child,
    );
  }
}

/// Rounded rectangle with a dashed border (permission card, empty states).
class DashedBorderBox extends StatelessWidget {
  const DashedBorderBox({
    super.key,
    required this.child,
    this.radius = 24,
    this.padding = const EdgeInsets.fromLTRB(16, 14, 14, 14),
    this.alpha = 0.4,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;
  final double alpha;

  @override
  Widget build(BuildContext context) {
    final p = Vitre.of(context);
    return CustomPaint(
      painter: _DashedRRectPainter(color: p.border(alpha), radius: radius),
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          color: p.fill(0.06),
          borderRadius: BorderRadius.circular(radius),
        ),
        child: child,
      ),
    );
  }
}

class _DashedRRectPainter extends CustomPainter {
  _DashedRRectPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    ).deflate(0.5);
    final source = Path()..addRRect(rrect);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final metric in source.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        canvas.drawPath(metric.extractPath(d, d + 4), paint);
        d += 7;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedRRectPainter old) =>
      old.color != color || old.radius != radius;
}
