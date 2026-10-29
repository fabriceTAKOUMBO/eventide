// Screen 8 · Veille: black screen for the night. Faint text that drifts a little every
// minute (OLED), immersive mode, any touch wakes it up.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/format.dart';
import '../model_scope.dart';
import '../theme/vitre.dart';
import '../widgets/vicons.dart';

class StandbyScreen extends StatefulWidget {
  const StandbyScreen({super.key});

  @override
  State<StandbyScreen> createState() => _StandbyScreenState();
}

class _StandbyScreenState extends State<StandbyScreen> {
  Timer? _tick;
  int _minute = 0;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    // Refresh the remaining time and move the text a little every 30 s.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() => _minute++);
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _wake() async {
    if (_leaving) return;
    _leaving = true;
    final model = context.readModel;
    final navigator = Navigator.of(context);
    await model.leaveStandby();
    // pop(), not maybePop(): PopScope would call _wake again.
    if (mounted) navigator.pop();
  }

  /// Small deterministic drift (± 14 px) changing every minute.
  Offset _drift() {
    final step = _minute ~/ 2;
    final r = math.Random(step * 7919 + 17);
    return Offset(r.nextDouble() * 28 - 14, r.nextDouble() * 28 - 14);
  }

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final endsAt = model.timerEndsAt;
    final landscape = model.catalog.landscape(model.scene.landscapeId);
    final String remaining;
    if (endsAt == null) {
      remaining = model.playing ? 'Le son continue' : 'Le son est arrêté';
    } else {
      final left = endsAt.difference(DateTime.now());
      remaining = left.inSeconds <= 0
          ? 'Le son s’arrête'
          : 'Il reste ${formatDuration(left + const Duration(seconds: 59))}';
    }
    final drift = _drift();
    const dim = Color(0x80FFFFFF);
    const dimmer = Color(0x73FFFFFF);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _wake();
      },
      child: Semantics(
        button: true,
        label: 'Réveiller l’écran',
        excludeSemantics: false,
        onTap: _wake,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _wake,
          onPanDown: (_) => _wake(),
          child: Material(
            color: Colors.black,
            child: SafeArea(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Transform.translate(
                      offset: drift,
                      child: Column(
                        children: [
                          const Spacer(flex: 5),
                          const VIcon(
                            VIcons.moon,
                            size: 44,
                            color: dim,
                            strokeWidth: 1.3,
                          ),
                          const SizedBox(height: 22),
                          Text(
                            remaining,
                            textAlign: TextAlign.center,
                            style: VitreType.figure(26, weight: 200, color: dim),
                          ),
                          if (landscape != null) ...[
                            const SizedBox(height: 8),
                            Text(
                              landscape.name,
                              textAlign: TextAlign.center,
                              style: VitreType.display(size: 22, color: dimmer),
                            ),
                          ],
                          const Spacer(flex: 6),
                          Text(
                            'Touchez pour réveiller',
                            textAlign: TextAlign.center,
                            style: VitreType.small(color: dimmer),
                          ),
                          const SizedBox(height: 44),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
