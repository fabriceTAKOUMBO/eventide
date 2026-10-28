# Alertes d'Eventide : sujet SNS chiffré par notre clé (abonnements e-mail à confirmer), alarmes
# CloudWatch sur NOTRE groupe cible et NOTRE service, sur des événements des journaux JSON de
# l'API et des tâches, sur le volume de journaux ingérés, et alerte d'échec d'une tâche
# ponctuelle. Adapté de Candidature Express (modules/observability), sans cache ni e-mail.
#
# Les alarmes de l'instance PostgreSQL partagée (lecture de ses métriques seulement) sont
# facultatives et coupées par défaut : Candidature Express les a déjà sur la même instance.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id    = data.aws_caller_identity.current.account_id
  alarm_actions = [aws_sns_topic.alerts.arn]
}

resource "aws_sns_topic" "alerts" {
  name              = "${var.name}-alerts"
  kms_master_key_id = var.kms_key_arn
}

data "aws_iam_policy_document" "alerts" {
  statement {
    sid       = "AllowEventBridge"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }

  # Compte partagé : seules NOS alarmes (préfixe <name>-) publient ici.
  statement {
    sid       = "AllowOurCloudWatchAlarms"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cloudwatch:${data.aws_region.current.region}:${local.account_id}:alarm:${var.name}-*"]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts.json
}

resource "aws_sns_topic_subscription" "email" {
  for_each  = toset(var.alert_emails)
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

# --- Notre groupe cible (seulement avec un domaine) ------------------------------------------------
# Pas d'alarme sur les 5xx de tout l'ALB : il est partagé (ses chiffres comptent CINAF).

locals {
  # Clés connues au plan (booléen), valeurs connues après l'apply (suffixe du groupe cible).
  target_alarms = !var.target_alarms_enabled ? {} : {
    "api-5xx" = {
      metric      = "HTTPCode_Target_5XX_Count", statistic = "Sum", extended = null, period = 300,
      periods     = 1, datapoints = 1, threshold = var.target_5xx_threshold,
      operator    = "GreaterThanOrEqualToThreshold",
      description = "Erreurs 5xx renvoyees par l API Eventide"
    }
    "api-latency-p95" = {
      metric      = "TargetResponseTime", statistic = null, extended = "p95", period = 300,
      periods     = 3, datapoints = 2, threshold = var.latency_p95_threshold_seconds,
      operator    = "GreaterThanThreshold",
      description = "Temps de reponse p95 de l API superieur a ${var.latency_p95_threshold_seconds} s (l assistant vocal attend le modele)"
    }
    "api-unhealthy" = {
      metric      = "UnHealthyHostCount", statistic = "Maximum", extended = null, period = 60,
      periods     = 5, datapoints = 5, threshold = 0, operator = "GreaterThanThreshold",
      description = "Au moins une tache api echoue au controle de sante de l ALB (/v1/health)"
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "target" {
  for_each            = local.target_alarms
  alarm_name          = "${var.name}-${each.key}"
  alarm_description   = each.value.description
  namespace           = "AWS/ApplicationELB"
  metric_name         = each.value.metric
  dimensions          = { LoadBalancer = var.alb_arn_suffix, TargetGroup = var.target_group_arn_suffix }
  statistic           = each.value.statistic
  extended_statistic  = each.value.extended
  period              = each.value.period
  evaluation_periods  = each.value.periods
  datapoints_to_alarm = each.value.datapoints
  threshold           = each.value.threshold
  comparison_operator = each.value.operator
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

# --- ECS ---------------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "ecs" {
  for_each = {
    for pair in setproduct(keys(var.ecs_service_names), ["CPUUtilization", "MemoryUtilization"]) :
    "${pair[0]}-${lower(replace(pair[1], "Utilization", ""))}" => { service = pair[0], metric = pair[1] }
  }
  alarm_name          = "${var.name}-${each.key}"
  alarm_description   = "${each.value.metric} du service ${each.value.service} superieur a ${var.ecs_utilization_threshold} % pendant 15 min"
  namespace           = "AWS/ECS"
  metric_name         = each.value.metric
  dimensions          = { ClusterName = var.ecs_cluster_name, ServiceName = var.ecs_service_names[each.value.service] }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = var.ecs_utilization_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

# --- Instance PostgreSQL partagée (métriques lues seulement) -------------------------------------
# Load of the shared instance (AGENTS.md rule 5): metric-only alarms (AWS/RDS metrics are read,
# nothing of the instance is), notifying OUR topic. A CloudWatch alarm cannot act on an RDS
# instance; the only actions here are SNS publications (checked again at plan time by
# .github/scripts/check-plan-additions-only.sh). CPUCreditBalance only exists on burstable
# classes (db.t*): absent metric = not breaching.

resource "aws_cloudwatch_metric_alarm" "rds" {
  for_each = var.rds_alarms_enabled ? {
    cpu         = { metric = "CPUUtilization", statistic = "Average", threshold = var.rds_cpu_threshold, operator = "GreaterThanThreshold", description = "CPU de l instance partagee superieur a ${var.rds_cpu_threshold} %" }
    connections = { metric = "DatabaseConnections", statistic = "Maximum", threshold = var.rds_connections_threshold, operator = "GreaterThanThreshold", description = "Connexions de l instance partagee (toutes applications) superieures a ${var.rds_connections_threshold}" }
    memory      = { metric = "FreeableMemory", statistic = "Minimum", threshold = var.rds_freeable_memory_mb * 1048576, operator = "LessThanThreshold", description = "Memoire libre de l instance partagee inferieure a ${var.rds_freeable_memory_mb} Mo" }
    storage     = { metric = "FreeStorageSpace", statistic = "Minimum", threshold = var.rds_free_storage_gb * 1073741824, operator = "LessThanThreshold", description = "Disque libre de l instance partagee inferieur a ${var.rds_free_storage_gb} Go (nos bases, nos fichiers temporaires et le test de restauration y ecrivent)" }
    cpu-credits = { metric = "CPUCreditBalance", statistic = "Minimum", threshold = var.rds_cpu_credits_threshold, operator = "LessThanThreshold", description = "Credits CPU de l instance partagee inferieurs a ${var.rds_cpu_credits_threshold} (classe db.t*)" }
  } : {}
  alarm_name          = "${var.name}-rds-${each.key}"
  alarm_description   = "${each.value.description} : verifier la part d Eventide dans Performance Insights (dimensions base et utilisateur)."
  namespace           = "AWS/RDS"
  metric_name         = each.value.metric
  dimensions          = { DBInstanceIdentifier = var.rds_instance_id }
  statistic           = each.value.statistic
  period              = 300
  evaluation_periods  = 3
  threshold           = each.value.threshold
  comparison_operator = each.value.operator
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

# --- Événements applicatifs (journaux JSON de Django, clé « event ») ------------------------------

locals {
  metric_namespace = "Eventide/${var.name}"

  log_events = {
    voice-global-cap = {
      event       = "voice_global_cap_reached"
      metric      = "VoiceGlobalCapReached"
      threshold   = 1
      period      = 300
      description = "Plafond quotidien GLOBAL du cout de l assistant atteint (VOICE_GLOBAL_DAILY_CAP_EUR) : abus possible, ou plafond trop bas. L assistant repond 503 model_unavailable (regles seules). Journaux : event = voice_global_cap_reached."
    }
    model-unavailable = {
      event       = "model_unavailable"
      metric      = "ModelUnavailable"
      threshold   = var.model_unavailable_threshold
      period      = 300
      description = "Echecs repetes d appel au modele Gemini (cle, quota Google, panne, modele retire) : reservations rendues, l application passe aux regles seules. Journaux : event = model_unavailable."
    }
    purchase-finalization-failed = {
      event       = "purchase_finalization_failed"
      metric      = "PurchaseFinalizationFailed"
      threshold   = 3
      period      = 3600
      description = "Achats non acquittes ou non consommes (Google rembourse apres 3 jours) : finalize_purchases reessaie chaque heure. Journaux : event = purchase_finalization_failed."
    }
    google-credentials = {
      event       = "play_api_auth_error"
      metric      = "PlayApiAuthError"
      threshold   = 1
      period      = 300
      description = "L API Google Play Developer refuse notre compte de service (droits Play Console, cle revoquee) : achats et RTDN indisponibles. Journaux : event = play_api_auth_error."
    }
    google-not-configured = {
      event       = "google_not_configured"
      metric      = "GoogleNotConfigured"
      threshold   = 1
      period      = 300
      description = "Secret du compte de service Google Play absent (A_REMPLACER) : Play Integrity et achats en 503. Journaux : event = google_not_configured."
    }
    rtdn-rejected = {
      event       = "rtdn_rejected"
      metric      = "RtdnRejected"
      threshold   = 5
      period      = 3600
      description = "Notifications Google Play refusees (jeton Pub/Sub, audience ou compte de service) : verifier RTDN_AUDIENCE et RTDN_SERVICE_ACCOUNT_EMAIL. Journaux : event = rtdn_rejected."
    }
  }

  log_event_filters = {
    for pair in setproduct(keys(local.log_events), keys(var.app_log_group_names)) :
    "${pair[0]}-${pair[1]}" => { event_key = pair[0], log_group = var.app_log_group_names[pair[1]] }
  }
}

resource "aws_cloudwatch_log_metric_filter" "app_event" {
  for_each       = local.log_event_filters
  name           = "${var.name}-${each.key}"
  log_group_name = each.value.log_group
  pattern        = "{ $.event = \"${local.log_events[each.value.event_key].event}\" }"

  metric_transformation {
    name          = local.log_events[each.value.event_key].metric
    namespace     = local.metric_namespace
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "app_event" {
  for_each            = local.log_events
  alarm_name          = "${var.name}-${each.key}"
  alarm_description   = each.value.description
  namespace           = local.metric_namespace
  metric_name         = each.value.metric
  statistic           = "Sum"
  period              = each.value.period
  evaluation_periods  = 1
  threshold           = each.value.threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  depends_on = [aws_cloudwatch_log_metric_filter.app_event]
}

# --- Volume de journaux ingérés (coût) -------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "log_ingestion" {
  for_each            = var.app_log_group_names
  alarm_name          = "${var.name}-${each.key}-log-ingestion"
  alarm_description   = "Journaux ${each.value} : plus de ${var.log_ingestion_gb_per_day} Go ingeres en 24 h (cout CloudWatch Logs). Chercher l evenement le plus frequent (Logs Insights : stats count(*) by event)."
  namespace           = "AWS/Logs"
  metric_name         = "IncomingBytes"
  dimensions          = { LogGroupName = each.value }
  statistic           = "Sum"
  period              = 86400
  evaluation_periods  = 1
  threshold           = var.log_ingestion_gb_per_day * 1000000000
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

# --- Échec d'une tâche ponctuelle (tâches planifiées, sauvegarde, migration, amorçage) ------------

resource "aws_cloudwatch_event_rule" "task_failed" {
  name        = "${var.name}-one-off-task-failed"
  description = "Tache ECS Eventide hors service (planifiee, sauvegarde, migration, amorcage) terminee en erreur"

  event_pattern = jsonencode({
    source        = ["aws.ecs"]
    "detail-type" = ["ECS Task State Change"]
    detail = {
      clusterArn = [var.ecs_cluster_arn]
      lastStatus = ["STOPPED"]
      group      = [{ "anything-but" = { prefix = "service:" } }]
      "$or" = [
        { containers = { exitCode = [{ "anything-but" = 0 }] } },
        { stopCode = ["TaskFailedToStart"] },
      ]
    }
  })
}

resource "aws_cloudwatch_event_target" "task_failed" {
  rule      = aws_cloudwatch_event_rule.task_failed.name
  target_id = "sns"
  arn       = aws_sns_topic.alerts.arn

  input_transformer {
    input_paths = {
      group  = "$.detail.group"
      task   = "$.detail.taskArn"
      reason = "$.detail.stoppedReason"
    }
    input_template = "\"[${var.name}] Tache ECS en echec : <group> (<task>). Raison : <reason>. Journaux : /ecs/${var.name}/jobs.\""
  }
}
