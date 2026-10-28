// Screen 2 · Accueil. Vertical swipe on the landscape = next/previous landscape of
// the theme (no wrap), horizontal swipe = theme, vertical swipe on the menu =
// collapse/expand. Thresholds: 50 px and a clearly dominant axis (1.3×). The photo
// follows the finger during the gesture; arrows and theme buttons double the swipes.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/app_model.dart';
import '../../../core/catalog.dart';
import '../../../core/format.dart';
import '../../../core/scene.dart';
import '../../landscape/decor_layer.dart';
import '../../landscape/landscape_image.dart';
import '../../model_scope.dart';
import '../../navigation.dart';
import '../../theme/vitre.dart';
import '../../widgets/vicons.dart';
import 'home_controls.dart';
import 'home_menu.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  /// The swipe hint is shown once per app session (the model offers no storage
  /// for UI hints).
  static bool hintShownThisSession = false;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  bool _expanded = true;
  bool _timerMenu = false;
  bool _hint = false;
  Timer? _hintTimer;

  // Slow network detection while sounds load.
  AppModel? _model;
  bool _slow = false;
  Timer? _slowTimer;

  // Gesture.
  int? _pointer;
  Offset _start = Offset.zero;
  Axis? _axis;
  bool _onMenu = false;
  final GlobalKey _menuKey = GlobalKey();

  // Strip.
  late final AnimationController _settle = AnimationController(vsync: this);
  Animation<Offset>? _settleAnimation;
  Offset _offset = Offset.zero;
  String? _incomingId;
  String? _shownId;
  Timer? _shownTimer;
  Size _size = Size.zero;

  @override
  void initState() {
    super.initState();
    _settle.addListener(() {
      final a = _settleAnimation;
      if (a != null) setState(() => _offset = a.value);
    });
    if (!HomeScreen.hintShownThisSession) {
      HomeScreen.hintShownThisSession = true;
      _hint = true;
      _hintTimer = Timer(const Duration(seconds: 6), _hideHint);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final model = context.readModel;
    if (model != _model) {
      _model?.removeListener(_onModel);
      _model = model..addListener(_onModel);
      _onModel();
    }
  }

  void _onModel() {
    final loading = _model?.loadingAudio ?? false;
    if (loading && _slowTimer == null && !_slow) {
      _slowTimer = Timer(const Duration(seconds: 8), () {
        if (mounted) setState(() => _slow = true);
      });
    } else if (!loading) {
      _slowTimer?.cancel();
      _slowTimer = null;
      if (_slow) setState(() => _slow = false);
    }
  }

  @override
  void dispose() {
    _model?.removeListener(_onModel);
    _hintTimer?.cancel();
    _slowTimer?.cancel();
    _shownTimer?.cancel();
    _settle.dispose();
    super.dispose();
  }

  void _hideHint() {
    _hintTimer?.cancel();
    if (_hint && mounted) setState(() => _hint = false);
  }

  // ---- Catalog helpers

  String _currentId(AppModel model) {
    final shown = _shownId;
    if (shown != null && shown == model.browsedLandscapeId) _shownId = null;
    return _shownId ?? model.browsedLandscapeId;
  }

  Landscape _landscape(AppModel model, String id) =>
      model.catalog.landscape(id) ?? model.catalog.defaultLandscape;

  ({String? previous, String? next}) _vertical(AppModel model, String id) {
    final l = _landscape(model, id);
    final list = model.catalog.landscapesOfTheme(l.themeId);
    final i = list.indexWhere((x) => x.id == l.id);
    return (
      previous: i > 0 ? list[i - 1].id : null,
      next: i >= 0 && i < list.length - 1 ? list[i + 1].id : null,
    );
  }

  ({String? left, String? right}) _horizontal(AppModel model, String id) {
    final l = _landscape(model, id);
    final themes = model.catalog.themes;
    final t = themes.indexWhere((x) => x.id == l.themeId);
    return (
      left: t > 0 ? model.lastLandscapeOfTheme(themes[t - 1].id) : null,
      right: t >= 0 && t < themes.length - 1
          ? model.lastLandscapeOfTheme(themes[t + 1].id)
          : null,
    );
  }

  // ---- Gestures

  Rect? _menuRect() {
    final box = _menuKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  void _onDown(PointerDownEvent e) {
    if (_pointer != null || _timerMenu || _settle.isAnimating) return;
    _pointer = e.pointer;
    _start = e.position;
    _axis = null;
    _onMenu = _menuRect()?.contains(e.position) ?? false;
  }

  void _onMove(PointerMoveEvent e) {
    if (e.pointer != _pointer) return;
    final d = e.position - _start;
    if (_axis == null && d.distance > 14) {
      _axis = d.dx.abs() > d.dy.abs() ? Axis.horizontal : Axis.vertical;
      _hideHint();
    }
    if (_axis == null || (_onMenu && _axis == Axis.vertical)) return;
    final model = context.readModel;
    final id = _currentId(model);
    if (_axis == Axis.horizontal) {
      final n = _horizontal(model, id);
      final incoming = d.dx < 0 ? n.right : n.left;
      setState(() {
        _incomingId = incoming;
        _offset = Offset(incoming == null ? d.dx * 0.3 : d.dx, 0);
      });
    } else {
      final n = _vertical(model, id);
      final incoming = d.dy < 0 ? n.next : n.previous;
      setState(() {
        _incomingId = incoming;
        _offset = Offset(0, incoming == null ? d.dy * 0.3 : d.dy);
      });
    }
  }

  void _onUp(PointerEvent e) {
    if (e.pointer != _pointer) return;
    _pointer = null;
    final d = e.position - _start;
    final ax = d.dx.abs(), ay = d.dy.abs();
    final model = context.readModel;
    final id = _currentId(model);
    if (e is PointerUpEvent) {
      if (_onMenu && ay >= 50 && ay > ax * 1.3) {
        setState(() {
          _expanded = d.dy < 0;
          _timerMenu = false;
        });
        _settleTo(Offset.zero);
        return;
      }
      if (ax >= 50 && ax > ay * 1.3) {
        final n = _horizontal(model, id);
        final target = d.dx < 0 ? n.right : n.left;
        if (target != null) {
          _commit(target, Offset(d.dx < 0 ? -_size.width : _size.width, 0));
          return;
        }
      } else if (!_onMenu && ay >= 50 && ay > ax * 1.3) {
        final n = _vertical(model, id);
        final target = d.dy < 0 ? n.next : n.previous;
        if (target != null) {
          _commit(target, Offset(0, d.dy < 0 ? -_size.height : _size.height));
          return;
        }
      }
    }
    _settleTo(Offset.zero);
  }

  void _settleTo(Offset target, {VoidCallback? then}) {
    if (_offset == target) {
      then?.call();
      return;
    }
    if (Vitre.reduceMotion(context)) {
      setState(() => _offset = target);
      then?.call();
      return;
    }
    _settleAnimation = Tween(begin: _offset, end: target).animate(
      CurvedAnimation(parent: _settle, curve: const Cubic(0.22, 0.8, 0.24, 1)),
    );
    _settle
      ..duration = const Duration(milliseconds: 420)
      ..forward(from: 0).whenComplete(() => then?.call());
  }

  /// Slides [targetId] in from the side opposite to [exit] and makes it current.
  void _commit(String targetId, Offset exit) {
    _hideHint();
    setState(() {
      _incomingId = targetId;
      if (_offset == Offset.zero) {
        // Started from a button: nudge so the incoming picture is placed correctly.
        _offset = Offset(exit.dx.sign * 0.01, exit.dy.sign * 0.01);
      }
    });
    _settleTo(
      exit,
      then: () {
        if (!mounted) return;
        context.readModel.browseLandscape(targetId);
        setState(() {
          _shownId = targetId;
          _incomingId = null;
          _offset = Offset.zero;
        });
        _shownTimer?.cancel();
        _shownTimer = Timer(const Duration(milliseconds: 800), () {
          if (mounted) setState(() => _shownId = null);
        });
      },
    );
  }

  void _goVertical(bool next) {
    final model = context.readModel;
    final n = _vertical(model, _currentId(model));
    final target = next ? n.next : n.previous;
    if (target == null || _settle.isAnimating) return;
    _commit(target, Offset(0, next ? -_size.height : _size.height));
  }

  void _goTheme(int index) {
    final model = context.readModel;
    final current = _landscape(model, _currentId(model));
    final themes = model.catalog.themes;
    final from = themes.indexWhere((t) => t.id == current.themeId);
    if (index == from ||
        index < 0 ||
        index >= themes.length ||
        _settle.isAnimating) {
      return;
    }
    final target = model.lastLandscapeOfTheme(themes[index].id);
    _commit(target, Offset(index > from ? -_size.width : _size.width, 0));
  }

  // ---- Build

  Widget _picture(
    AppModel model,
    String id,
    Offset offset, {
    required bool current,
  }) {
    final l = _landscape(model, id);
    return Positioned.fill(
      key: ValueKey('picture-$id'),
      child: Transform.translate(
        offset: offset,
        child: LandscapeImage(
          landscapeId: l.id,
          style: l.style,
          moment: model.scene.moment,
          kenBurns: true,
        ),
      ),
    );
  }

  Offset _incomingOffset() {
    if (_offset.dx != 0) {
      return _offset + Offset(_offset.dx < 0 ? _size.width : -_size.width, 0);
    }
    return _offset + Offset(0, _offset.dy < 0 ? _size.height : -_size.height);
  }

  String _soundsLine(AppModel model, Landscape shown) {
    final catalog = model.catalog;
    final names = <String>[];
    final fromScene = shown.id == model.scene.landscapeId;
    for (final kind in const [LayerKind.son, LayerKind.musique]) {
      final layers = fromScene
          ? model.scene.layers(kind)
          : (shown.defaultMix[kind] ?? const <Layer>[]);
      for (final layer in layers) {
        final name = catalog.item(kind, layer.id)?.name;
        if (name != null) names.add(name);
      }
    }
    if (names.isEmpty) return 'Aucun son pour l’instant';
    return names.take(3).join(' · ');
  }

  HomeMenuData _menuData(AppModel model, Landscape shown) {
    final next = model.nextScheduledStart;
    String top = 'Démarrage',
        main = 'Programmer',
        label = 'Programmer le démarrage automatique du son';
    if (next != null) {
      final text = nextStartLabel(next, DateTime.now());
      final parts = text.split(' · ');
      top = parts.first;
      main = parts.length > 1 ? parts.sublist(1).join(' · ') : '';
      label =
          'Prochain démarrage du son : $text. Toucher pour voir les programmations';
    }
    final locked = !model.rules.canUseLandscape(model.plan, shown);
    final loading = model.loadingAudio && !locked;
    return HomeMenuData(
      landscapeId: shown.id,
      style: shown.style,
      name: shown.name,
      subtitle: loading
          ? (_slow ? 'Réseau lent, encore un instant…' : 'Chargement des sons…')
          : _soundsLine(model, shown),
      locked: locked,
      playing: model.playing,
      loading: loading,
      scheduleTop: top,
      scheduleMain: main,
      scheduleLabel: label,
    );
  }

  void _openSchedule() {
    final model = context.readModel;
    if (model.schedules.isEmpty) {
      Nav.scheduleEditor(context);
    } else {
      Nav.schedules(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final media = MediaQuery.of(context);
    final id = _currentId(model);
    final shown = _landscape(model, id);
    final themes = model.catalog.themes;
    final themeIndex = themes.indexWhere((t) => t.id == shown.themeId);
    final ofTheme = model.catalog.landscapesOfTheme(shown.themeId);
    final index = ofTheme.indexWhere((l) => l.id == shown.id);
    final vertical = _vertical(model, id);
    final dragging = _offset != Offset.zero;
    final decor = shown.id == model.scene.landscapeId && !dragging
        ? [for (final l in model.scene.decor) DecorEffect(l.id, l.level)]
        : const <DecorEffect>[];
    final topVisible = _expanded;
    final fade = motion(context, const Duration(milliseconds: 300));
    _prewarmNeighbors(model, id, media.devicePixelRatio);

    return PopScope(
      canPop: !_timerMenu,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _timerMenu = false);
      },
      child: Scaffold(
        backgroundColor: VitreColors.page,
        body: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _onDown,
          onPointerMove: _onMove,
          onPointerUp: _onUp,
          onPointerCancel: _onUp,
          child: LayoutBuilder(
            builder: (context, constraints) {
              _size = constraints.biggest;
              return Stack(
                children: [
                  // Landscapes: the current one and, during a gesture, the incoming one.
                  _picture(model, shown.id, _offset, current: true),
                  if (_incomingId != null && dragging)
                    _picture(
                      model,
                      _incomingId!,
                      _incomingOffset(),
                      current: false,
                    ),
                  Positioned.fill(
                    child: DecorLayer(effects: decor, active: !dragging),
                  ),
                  const Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Color(0x6B000000),
                              Color(0x00000000),
                              Color(0x00000000),
                              Color(0x66000000),
                            ],
                            stops: [0, 0.18, 0.58, 1],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: Padding(
                      padding: EdgeInsets.only(top: media.padding.top),
                      child: Column(
                        children: [
                          AnimatedOpacity(
                            opacity: topVisible ? 1 : 0,
                            duration: fade,
                            child: IgnorePointer(
                              ignoring: !topVisible,
                              child: ExcludeSemantics(
                                excluding: !topVisible,
                                child: HomeTopBar(
                                  timer: model.scene.timer,
                                  timerMenuOpen: _timerMenu,
                                  onSleep: () => Nav.sleep(context),
                                  onSettings: () => Nav.settings(context),
                                  onTimer: () =>
                                      setState(() => _timerMenu = !_timerMenu),
                                  themes: [for (final t in themes) t.name],
                                  themeIndex: themeIndex < 0 ? 0 : themeIndex,
                                  onTheme: _goTheme,
                                ),
                              ),
                            ),
                          ),
                          Expanded(
                            child: Align(
                              alignment: Alignment.topRight,
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  0,
                                  30,
                                  10,
                                  12,
                                ),
                                child: HomeRightEdge(
                                  favorite: model.isCurrentSceneFavorite,
                                  onFavorite: model.toggleFavorite,
                                  onPrevious: vertical.previous == null
                                      ? null
                                      : () => _goVertical(false),
                                  onNext: vertical.next == null
                                      ? null
                                      : () => _goVertical(true),
                                  dots: [
                                    for (final l in ofTheme)
                                      model.rules.canUseLandscape(
                                        model.plan,
                                        l,
                                      ),
                                  ],
                                  current: index < 0 ? 0 : index,
                                  pagerLabel:
                                      '${themeIndex < 0 ? '' : themes[themeIndex].name}, paysage ${index + 1} sur ${ofTheme.length}'
                                      '${model.rules.canUseLandscape(model.plan, shown) ? '' : ', réservé à Premium'}',
                                ),
                              ),
                            ),
                          ),
                          Padding(
                            padding: EdgeInsets.fromLTRB(
                              14,
                              0,
                              14,
                              18 + media.padding.bottom,
                            ),
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                maxHeight: constraints.maxHeight * 0.62,
                              ),
                              child: SingleChildScrollView(
                                physics: const ClampingScrollPhysics(),
                                reverse: true,
                                child: HomeMenu(
                                  key: _menuKey,
                                  data: _menuData(model, shown),
                                  expanded: _expanded,
                                  onToggleExpanded: () => setState(() {
                                    _expanded = !_expanded;
                                    _timerMenu = false;
                                  }),
                                  onPlay: model.togglePlay,
                                  onUnlock: () => Nav.premium(context),
                                  onLandscapes: () => Nav.landscapes(context),
                                  onMix: () => Nav.mix(context),
                                  onVoice: () => Nav.voice(context),
                                  onSchedule: _openSchedule,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_hint)
                    Positioned(
                      left: 40,
                      right: 40,
                      top: constraints.maxHeight * 0.36,
                      child: IgnorePointer(child: Center(child: _SwipeHint())),
                    ),
                  if (_timerMenu) ...[
                    Positioned.fill(
                      child: Semantics(
                        label: 'Fermer le choix du minuteur',
                        button: true,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => setState(() => _timerMenu = false),
                        ),
                      ),
                    ),
                    Positioned(
                      top: media.padding.top + 64,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: (220 * media.textScaler.scale(1)).clamp(
                              220,
                              constraints.maxWidth - 40,
                            ),
                            minWidth: 220,
                            maxHeight:
                                constraints.maxHeight - media.padding.top - 80,
                          ),
                          child: TimerMenu(
                            current: model.scene.timer,
                            onPick: (t) {
                              model.setTimer(t);
                              setState(() => _timerMenu = false);
                            },
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  String? _prewarmedFor;

  /// Rasterises the neighbouring landscapes after the frame, so that a swipe never
  /// waits for the first paint of the incoming picture.
  void _prewarmNeighbors(AppModel model, String id, double dpr) {
    if (_prewarmedFor == id || _size.isEmpty) return;
    _prewarmedFor = id;
    final v = _vertical(model, id);
    final h = _horizontal(model, id);
    final ids = {v.previous, v.next, h.left, h.right}.whereType<String>();
    final size = _size;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final other in ids) {
        final l = model.catalog.landscape(other);
        if (l == null || LandscapeImages.providerFor(other) != null) continue;
        LandscapeRasterCache.obtain(l.style, size, dpr.clamp(1.0, 1.75));
      }
    });
  }
}

class _SwipeHint extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final p = Vitre.of(context);
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color: p.glass(0.62),
          borderRadius: BorderRadius.circular(26),
          border: Border.all(color: p.border(0.2)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const VIcon(VIcons.swipe, size: 24, color: VitreColors.white),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                'Balayez pour changer de paysage',
                textAlign: TextAlign.center,
                style: manrope(17, weight: 600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
