// Glass sheet over the blurred landscape: grabber, title, actions, close button.
// Used by Paysages, Mon mix, Partage, Sommeil, Programmations, Premium, Réglages…
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../landscape/landscape_image.dart';
import '../model_scope.dart';
import '../theme/vitre.dart';
import 'glass.dart';
import 'vicons.dart';

class VitreSheet extends StatefulWidget {
  const VitreSheet({
    super.key,
    required this.title,
    required this.child,
    this.top = 96,
    this.panelAlpha = 0.72,
    this.backgroundBrightness = 0.55,
    this.backgroundSaturation = 0.9,
    this.backgroundBlur = 3,
    this.actions = const [],
    this.onClose,
    this.titleSize = 28,
    this.footer,
    this.scrollable = true,
    this.contentPadding = const EdgeInsets.fromLTRB(20, 8, 20, 32),
    this.background,
    this.headerTop = 28,
    this.scrollController,
  });

  final String title;
  final Widget child;

  /// Distance from the top of the screen in the 844 px mockup frame.
  final double top;
  final double panelAlpha;
  final double backgroundBrightness;
  final double backgroundSaturation;
  final double backgroundBlur;
  final List<Widget> actions;
  final VoidCallback? onClose;
  final double titleSize;

  /// Fixed area under the scrolling content (« Enregistrer »).
  final Widget? footer;
  final bool scrollable;
  final EdgeInsetsGeometry contentPadding;

  /// Replaces the default blurred landscape.
  final Widget? background;
  final double headerTop;
  final ScrollController? scrollController;

  @override
  State<VitreSheet> createState() => _VitreSheetState();
}

class _VitreSheetState extends State<VitreSheet> {
  double _drag = 0;

  void _close() {
    if (widget.onClose != null) {
      widget.onClose!();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final landscape = model.catalog.landscape(model.browsedLandscapeId) ?? model.catalog.defaultLandscape;
    final media = MediaQuery.of(context);
    final top = math.max(widget.top, media.padding.top + 12);
    final bottomInset = media.padding.bottom;

    final header = GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragUpdate: (d) => setState(() => _drag = math.max(0, _drag + d.delta.dy)),
      onVerticalDragEnd: (d) {
        if (_drag > 90 || (d.primaryVelocity ?? 0) > 700) {
          _close();
        }
        setState(() => _drag = 0);
      },
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, widget.headerTop, 20, 12),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  widget.title,
                  style: manrope(widget.titleSize, weight: 600, letterSpacingEm: -0.02, height: 1.15),
                ),
              ),
            ),
            for (final a in widget.actions) ...[a, const SizedBox(width: 10)],
            RoundIconButton(icon: VIcons.close, label: 'Fermer', onPressed: _close),
          ],
        ),
      ),
    );

    Widget content = widget.child;
    if (widget.scrollable) {
      content = SingleChildScrollView(
        controller: widget.scrollController,
        padding: widget.contentPadding.add(EdgeInsets.only(bottom: widget.footer == null ? bottomInset : 0)),
        child: content,
      );
    } else {
      content = Padding(padding: widget.contentPadding, child: content);
    }

    return Scaffold(
      backgroundColor: VitreColors.page,
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          Positioned.fill(
            child: widget.background ??
                LandscapeImage(
                  landscapeId: landscape.id,
                  style: landscape.style,
                  moment: model.scene.moment,
                  brightness: widget.backgroundBrightness,
                  saturation: widget.backgroundSaturation,
                  blurSigma: widget.backgroundBlur,
                ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: top + _drag,
            bottom: -_drag,
            child: GlassPanel(
              alpha: widget.panelAlpha,
              borderAlpha: 0.2,
              blur: 36,
              shadow: false,
              topBorderOnly: true,
              radius: const BorderRadius.vertical(top: Radius.circular(32)),
              child: Stack(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      header,
                      Expanded(child: content),
                      if (widget.footer != null)
                        Padding(
                          padding: EdgeInsets.fromLTRB(20, 8, 20, 24 + bottomInset),
                          child: widget.footer,
                        ),
                    ],
                  ),
                  const Positioned(top: 10, left: 0, right: 0, child: Center(child: _Grabber())),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Grabber extends StatelessWidget {
  const _Grabber();

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Container(
        width: 44,
        height: 5,
        decoration: BoxDecoration(
          color: Vitre.of(context).text(0.35),
          borderRadius: BorderRadius.circular(3),
        ),
      ),
    );
  }
}

/// Body text of sheets (18 px, 84 % white).
class SheetText extends StatelessWidget {
  const SheetText(this.text, {super.key, this.size = 18, this.alpha = 0.84, this.align, this.weight = 400});

  final String text;
  final double size;
  final double alpha;
  final TextAlign? align;
  final int weight;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      textAlign: align,
      style: manrope(size, weight: weight, height: 1.4, color: Vitre.of(context).text(alpha)),
    );
  }
}
