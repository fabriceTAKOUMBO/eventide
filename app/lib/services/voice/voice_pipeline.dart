// Voice chain after transcription (dossier § 7): normalization → on-device rules → server model
// → validation on the phone. Counting (free trial, lifetime credits, monthly cap) is the
// server's job; this class only decides when to call it and how to read its answer.
import '../../core/catalog.dart';
import '../../core/french_normalizer.dart';
import '../../core/ops.dart';
import '../../core/plan.dart';
import '../../core/rules_parser.dart';
import '../api_client.dart';

enum VoiceSource {
  /// Resolved on the phone, not sent (subscribers, no backend, server unreachable).
  rules,

  /// Resolved on the phone and counted by the server (`actions_locales`).
  local,

  /// Resolved by the server model.
  model,
}

sealed class VoiceResolution {
  const VoiceResolution();
}

/// Operations ready for applyOps (already validated on the phone).
class VoiceOpsResolution extends VoiceResolution {
  const VoiceOpsResolution({required this.ops, required this.source, this.quota});

  final List<Map<String, dynamic>> ops;
  final VoiceSource source;

  /// Quota after this request, when the server answered.
  final VoiceQuota? quota;
}

/// 402 `voice_quota_exhausted`: free → Premium screen, lifetime → credits screen.
class VoiceQuotaExhaustedResolution extends VoiceResolution {
  const VoiceQuotaExhaustedResolution(this.mode);
  final VoiceMode mode;
}

/// Nothing to apply; [message] is shown instead (offline, timeout, not understood).
class VoiceFailureResolution extends VoiceResolution {
  const VoiceFailureResolution(this.message, {this.offline = false, this.rephrase = false, this.quota});

  final String message;
  final bool offline;

  /// Not understood: shown as « reformuler » rather than as an error.
  final bool rephrase;
  final VoiceQuota? quota;
}

abstract final class VoiceMessages {
  static const notUnderstood =
      'Je n’ai pas bien compris. Essayez une phrase simple, par exemple « Ajoute du piano doux ».';
  static const offline = 'Pas de connexion : l’assistant a besoin d’internet pour cette demande.';
  static const slow = 'La réponse tarde. Réessayez dans un instant.';
  static const unavailable = 'L’assistant ne peut pas répondre pour le moment. Réessayez plus tard.';
}

class VoicePipeline {
  VoicePipeline({required this.catalog, required this.api});

  final Catalog catalog;
  final ApiClient api;

  Future<VoiceResolution> resolve({
    required String phrase,
    required AppSnapshot snapshot,
    required Entitlements entitlements,
  }) async {
    final plan = entitlements.plan;
    final quota = entitlements.voice;
    final normalized = normalizeFrench(phrase);
    final rules = parseWithRules(normalized, snapshot, catalog);
    final localOps = rules == null ? null : validateOps(rules, catalog, plan);
    final state = snapshot.toVoiceState();

    if (localOps != null) {
      // Subscribers: a rules hit costs nothing and is not counted. No backend: rules only.
      if (plan.includesAssistant || !api.enabled) {
        return VoiceOpsResolution(ops: localOps, source: VoiceSource.rules);
      }
      // Free trial and lifetime credits are counted by the server, even for rules hits.
      try {
        final response = await api.voice(
          phrase: phrase,
          normalized: normalized,
          state: state,
          localActions: localOps,
        );
        return VoiceOpsResolution(
          ops: validateOps(response.actions, catalog, plan),
          source: VoiceSource.local,
          quota: _quota(response.voice),
        );
      } on ApiException catch (e) {
        if (e.status == 402 && e.code == 'voice_quota_exhausted') {
          return VoiceQuotaExhaustedResolution(quota.mode);
        }
        // voice_monthly_cap, 503 and the rest: never a hard cut, rules only.
        return VoiceOpsResolution(ops: localOps, source: VoiceSource.rules);
      } on ApiUnavailableException {
        if (!quota.canUseModel && quota.mode != VoiceMode.included) {
          return VoiceQuotaExhaustedResolution(quota.mode);
        }
        return VoiceOpsResolution(ops: localOps, source: VoiceSource.rules);
      }
    }

    // Rules not confident: the model is needed.
    if (!api.enabled) {
      return const VoiceFailureResolution(VoiceMessages.notUnderstood, rephrase: true);
    }
    if (!quota.canUseModel) {
      if (quota.mode == VoiceMode.included) {
        // Monthly cap reached: rules only until next month.
        return const VoiceFailureResolution(VoiceMessages.notUnderstood, rephrase: true);
      }
      return VoiceQuotaExhaustedResolution(quota.mode);
    }
    try {
      final response = await api.voice(phrase: phrase, normalized: normalized, state: state);
      return VoiceOpsResolution(
        ops: validateOps(response.actions, catalog, plan),
        source: response.source == 'local' ? VoiceSource.local : VoiceSource.model,
        quota: _quota(response.voice),
      );
    } on ApiException catch (e) {
      if (e.status == 402 && e.code == 'voice_quota_exhausted') {
        return VoiceQuotaExhaustedResolution(quota.mode);
      }
      if (e.status == 402 && e.code == 'voice_monthly_cap') {
        return VoiceFailureResolution(
          VoiceMessages.notUnderstood,
          rephrase: true,
          quota: VoiceQuota(
            mode: quota.mode,
            trialRemaining: quota.trialRemaining,
            creditsRemaining: quota.creditsRemaining,
            monthlyCapReached: true,
          ),
        );
      }
      if (e.status == 422 || e.status == 503) {
        return const VoiceFailureResolution(VoiceMessages.notUnderstood, rephrase: true);
      }
      return const VoiceFailureResolution(VoiceMessages.unavailable);
    } on ApiUnavailableException catch (e) {
      if (e.timeout) return const VoiceFailureResolution(VoiceMessages.slow);
      return const VoiceFailureResolution(VoiceMessages.offline, offline: true);
    }
  }

  static VoiceQuota? _quota(Map<String, dynamic>? json) => json == null ? null : VoiceQuota.fromJson(json);
}

/// « Essai gratuit · 2 demandes restantes », « Crédits · 48 restants »; null for subscribers.
String? quotaLabel(VoiceQuota quota) {
  switch (quota.mode) {
    case VoiceMode.trial:
      final n = quota.trialRemaining;
      if (n <= 0) return 'Essai gratuit terminé';
      return 'Essai gratuit · $n ${n == 1 ? 'demande restante' : 'demandes restantes'}';
    case VoiceMode.credits:
      final n = quota.creditsRemaining;
      return 'Crédits · $n ${n == 1 ? 'restant' : 'restants'}';
    case VoiceMode.included:
    case VoiceMode.none:
      return null;
  }
}
