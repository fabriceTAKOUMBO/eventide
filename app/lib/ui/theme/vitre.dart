// Design system « Vitre »: dark translucent glass over full-screen landscapes.
// Values come from the validated mockup (390 × 844 frames).
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Raw colors of the mockup.
abstract final class VitreColors {
  static const Color page = Color(0xFF050807);
  static const Color ink = Color(0xFF0A0F0D);
  static const Color white = Color(0xFFFFFFFF);
  static const Color wordmark = Color(0xFFF4F1EA);
  static const Color thumbFallback = Color(0xFF2A3A2C);

  /// Base color of glass panels: rgba(6,10,8,a).
  static Color glassBase(double alpha) => Color.fromRGBO(6, 10, 8, alpha);
  static Color whiteA(double alpha) => Color.fromRGBO(255, 255, 255, alpha);
  static Color blackA(double alpha) => Color.fromRGBO(0, 0, 0, alpha);
}

/// Palette that depends on the « Contraste renforcé » option:
/// more opaque panels, sharper borders, pure white text.
@immutable
class VitrePalette {
  const VitrePalette({required this.highContrast});

  final bool highContrast;

  /// Glass panel background.
  Color glass(double alpha) => VitreColors.glassBase(
    highContrast ? math.min(0.94, alpha + 0.24) : alpha,
  );

  /// Hairline borders of panels and buttons.
  Color border(double alpha) => VitreColors.whiteA(
    highContrast ? math.max(0.62, math.min(1, alpha * 3)) : alpha,
  );

  /// Secondary text (white with reduced opacity; pure white in high contrast).
  Color text(double alpha) => VitreColors.whiteA(highContrast ? 1 : alpha);

  /// Translucent white fills of tiles, chips and secondary buttons.
  Color fill(double alpha) =>
      VitreColors.whiteA(highContrast ? math.min(0.32, alpha * 1.8) : alpha);

  Color get primaryText => VitreColors.white;

  @override
  bool operator ==(Object other) =>
      other is VitrePalette && other.highContrast == highContrast;

  @override
  int get hashCode => highContrast.hashCode;
}

/// Gives the palette and motion preference to the whole tree.
class Vitre extends InheritedWidget {
  const Vitre({super.key, required this.palette, required super.child});

  final VitrePalette palette;

  static VitrePalette of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<Vitre>()?.palette ??
      const VitrePalette(highContrast: false);

  /// True when the user asked Android for fewer animations.
  static bool reduceMotion(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  @override
  bool updateShouldNotify(Vitre oldWidget) => oldWidget.palette != palette;
}

/// Display face of the « Galerie » style: landscape names and titles only.
const String kDisplayFamily = 'Cormorant Garamond';

/// Type roles of the « Galerie » style (product owner, 29 October 2026): Cormorant Garamond 500
/// for landscape names (italic) and titles, a lighter Manrope for everything else, spaced
/// capitals for eyebrows and buttons. Sizes are logical pixels at text scale 1 (384-dp phone);
/// every role follows the Android text size and the in-app A−/A+ factor.
abstract final class VitreType {
  static const double displaySize = 32;
  static const double titleSize = 32;
  static const double headingSize = 24;
  static const double bodySize = 15;
  static const double smallSize = 13.5;
  static const double labelSize = 16;
  static const double eyebrowSize = 11.5;
  static const double buttonSize = 13;

  /// Landscape names: Cormorant Garamond 500 italic, slight positive tracking.
  static TextStyle display({
    double size = displaySize,
    Color color = VitreColors.white,
    double height = 1.08,
    List<Shadow>? shadows,
  }) => _serif(size, italic: true, color: color, height: height, shadows: shadows);

  /// Screen, sheet, dialog and card titles: Cormorant Garamond 500 upright.
  static TextStyle title({
    double size = titleSize,
    Color color = VitreColors.white,
    double height = 1.12,
  }) => _serif(size, italic: false, color: color, height: height);

  /// Body text: Manrope 400.
  static TextStyle body({
    double size = bodySize,
    Color color = VitreColors.white,
    double height = 1.45,
  }) => manrope(size, color: color, height: height, letterSpacingEm: 0.01);

  /// Secondary text (subtitles, notes, prices' units): Manrope 400, smaller.
  static TextStyle small({
    double size = smallSize,
    Color color = VitreColors.white,
    double height = 1.4,
    TextDecoration? decoration,
  }) => manrope(
    size,
    color: color,
    height: height,
    letterSpacingEm: 0.01,
    decoration: decoration,
  );

  /// Emphasised UI labels (row titles, tiles, chips, tabs, prices): Manrope 500.
  static TextStyle label({
    double size = labelSize,
    Color color = VitreColors.white,
    int weight = 500,
    double? height,
    TextDecoration? decoration,
  }) => manrope(
    size,
    weight: weight,
    color: color,
    height: height,
    letterSpacingEm: 0.01,
    decoration: decoration,
  );

