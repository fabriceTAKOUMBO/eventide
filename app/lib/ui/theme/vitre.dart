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

/// Manrope with the weight applied both as `fontWeight` and as the `wght` axis
/// (the variable font defaults to 200).
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
      textStyle: manrope(16, weight: 600, color: VitreColors.ink),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
      ),
      waitDuration: const Duration(milliseconds: 600),
    ),
  );
}
