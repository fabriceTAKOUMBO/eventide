// Screen 5 · Régler à la voix. Listening starts as soon as the screen opens (after the
// microphone explanation the first time). One stop button, no « Terminé ».
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/app_model.dart';
import '../landscape/landscape_image.dart';
import '../model_scope.dart';
import '../theme/vitre.dart';
import '../widgets/glass.dart';
import '../widgets/permission_dialog.dart';
import '../widgets/vicons.dart';

class VoiceScreen extends StatefulWidget {
  const VoiceScreen({super.key});

  @override
  State<VoiceScreen> createState() => _VoiceScreenState();
}

class _VoiceScreenState extends State<VoiceScreen> {
  bool _micRefused = false;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    if (!mounted) return;
    final model = context.readModel;
    final granted = await explainAndRequestPermission(context, model, PermissionKind.microphone);
    if (!mounted) return;
    if (!granted) {
      setState(() => _micRefused = true);
      return;
    }
    setState(() {
      _micRefused = false;
      _started = true;
    });
    await model.startVoice();
  }

  void _close() {
    final model = context.readModel;
    switch (model.voiceState) {
      case VoiceResult():
        // Changes are already applied; closing keeps them, like « Garder ».
        model.keepVoice();
      case VoiceListening():
      case VoiceThinking():
      case VoiceRephrase():
      case VoiceRefused():
      case VoiceError():
        model.resetVoice();
      case VoiceIdle():
        break;
    }
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final landscape = model.catalog.landscape(model.browsedLandscapeId) ?? model.catalog.defaultLandscape;
    final media = MediaQuery.of(context);
    final state = model.voiceState;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Scaffold(
        backgroundColor: VitreColors.page,
        body: Stack(
          children: [
            Positioned.fill(
              child: LandscapeImage(
                landscapeId: landscape.id,
                style: landscape.style,
                moment: model.scene.moment,
                brightness: 0.8,
              ),
            ),
            const Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x66000000), Color(0x00000000)],
                      stops: [0, 0.2],
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              top: math.max(media.padding.top + 12, math.min(240, media.size.height * 0.28)),
              child: GlassPanel(
                alpha: 0.74,
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
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 28, 20, 8),
                          child: Row(
                            children: [
                              Expanded(
                                child: Semantics(
                                  header: true,
                                  child: Text('Régler à la voix', style: manrope(26, weight: 600, letterSpacingEm: -0.015)),
                                ),
                              ),
                              RoundIconButton(icon: VIcons.close, label: 'Fermer', onPressed: _close),
                            ],
                          ),
                        ),
                        Expanded(
                          child: SingleChildScrollView(
                            padding: EdgeInsets.fromLTRB(20, 6, 20, 24 + media.padding.bottom),
                            child: Semantics(
                              liveRegion: true,
                              child: AnimatedSwitcher(
                                duration: motion(context, const Duration(milliseconds: 250)),
                                child: KeyedSubtree(
                                  key: ValueKey(_micRefused ? 'refused-mic' : state.runtimeType),
                                  child: _body(context, model, state),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    Positioned(
                      top: 10,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: Container(
                          width: 44,
                          height: 5,
                          decoration: BoxDecoration(color: VitreColors.whiteA(0.35), borderRadius: BorderRadius.circular(3)),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context, AppModel model, VoiceState state) {
    if (_micRefused) {
      return _Message(
        icon: VIcons.mic,
        title: 'Le micro n’est pas autorisé',
        message: 'Pour régler l’application en parlant, autorisez le micro. Vous pouvez aussi tout régler du bout du doigt.',
        primary: 'Autoriser le micro',
        onPrimary: _start,
        secondary: 'Fermer',
        onSecondary: _close,
      );
    }
    return switch (state) {
      VoiceListening(:final partialText, :final soundLevel) => _Listening(
          text: partialText,
          level: soundLevel,
          onStop: model.stopVoice,
        ),
      VoiceThinking() => const _Thinking(),
      VoiceResult() => _Result(
          result: state,
          onUndo: () async {
            await model.undoVoice();
            if (context.mounted) Navigator.of(context).maybePop();
          },
          onKeep: () {
            model.keepVoice();
            Navigator.of(context).maybePop();
          },
        ),
      VoiceRephrase(:final phrase, :final message) => _Message(
          icon: VIcons.question,
          title: 'Pouvez-vous reformuler ?',
          message: message,
          phrase: phrase,
          primary: 'Parler à nouveau',
          onPrimary: model.startVoice,
          secondary: 'Fermer',
          onSecondary: _close,
        ),
      VoiceRefused(:final phrase, :final message) => _Message(
          icon: VIcons.close,
          title: 'Je ne peux pas faire cela',
          message: message,
          phrase: phrase,
          primary: 'Faire une autre demande',
          onPrimary: model.startVoice,
          secondary: 'Fermer',
          onSecondary: _close,
        ),
      VoiceError(:final message, :final offline) => _Message(
          icon: offline ? VIcons.wifiOff : VIcons.refresh,
          title: offline ? 'Pas de connexion' : 'Un souci est survenu',
          message: message,
          primary: 'Réessayer',
          onPrimary: model.startVoice,
          secondary: 'Fermer',
          onSecondary: _close,
        ),
      VoiceIdle() => _Idle(onStart: _started ? model.startVoice : _start),
    };
  }
}

const List<double> _barHeights = [26, 40, 54, 62, 46, 58, 36, 50, 28];

class _Listening extends StatelessWidget {
  const _Listening({required this.text, required this.level, required this.onStop});

  final String text;
  final double level;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final p = Vitre.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: 64, child: _WaveBars(level: level)),
        const SizedBox(height: 12),
        Text(
          text.isEmpty ? 'Je vous écoute…' : '« $text »',
          textAlign: TextAlign.center,
          style: manrope(20, weight: 500, height: 1.35),
        ),
        const SizedBox(height: 20),
        Center(child: _StopButton(onStop: onStop)),
        const SizedBox(height: 10),
        Text('Touchez pour arrêter', textAlign: TextAlign.center, style: manrope(17, color: p.text(0.78))),
        const SizedBox(height: 22),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Vous pouvez aussi dire', style: manrope(16, weight: 700, color: p.text(0.7))),
              const SizedBox(height: 6),
              for (final s in const ['« Change de paysage »', '« Ajoute du piano doux »', '« Active le suivi du sommeil »'])
                Text(s, style: manrope(17, height: 1.5, color: p.text(0.84))),
            ],
          ),
        ),
      ],
    );
  }
}