  /// Eyebrows and section labels: Manrope 500 in spaced capitals (draw with [CapsText]).
  static TextStyle eyebrow({
    double size = eyebrowSize,
    Color color = VitreColors.white,
  }) => manrope(
    size,
    weight: 500,
    color: color,
    height: 1.3,
    letterSpacingEm: 0.22,
  );

  /// Button labels: Manrope 600 in spaced capitals (draw with [CapsText]).
  static TextStyle button({
    double size = buttonSize,
    Color color = VitreColors.white,
  }) => manrope(
    size,
    weight: 600,
    color: color,
    height: 1.3,
    letterSpacingEm: 0.16,
  ).copyWith(leadingDistribution: TextLeadingDistribution.even);

  /// Large figures (times, durations, levels): Manrope light.
  static TextStyle figure(
    double size, {
    Color color = VitreColors.white,
    int weight = 300,
    double height = 1.1,
  }) => manrope(size, weight: weight, color: color, height: height);

  static TextStyle _serif(
    double size, {
    required bool italic,
    required Color color,
    required double height,
    List<Shadow>? shadows,
  }) => TextStyle(
    fontFamily: kDisplayFamily,
    fontSize: size,
    fontWeight: FontWeight.w500,
    fontStyle: italic ? FontStyle.italic : FontStyle.normal,
    color: color,
    height: height,
    letterSpacing: 0.005 * size,
    shadows: shadows,
  );
}

/// Text in spaced capitals (eyebrows, buttons): shows [text] upper-cased, while TalkBack reads
/// it as written (never spelled letter by letter).
class CapsText extends StatelessWidget {
  const CapsText(
    this.text, {
    super.key,
    required this.style,
    this.textAlign,
    this.maxLines,
    this.overflow,
    this.textScaler,
  });

  final String text;
  final TextStyle style;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextScaler? textScaler;

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    semanticsLabel: text,
    style: style,
    textAlign: textAlign,
    maxLines: maxLines,
    overflow: overflow,
    textScaler: textScaler,
  );
}

/// Manrope with the weight applied both as `fontWeight` and as the `wght` axis
/// (the variable font defaults to 200). Prefer the roles of [VitreType].
TextStyle manrope(
  double size, {
  int weight = 400,
  Color color = VitreColors.white,
  double? height,
  double letterSpacingEm = 0,
  TextDecoration? decoration,
  List<Shadow>? shadows,
}) {
  return TextStyle(
    fontFamily: 'Manrope',
    fontSize: size,
    fontWeight: _weight(weight),
    fontVariations: [FontVariation.weight(weight.toDouble())],
    color: color,
    height: height,
    letterSpacing: letterSpacingEm == 0 ? null : letterSpacingEm * size,
    decoration: decoration,
    decorationColor: color,
    shadows: shadows,
  );
}

/// Fraunces (wordmark only). Optical size follows the font size like browsers do.
TextStyle fraunces(
  double size, {
  int weight = 500,
  Color color = VitreColors.wordmark,
}) {
  return TextStyle(
    fontFamily: 'Fraunces',
    fontSize: size,
    fontWeight: _weight(weight),
    fontVariations: [
      FontVariation.weight(weight.toDouble()),
      FontVariation('opsz', size.clamp(9, 144).toDouble()),
      const FontVariation('SOFT', 0),
      const FontVariation('WONK', 0),
    ],
    color: color,
    height: 1.1,
  );
}

FontWeight _weight(int w) {
  final index = ((w / 100).round() - 1).clamp(0, 8);
  return FontWeight.values[index];
}

/// Durations that collapse to zero with reduced motion.
Duration motion(BuildContext context, Duration d) =>
    Vitre.reduceMotion(context) ? Duration.zero : d;

/// Multiplies the system text scale by the in-app A−/A+ factor.
/// Keeps Android 14 non-linear scaling of the system scaler.
class MultipliedTextScaler extends TextScaler {
  const MultipliedTextScaler(this.base, this.factor);

  final TextScaler base;
  final double factor;

  @override
  double scale(double fontSize) => base.scale(fontSize) * factor;

  @override
  // ignore: deprecated_member_use
  double get textScaleFactor => base.textScaleFactor * factor;

  @override
  bool operator ==(Object other) =>
      other is MultipliedTextScaler &&
      other.base == base &&
      other.factor == factor;

  @override
  int get hashCode => Object.hash(base, factor);
}

/// Material theme used underneath (dialogs, focus, selection); most widgets are custom.
ThemeData vitreMaterialTheme() {
  final base = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    fontFamily: 'Manrope',
    scaffoldBackgroundColor: VitreColors.page,
    colorScheme: const ColorScheme.dark(
      primary: VitreColors.white,
      onPrimary: VitreColors.ink,
      surface: Color(0xFF0B110E),
      onSurface: VitreColors.white,
    ),
    splashFactory: InkSparkle.splashFactory,
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(
      fontFamily: 'Manrope',
      bodyColor: Colors.white,
      displayColor: Colors.white,
    ),
    tooltipTheme: TooltipThemeData(
      textStyle: VitreType.label(size: 14, color: VitreColors.ink),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
      ),
      waitDuration: const Duration(milliseconds: 600),
    ),
  );
}
