// Screen 3 · Paysages: tabs Nature / Urbain / Astral / Favoris, 2-column grid.
// Also used to pick the landscape of a schedule ([pickFor] set): it then returns the id.
import 'package:flutter/material.dart';

import '../../app/app_model.dart';
import '../../core/catalog.dart';
import '../model_scope.dart';
import '../navigation.dart';
import '../theme/vitre.dart';
import '../widgets/glass.dart';
import '../widgets/sheet_scaffold.dart';
import '../widgets/vicons.dart';
import 'home/home_menu.dart' show LandscapeThumbnail;

class LandscapesSheet extends StatefulWidget {
  const LandscapesSheet({super.key, this.pickFor});

  /// Selected landscape of the schedule being edited (picker mode).
  final String? pickFor;

  @override
  State<LandscapesSheet> createState() => _LandscapesSheetState();
}

class _LandscapesSheetState extends State<LandscapesSheet> {
  int? _tab;

  bool get _picker => widget.pickFor != null;

  @override
  Widget build(BuildContext context) {
    final model = context.model;
    final catalog = model.catalog;
    final selectedId = widget.pickFor ?? model.scene.landscapeId;
    final themes = catalog.themes;
    final selectedLandscape = catalog.landscape(selectedId);
    final initialTab = selectedLandscape == null ? 0 : themes.indexWhere((t) => t.id == selectedLandscape.themeId);
    final tab = _tab ?? (initialTab < 0 ? 0 : initialTab);
    final labels = [for (final t in themes) t.name, if (!_picker) 'Favoris'];
    final favoritesTab = !_picker && tab == themes.length;
    final premium = model.plan.isPremium;

    return VitreSheet(
      title: _picker ? 'Ambiance' : 'Paysages',
      top: 96,
      panelAlpha: 0.7,
      backgroundBrightness: 0.6,
      contentPadding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TextTabs(labels: labels, selected: tab, onSelected: (i) => setState(() => _tab = i)),
          const SizedBox(height: 14),
          if (favoritesTab)
            _FavoritesList(model: model)
          else ...[
            _Grid(
              landscapes: catalog.landscapesOfTheme(themes[tab].id),
              selectedId: selectedId,
              canUse: (l) => model.rules.canUseLandscape(model.plan, l),
              onTap: (l) {
                final usable = model.rules.canUseLandscape(model.plan, l);
                if (!usable) {
                  Nav.premium(context);
                } else if (_picker) {
                  Navigator.of(context).pop(l.id);
                } else {
                  model.selectLandscape(l.id);
                  Navigator.of(context).maybePop();
                }
              },
            ),
            if (!premium) ...[
              const SizedBox(height: 18),
              SecondaryButton(
                label: 'Débloquer tous les paysages',
                height: 56,
                fontSize: 18,
                weight: 600,
                borderAlpha: 0.25,
                onPressed: () => Nav.premium(context),
              ),
              const SizedBox(height: 12),
              Text(
                'Version gratuite : ${catalog.landscapes.where((l) => l.free).length} paysages',
                textAlign: TextAlign.center,
                style: manrope(16, color: Vitre.of(context).text(0.72)),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// Text tabs with a dot under the selected one (mockup), scrollable when large.
class _TextTabs extends StatelessWidget {
  const _TextTabs({required this.labels, required this.selected, required this.onSelected});

  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final p = Vitre.of(context);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++)
            Padding(
              padding: EdgeInsets.only(right: i == labels.length - 1 ? 0 : 6),
              child: Semantics(
                selected: i == selected,
                button: true,
                label: labels[i],
                excludeSemantics: true,
                onTap: () => onSelected(i),
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => onSelected(i),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            labels[i],
                            style: manrope(18, weight: 600, color: i == selected ? VitreColors.white : p.text(0.7)),
                          ),
                          const SizedBox(height: 6),
                          Container(
                            width: 5,
                            height: 5,
                            decoration: BoxDecoration(
                              color: i == selected ? VitreColors.white : Colors.transparent,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ],
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

class _Grid extends StatelessWidget {
  const _Grid({required this.landscapes, required this.selectedId, required this.canUse, required this.onTap});

  final List<Landscape> landscapes;
  final String selectedId;
  final bool Function(Landscape) canUse;
  final ValueChanged<Landscape> onTap;

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(17) / 17;
    final tileHeight = 148.0 + (scale > 1.3 ? (scale - 1.3) * 60 : 0);
    final rows = <Widget>[];
    for (var i = 0; i < landscapes.length; i += 2) {
      rows.add(Padding(
        padding: EdgeInsets.only(bottom: i + 2 < landscapes.length ? 12 : 0),
        child: Row(
          children: [
            Expanded(child: _tile(context, landscapes[i], tileHeight)),
            const SizedBox(width: 12),
            Expanded(child: i + 1 < landscapes.length ? _tile(context, landscapes[i + 1], tileHeight) : const SizedBox()),
          ],
        ),
      ));
    }
    return Column(children: rows);
  }

  Widget _tile(BuildContext context, Landscape l, double height) {
    final selected = l.id == selectedId;
    final locked = !canUse(l);
    final p = Vitre.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: '${l.name}${selected ? ', sélectionné' : ''}${locked ? ', Premium' : ''}',
      excludeSemantics: true,
      onTap: () => onTap(l),
      child: GestureDetector(
        onTap: () => onTap(l),
        child: Container(
          height: height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            color: VitreColors.thumbFallback,
            boxShadow: selected ? const [BoxShadow(color: Colors.white, spreadRadius: 2.5)] : null,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: Stack(
              children: [
                Positioned.fill(child: LandscapeThumbnail(landscapeId: l.id, style: l.style)),
                const Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [Color(0xD9000000), Color(0x00000000)],
                        stops: [0, 0.62],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 10,
                  child: Text(
                    l.name,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: manrope(17, weight: 600, height: 1.2),
                  ),
                ),
                if (selected)
                  Positioned(
                    right: 10,
                    top: 10,
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: const BoxDecoration(color: VitreColors.white, shape: BoxShape.circle),
                      alignment: Alignment.center,
                      child: const VIcon(VIcons.check, size: 16, color: VitreColors.ink, strokeWidth: 3),
                    ),
                  )
                else if (locked)
                  Positioned(
                    right: 10,
                    top: 10,
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: p.glass(0.6),
                        shape: BoxShape.circle,
                        border: Border.all(color: p.border(0.3)),
                      ),
                      alignment: Alignment.center,
                      child: const VIcon(VIcons.lock, size: 16, color: VitreColors.white, strokeWidth: 2.2),
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

/// « Favoris » tab (not in the mockup): saved landscape + mix selections.
class _FavoritesList extends StatelessWidget {
  const _FavoritesList({required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final p = Vitre.of(context);
    final favorites = model.favorites;
    final max = model.rules.maxFavorites(model.plan);
    final children = <Widget>[];
    if (favorites.isEmpty) {
      children.add(DashedBorderBox(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            VIcon(VIcons.heart, size: 28, color: p.text(0.9)),
            const SizedBox(height: 10),
            Text('Aucun favori pour l’instant', style: manrope(19, weight: 700)),
            const SizedBox(height: 6),
            Text(
              'Touchez le cœur de l’accueil pour garder un paysage avec ses sons.',
              style: manrope(17, height: 1.4, color: p.text(0.8)),
            ),
          ],
        ),
      ));
    }
    for (final f in favorites) {
      final l = model.catalog.landscape(f.landscapeId);
      if (l == null) continue;
      final names = [
        for (final kind in const [LayerKind.son, LayerKind.musique])
          for (final layer in f.scene.layers(kind)) model.catalog.item(kind, layer.id)?.name ?? '',
      ].where((n) => n.isNotEmpty).take(3).join(' · ');
      children.add(Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Material(
          color: p.fill(0.07),
          borderRadius: BorderRadius.circular(22),
          child: Row(
            children: [
              Expanded(
                child: Semantics(
                  button: true,
                  label: 'Écouter ${l.name}${names.isEmpty ? '' : ', $names'}',
                  excludeSemantics: true,
                  onTap: () => _apply(context, f),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(22),
                    onTap: () => _apply(context, f),
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Row(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(14),
                            child: SizedBox.square(dimension: 56, child: LandscapeThumbnail(landscapeId: l.id, style: l.style)),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(l.name, style: manrope(18, weight: 700)),
                                if (names.isNotEmpty)
                                  Text(names, style: manrope(16, color: p.text(0.72))),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              RoundIconButton(
                icon: VIcons.trash,
                label: 'Retirer ${l.name} des favoris',
                onPressed: () => model.removeFavorite(f.id),
                fillAlpha: 0,
                borderAlpha: 0,
              ),
              const SizedBox(width: 6),
            ],
          ),
        ),
      ));
    }
    if (max != null) {
      children.add(Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          'Version gratuite : $max favoris. Premium n’a pas de limite.',
          textAlign: TextAlign.center,
          style: manrope(16, color: p.text(0.72)),
        ),
      ));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }

  void _apply(BuildContext context, Favorite f) {
    model.applyFavorite(f);
    Navigator.of(context).maybePop();
  }
}