/// Nine bars driven by the microphone level; static with reduced motion.
class _WaveBars extends StatefulWidget {
  const _WaveBars({required this.level});

  final double level;

  @override
  State<_WaveBars> createState() => _WaveBarsState();
}

class _WaveBarsState extends State<_WaveBars> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (Vitre.reduceMotion(context)) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final still = Vitre.reduceMotion(context);
    return ExcludeSemantics(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final level = widget.level.clamp(0.0, 1.0);
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              for (var i = 0; i < _barHeights.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Container(
                  width: 8,
                  height: _barHeights[i] *
                      (still
                          ? 0.6
                          : (0.3 + 0.7 * (0.35 + 0.65 * level) * (0.5 + 0.5 * math.sin((_c.value + i * 0.12) * math.pi)))),
                  decoration: BoxDecoration(color: VitreColors.white, borderRadius: BorderRadius.circular(4)),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _StopButton extends StatefulWidget {
  const _StopButton({required this.onStop});

  final VoidCallback onStop;

  @override
  State<_StopButton> createState() => _StopButtonState();
}

class _StopButtonState extends State<_StopButton> with SingleTickerProviderStateMixin {
  late final AnimationController _ring = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (Vitre.reduceMotion(context)) {
      _ring.stop();
    } else if (!_ring.isAnimating) {
      _ring.repeat();
    }
  }

  @override
  void dispose() {
    _ring.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final still = Vitre.reduceMotion(context);
    return SizedBox(
      width: 84,
      height: 84,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          AnimatedBuilder(
            animation: _ring,
            builder: (context, _) {
              final t = still ? 0.0 : Curves.easeOut.transform(_ring.value);
              return Transform.scale(
                scale: 1 + 0.6 * t,
                child: Opacity(
                  opacity: still ? 0.35 : 0.55 * (1 - t),
                  child: Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: VitreColors.whiteA(0.8), width: 2),
                    ),
                  ),
                ),
              );
            },
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: Color(0x59000000), blurRadius: 24, offset: Offset(0, 8))],
              ),
              child: Material(
                color: VitreColors.white,
                shape: const CircleBorder(),
                child: Semantics(
                  button: true,
                  label: 'Arrêter l’enregistrement',
                  excludeSemantics: true,
                  onTap: widget.onStop,
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: widget.onStop,
                    child: Center(
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(color: VitreColors.ink, borderRadius: BorderRadius.circular(7)),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Thinking extends StatefulWidget {
  const _Thinking();

  @override
  State<_Thinking> createState() => _ThinkingState();
}

class _ThinkingState extends State<_Thinking> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (Vitre.reduceMotion(context)) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final still = Vitre.reduceMotion(context);
    return Padding(
      padding: const EdgeInsets.only(top: 60),
      child: Column(
        children: [
          Text('Je prépare vos réglages', textAlign: TextAlign.center, style: manrope(24, weight: 500)),
          const SizedBox(height: 22),
          ExcludeSemantics(
            child: AnimatedBuilder(
              animation: _c,
              builder: (context, _) => Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < 3; i++) ...[
                    if (i > 0) const SizedBox(width: 10),
                    Opacity(
                      opacity: still ? 0.7 : 0.25 + 0.75 * (0.5 - 0.5 * math.cos(((_c.value - i * 0.17) % 1) * 2 * math.pi)),
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: const BoxDecoration(color: VitreColors.white, shape: BoxShape.circle),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Result extends StatelessWidget {
  const _Result({required this.result, required this.onUndo, required this.onKeep});

  final VoiceResult result;
  final VoidCallback onUndo;
  final VoidCallback onKeep;

  @override
  Widget build(BuildContext context) {
    final p = Vitre.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: const BoxDecoration(color: VitreColors.white, shape: BoxShape.circle),
              alignment: Alignment.center,
              child: const VIcon(VIcons.check, size: 24, color: VitreColors.ink, strokeWidth: 3),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text('C’est fait', style: manrope(26, weight: 600))),
          ],
        ),
        const SizedBox(height: 14),
        Text('« ${result.phrase} »', style: manrope(18, height: 1.35, color: p.text(0.76))),
        const SizedBox(height: 16),
        GlassCard(
          radius: 24,
          fillAlpha: 0.09,
          borderAlpha: 0.16,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (result.changes.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text('Rien n’a changé.', style: manrope(17, color: p.text(0.76))),
                ),
              for (var i = 0; i < result.changes.length; i++)
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    border: i == 0 ? null : Border(top: BorderSide(color: p.border(0.14))),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(result.changes[i].label, style: manrope(19, weight: 700)),
                      const SizedBox(height: 2),
                      Text(result.changes[i].value, style: manrope(17, color: p.text(0.76))),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: SecondaryButton(label: 'Annuler', height: 64, fontSize: 19, onPressed: onUndo),
            ),
            const SizedBox(width: 12),
            Expanded(child: PrimaryButton(label: 'Garder', fontSize: 19, onPressed: onKeep)),
          ],
        ),
        if (result.quotaLabel != null) ...[
          const SizedBox(height: 16),
          Text(result.quotaLabel!, textAlign: TextAlign.center, style: manrope(16, color: p.text(0.72))),
        ],
      ],
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.message,
    required this.primary,
    required this.onPrimary,
    required this.secondary,
    required this.onSecondary,
    this.phrase,
  });

  final VIconData icon;
  final String title;
  final String message;
  final String? phrase;
  final String primary;
  final VoidCallback onPrimary;
  final String secondary;
  final VoidCallback onSecondary;

  @override
  Widget build(BuildContext context) {
    final p = Vitre.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: p.fill(0.12),
                shape: BoxShape.circle,
                border: Border.all(color: p.border(0.24)),
              ),
              alignment: Alignment.center,
              child: VIcon(icon, size: 24, color: VitreColors.white),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(title, style: manrope(24, weight: 600, height: 1.2))),
          ],
        ),
        if (phrase != null && phrase!.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text('« $phrase »', style: manrope(18, height: 1.35, color: p.text(0.76))),
        ],
        const SizedBox(height: 14),
        Text(message, style: manrope(19, height: 1.4, color: p.text(0.9))),
        const SizedBox(height: 24),
        PrimaryButton(label: primary, onPressed: onPrimary),
        const SizedBox(height: 10),
        SecondaryButton(label: secondary, onPressed: onSecondary),
      ],
    );
  }
}

class _Idle extends StatelessWidget {
  const _Idle({required this.onStart});

  final Future<void> Function() onStart;

  @override
  Widget build(BuildContext context) {
    final p = Vitre.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 40),
      child: Column(
        children: [
          Semantics(
            button: true,
            label: 'Parler',
            excludeSemantics: true,
            onTap: onStart,
            child: Material(
              color: VitreColors.white,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onStart,
                child: const SizedBox(
                  width: 84,
                  height: 84,
                  child: Center(child: VIcon(VIcons.mic, size: 36, color: VitreColors.ink)),
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text('Touchez le micro pour parler', textAlign: TextAlign.center, style: manrope(18, color: p.text(0.84))),
        ],
      ),
    );
  }
}
