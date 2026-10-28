// Glass toast (« Ajouté aux favoris »), shown above every screen.
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../theme/vitre.dart';
import 'vicons.dart';

class ToastMessage {
  const ToastMessage(this.text, {this.check = false, required this.serial});
  final String text;
  final bool check;
  final int serial;
}

class ToastController extends ChangeNotifier {
  ToastMessage? _current;
  Timer? _timer;
  int _serial = 0;

  ToastMessage? get current => _current;

  /// Shows [text] for a few seconds. Confirmations get a check mark.
  void show(String text, {bool? check}) {
    _timer?.cancel();
    final positive =
        check ??
        (text.startsWith('Ajouté') ||
            text.startsWith('Enregistr') ||
            text.contains('copié') ||
            text.startsWith('Achats restaurés'));
    _current = ToastMessage(text, check: positive, serial: _serial++);
    notifyListeners();
    _timer = Timer(const Duration(milliseconds: 2600), hide);
  }

  void hide() {
    _timer?.cancel();
    _timer = null;
    if (_current == null) return;
    _current = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// Gives access to the toast controller.
class ToastHost extends InheritedWidget {
  const ToastHost({super.key, required this.controller, required super.child});

  final ToastController controller;

  static ToastController? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ToastHost>()?.controller;

  static void show(BuildContext context, String text, {bool? check}) =>
      maybeOf(context)?.show(text, check: check);

  @override
  bool updateShouldNotify(ToastHost oldWidget) =>
      oldWidget.controller != controller;
}

/// Overlay that draws the current toast near the top of the screen.
class ToastOverlay extends StatefulWidget {
  const ToastOverlay({super.key, required this.controller});

  final ToastController controller;

  @override
  State<ToastOverlay> createState() => _ToastOverlayState();
}

class _ToastOverlayState extends State<ToastOverlay> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(ToastOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    final message = widget.controller.current;
    if (message != null) {
      final view = View.maybeOf(context);
      if (view != null) {
        SemanticsService.sendAnnouncement(
          view,
          message.text,
          TextDirection.ltr,
        );
      }
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.controller.current;
    final top = MediaQuery.paddingOf(context).top + 140;
    return Positioned(
      top: top,
      left: 20,
      right: 20,
      child: IgnorePointer(
        ignoring: message == null,
        child: Center(
          child: AnimatedSwitcher(
            duration: motion(context, const Duration(milliseconds: 220)),
            child: message == null
                ? const SizedBox.shrink()
                : GestureDetector(
                    key: ValueKey(message.serial),
                    onTap: widget.controller.hide,
                    child: _ToastPill(message: message),
                  ),
          ),
        ),
      ),
    );
  }
}

class _ToastPill extends StatelessWidget {
  const _ToastPill({required this.message});

  final ToastMessage message;

  @override
  Widget build(BuildContext context) {
    final p = Vitre.of(context);
    return Semantics(
      liveRegion: true,
      container: true,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: Container(
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: p.glass(0.72),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: p.border(0.2)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (message.check) ...[
                  const VIcon(VIcons.check, size: 18, color: VitreColors.white),
                  const SizedBox(width: 8),
                ],
                Flexible(
                  child: Text(
                    message.text,
                    textAlign: TextAlign.center,
                    style: manrope(17, weight: 600),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
