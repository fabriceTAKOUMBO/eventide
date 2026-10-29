// Plans, entitlements (contract §6) and the free/Premium product rules
// (dossier, section 6).

import 'catalog.dart';
import 'scene.dart';

enum Plan {
  free,
  monthly,
  annual,
  lifetime;

  /// Monthly, annual and lifetime are Premium.
  bool get isPremium => this != Plan.free;

  static Plan fromId(Object? value) {
    for (final p in Plan.values) {
      if (p.name == value) return p;
    }
    return Plan.free;
  }
}

/// Body of `GET /entitlements` (contract §6).
class Entitlements {
  const Entitlements({
    required this.plan,
    required this.premium,
    this.expiresAt,
    this.autoRenewing = false,
  });

  /// Free plan (used before the first sync).
  factory Entitlements.free() =>
      const Entitlements(plan: Plan.free, premium: false);

  final Plan plan;
  final bool premium;
  final DateTime? expiresAt;
  final bool autoRenewing;

  /// Lenient: unknown fields are ignored.
  factory Entitlements.fromJson(Map<String, dynamic> json) {
    final plan = Plan.fromId(json['plan']);
    final expires = json['expires_at'];
    return Entitlements(
      plan: plan,
      premium: json['premium'] is bool
          ? json['premium'] as bool
          : plan.isPremium,
      expiresAt: expires is String ? DateTime.tryParse(expires) : null,
      autoRenewing: json['auto_renewing'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
    'plan': plan.name,
    'premium': premium,
    'expires_at': expiresAt?.toUtc().toIso8601String(),
    'auto_renewing': autoRenewing,
  };

  @override
  bool operator ==(Object other) =>
      other is Entitlements &&
      other.plan == plan &&
      other.premium == premium &&
      other.expiresAt == expiresAt &&
      other.autoRenewing == autoRenewing;

  @override
  int get hashCode => Object.hash(plan, premium, expiresAt, autoRenewing);
}

/// Who may use what (dossier, section 6).
class ProductRules {
  ProductRules(this.catalog);

  final Catalog catalog;

  /// Free: the landscapes flagged `gratuit`. Premium: all.
  bool canUseLandscape(Plan plan, Landscape landscape) =>
      plan.isPremium || landscape.free;

  /// Unknown ids are never usable.
  bool canUseItem(Plan plan, LayerKind kind, String id) {
    final item = catalog.item(kind, id);
    if (item == null) return false;
    return plan.isPremium || item.free;
  }

  /// Elements of [scene] the plan cannot play (for a received shared mix,
  /// shown locked). The landscape is reported with kind null.
  List<({LayerKind? kind, String id})> lockedElements(Plan plan, Scene scene) {
    final locked = <({LayerKind? kind, String id})>[];
    final landscape = catalog.landscape(scene.landscapeId);
    if (landscape == null || !canUseLandscape(plan, landscape)) {
      locked.add((kind: null, id: scene.landscapeId));
    }
    for (final kind in LayerKind.values) {
      for (final layer in scene.layers(kind)) {
        if (!canUseItem(plan, kind, layer.id)) {
          locked.add((kind: kind, id: layer.id));
        }
      }
    }
    return locked;
  }

  /// 1 for free, null = unlimited.
  int? maxSchedules(Plan plan) =>
      plan.isPremium ? null : catalog.limits.freeSchedules;

  /// 3 for free, null = unlimited.
  int? maxFavorites(Plan plan) =>
      plan.isPremium ? null : catalog.limits.freeFavorites;

  /// Free requires a connection; Premium plays downloaded content offline.
  bool offlineAllowed(Plan plan) => plan.isPremium;

  /// Light ads at opening and exit, never during playback: free only.
  bool showsAds(Plan plan) => !plan.isPremium;

  /// Full sleep history; free sees only the last night.
  bool sleepHistory(Plan plan) => plan.isPremium;
}
