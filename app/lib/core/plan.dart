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

  /// The voice assistant is included in monthly and annual only.
  bool get includesAssistant => this == Plan.monthly || this == Plan.annual;

  static Plan fromId(Object? value) {
    for (final p in Plan.values) {
      if (p.name == value) return p;
    }
    return Plan.free;
  }
}

enum VoiceMode {
  /// Free plan: 3 trial requests, once.
  trial,

  /// Monthly and annual: included, with a monthly cost cap.
  included,

  /// Lifetime: credits sold separately.
  credits,

  /// No assistant available.
  none;

  static VoiceMode fromId(Object? value) {
    for (final m in VoiceMode.values) {
      if (m.name == value) return m;
    }
    return VoiceMode.none;
  }
}

class VoiceQuota {
  const VoiceQuota({
    required this.mode,
    this.trialRemaining = 0,
    this.creditsRemaining = 0,
    this.monthlyCapReached = false,
  });

  final VoiceMode mode;
  final int trialRemaining;
  final int creditsRemaining;

  /// The 2 € monthly cap is reached: rules only until next month.
  final bool monthlyCapReached;

  /// The server model can be called (rules always work locally).
  bool get canUseModel => switch (mode) {
    VoiceMode.trial => trialRemaining > 0,
    VoiceMode.included => !monthlyCapReached,
    VoiceMode.credits => creditsRemaining > 0,
    VoiceMode.none => false,
  };

  factory VoiceQuota.fromJson(Map<String, dynamic> json) {
    int read(String key) {
      final v = json[key];
      return v is num ? v.toInt() : 0;
    }

    return VoiceQuota(
      mode: VoiceMode.fromId(json['mode']),
      trialRemaining: read('trial_remaining'),
      creditsRemaining: read('credits_remaining'),
      monthlyCapReached: json['monthly_cap_reached'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    'trial_remaining': trialRemaining,
    'credits_remaining': creditsRemaining,
    'monthly_cap_reached': monthlyCapReached,
  };

  @override
  bool operator ==(Object other) =>
      other is VoiceQuota &&
      other.mode == mode &&
      other.trialRemaining == trialRemaining &&
      other.creditsRemaining == creditsRemaining &&
      other.monthlyCapReached == monthlyCapReached;

  @override
  int get hashCode =>
      Object.hash(mode, trialRemaining, creditsRemaining, monthlyCapReached);
}

/// Body of `GET /entitlements` (contract §6).
class Entitlements {
  const Entitlements({
    required this.plan,
    required this.premium,
    this.expiresAt,
    this.autoRenewing = false,
    required this.voice,
  });

  /// Free plan with the 3 trial requests (used before the first sync).
  factory Entitlements.free({int trialRemaining = 3}) => Entitlements(
    plan: Plan.free,
    premium: false,
    voice: VoiceQuota(mode: VoiceMode.trial, trialRemaining: trialRemaining),
  );

  final Plan plan;
  final bool premium;
  final DateTime? expiresAt;
  final bool autoRenewing;
  final VoiceQuota voice;

  factory Entitlements.fromJson(Map<String, dynamic> json) {
    final plan = Plan.fromId(json['plan']);
    final expires = json['expires_at'];
    final voice = json['voice'];
    return Entitlements(
      plan: plan,
      premium: json['premium'] is bool
          ? json['premium'] as bool
          : plan.isPremium,
      expiresAt: expires is String ? DateTime.tryParse(expires) : null,
      autoRenewing: json['auto_renewing'] == true,
      voice: voice is Map
          ? VoiceQuota.fromJson(Map<String, dynamic>.from(voice))
          : const VoiceQuota(mode: VoiceMode.none),
    );
  }

  Map<String, dynamic> toJson() => {
    'plan': plan.name,
    'premium': premium,
    'expires_at': expiresAt?.toUtc().toIso8601String(),
    'auto_renewing': autoRenewing,
    'voice': voice.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is Entitlements &&
      other.plan == plan &&
      other.premium == premium &&
      other.expiresAt == expiresAt &&
      other.autoRenewing == autoRenewing &&
      other.voice == voice;

  @override
  int get hashCode =>
      Object.hash(plan, premium, expiresAt, autoRenewing, voice);
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
