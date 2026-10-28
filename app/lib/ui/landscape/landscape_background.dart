// Full-screen landscape (home, welcome, offline): a living landscape, never a player.
//
// Priority chain: looping video (when the landscape has one, the plan allows it and it can be
// played now) → poster or photo (the loop's frame 0, pixel-identical to the video's first
// frame) → procedural painter. The same moment-of-day colour filter, blur and cover fit apply
// to all three; decor and glass panels are drawn above by the screens, as before.
//
// The video plays when, and only when: its landscape is on screen (route not covered:
// TickerMode), the app is in the foreground (AppLifecycleState.resumed) and animations are
// allowed (MediaQuery.disableAnimations false). Otherwise the still picture is shown: standby
// (black screen) covers this widget, reduced motion shows the poster, and in background
// nothing plays (the player is released; on return the poster, i.e. frame 0, shows until the
// video starts again from frame 0, so nothing jumps).
//
// Never tied to the sound: this widget never reads AppModel.playing. Play/pause, the media
// notification, voice, audio focus and the timer only change the sound.
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../app/app_model.dart';
import '../../core/landscape_media.dart';
import '../../core/scene.dart' show Moment;
import '../model_scope.dart';
import '../theme/vitre.dart';
import 'landscape_image.dart';
import 'landscape_painter.dart';
import 'landscape_video.dart';

class LandscapeBackground extends StatefulWidget {
  const LandscapeBackground({
    super.key,
    required this.landscapeId,
    required this.style,
    this.moment = Moment.jour,
    this.kenBurns = false,
    this.blurSigma = 0,
    this.brightness = 1,
    this.saturation = 1,
    this.releaseWhenCovered = const Duration(seconds: 20),
  });

  final String landscapeId;
  final String style;
  final Moment moment;

  /// Slow zoom and drift for still pictures only (never with a video: the poster must stay
  /// exactly where the video will appear).
  final bool kenBurns;
  final double blurSigma;
  final double brightness;
  final double saturation;

  /// A covered landscape (another screen on top, standby) keeps its paused frame this long,
  /// so that coming back shows exactly the same picture, then releases its player.
  final Duration releaseWhenCovered;

  @override
  State<LandscapeBackground> createState() => _LandscapeBackgroundState();
}

class _LandscapeBackgroundState extends State<LandscapeBackground>
    with WidgetsBindingObserver {
  late final LandscapeVideoHub _hub;
  AppModel? _model;
  AppLifecycleState _lifecycle = AppLifecycleState.resumed;
  bool _visible = true;
  bool _reduced = false;
  bool _allowed = false;

  /// Answer of AppModel.landscapeVideo for [_requested].
  LandscapeVideoSource? _source;
  String? _requested;
  int _ticket = 0;
  LandscapeVideoSource? _failed;
  LandscapeVideoLease? _lease;
  Timer? _coveredTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lifecycle =
        WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
    _hub = LandscapeVideos.hub..addListener(_onHub);
    LandscapeImages.revision.addListener(_onAssets);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = TickerMode.valuesOf(context).enabled;
    _reduced = Vitre.reduceMotion(context);
    _model = context.dependOnInheritedWidgetOfExactType<ModelScope>()?.notifier;
    _update();
  }

  @override
  void didUpdateWidget(LandscapeBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.landscapeId != widget.landscapeId) {
      _drop();
      _source = null;
      _requested = null;
      _failed = null;
    }
    _update();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == _lifecycle) return;
    _lifecycle = state;
    if (state == AppLifecycleState.resumed && _source == null) {
      // A download refused earlier (offline, mobile data) may be possible now.
      _requested = null;
      _update();
    } else {
      _sync();
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hub.removeListener(_onHub);
    LandscapeImages.revision.removeListener(_onAssets);
    _drop(now: true);
    super.dispose();
  }

  void _onAssets() {
    if (!mounted) return;
    setState(_update);
  }

  /// A player slot was freed: take it if we are waiting for one.
  void _onHub() {
    if (!mounted || _lease != null || _source == null) return;
    _sync();
    if (_lease != null) setState(() {});
  }

  void _onStatus() {
    if (!mounted) return;
    final lease = _lease;
    if (lease != null &&
        lease.player.status.value == LandscapeVideoStatus.failed) {
      // Not from inside the player's own notification: releasing may dispose it.
      scheduleMicrotask(() {
        if (!mounted || !identical(_lease, lease)) return;
        _failed = _source;
        _drop();
        setState(() {});
      });
      return;
    }
    setState(() {});
  }

  /// The landscape has a video the user may watch (decided synchronously: a still picture of
  /// such a landscape never moves, so that the video replaces it without a jump).
  bool get _videoLandscape =>
      _allowed && LandscapeImages.hasVideo(widget.landscapeId);

  bool get _wantVideo => _videoLandscape && !_reduced;

  void _update() {
    final model = _model;
    final landscape = model?.catalog.landscape(widget.landscapeId);
    _allowed =
        model != null &&
        landscape != null &&
        model.rules.canUseLandscape(model.plan, landscape);
    if (!_wantVideo) {
      _drop();
      _source = null;
      _requested = null;
      return;
    }
    final key = '${widget.landscapeId}|${model!.plan.name}';
    if (key != _requested) {
      _requested = key;
      _resolve(model, widget.landscapeId);
    }
    _sync();
  }

  void _resolve(AppModel model, String id) {
    final ticket = ++_ticket;
    model.landscapeVideo(id).then(
      (source) {
        if (!mounted || ticket != _ticket || id != widget.landscapeId) return;
        if (source != _source) {
          _drop();
          _source = source;
        }
        _sync();
        setState(() {});
      },
      onError: (Object e) {
        debugPrint('LandscapeBackground: no video for $id ($e)');
      },
    );
  }

  /// Acquires, plays, pauses or releases the player to match the conditions.
  void _sync() {
    final source = _source;
    final gone =
        _lifecycle == AppLifecycleState.hidden ||
        _lifecycle == AppLifecycleState.paused ||
        _lifecycle == AppLifecycleState.detached;
    if (source == null || source == _failed || !_wantVideo || gone) {
      _drop(now: gone);
      return;
    }
    if (!_visible || _lifecycle == AppLifecycleState.inactive) {
      // Paused on its current frame; released if the landscape stays covered.
      _lease?.playing = false;
      if (!_visible && _lease != null) {
        _coveredTimer ??= Timer(widget.releaseWhenCovered, () {
          _drop(now: true);
          if (mounted) setState(() {});
        });
      }
      return;
    }
    _coveredTimer?.cancel();
    _coveredTimer = null;
    var lease = _lease;
    if (lease == null) {
      lease = _hub.acquire(source);
      if (lease == null) return; // no free player now: retried by _onHub
      _lease = lease;
      lease.player.status.addListener(_onStatus);
    }
    lease.playing = true;
  }

  /// Lets go of the player. On screen, only after the next frame, once its picture has left
  /// the tree (never a frame drawn from a released texture); in background or covered, now
  /// (no frame may come before the app is back).
  void _drop({bool now = false}) {
    _coveredTimer?.cancel();
    _coveredTimer = null;
    final lease = _lease;
    if (lease == null) return;
    _lease = null;
    lease.player.status.removeListener(_onStatus);
    if (now) {
      lease.release();
      return;
    }
    WidgetsBinding.instance
      ..addPostFrameCallback((_) => lease.release())
      ..ensureVisualUpdate();
  }

  @override
  Widget build(BuildContext context) {
    final provider = LandscapeImages.providerFor(widget.landscapeId);
    final focus = Alignment(0, landscapeFocusY(widget.style) * 2 - 1);
    final Widget still = provider != null
        ? Image(
            image: provider,
            fit: BoxFit.cover,
            alignment: focus,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
            errorBuilder: (context, error, stack) =>
                ProceduralLandscape(style: widget.style),
          )
        : ProceduralLandscape(style: widget.style);
    Widget picture = still;
    final lease = _lease;
    if (lease != null) {
      final player = lease.player;
      final showing = player.status.value == LandscapeVideoStatus.showing;
      final size = player.size;
      picture = Stack(
        fit: StackFit.expand,
        children: [
          still,
          // The poster is the loop's frame 0: the fade only hides the few frames played
          // while the texture warmed up. From the procedural painter it is a real dissolve.
          AnimatedOpacity(
            opacity: showing ? 1 : 0,
            duration: Duration(milliseconds: provider != null ? 240 : 700),
            curve: Curves.easeOut,
            child: size.isEmpty
                ? const SizedBox.shrink()
                : ClipRect(
                    child: FittedBox(
                      fit: BoxFit.cover,
                      alignment: focus,
                      child: SizedBox(
                        key: const ValueKey('landscape-video'),
                        width: size.width,
                        height: size.height,
                        child: player.view(),
                      ),
                    ),
                  ),
          ),
        ],
      );
    }
    if (widget.moment != Moment.jour ||
        widget.brightness != 1 ||
        widget.saturation != 1) {
      picture = ColorFiltered(
        colorFilter: ColorFilter.matrix(
          landscapeMatrix(
            moment: widget.moment,
            brightness: widget.brightness,
            saturation: widget.saturation,
          ),
        ),
        child: picture,
      );
    }
    if (widget.kenBurns && _reduced) {
      picture = Transform.scale(
        scale: 1.04,
        alignment: const Alignment(0, -0.2),
        child: picture,
      );
    } else if (widget.kenBurns && !_videoLandscape) {
      picture = KenBurns(child: picture);
    }
    if (widget.blurSigma > 0) {
      picture = ImageFiltered(
        imageFilter: ui.ImageFilter.blur(
          sigmaX: widget.blurSigma,
          sigmaY: widget.blurSigma,
          tileMode: TileMode.clamp,
        ),
        child: picture,
      );
    }
    return ClipRect(child: SizedBox.expand(child: picture));
  }
}
