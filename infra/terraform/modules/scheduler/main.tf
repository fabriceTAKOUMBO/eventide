# EventBridge Scheduler -> ECS RunTask : commandes de gestion Django d'Eventide (purge
# quotidienne, finalisation horaire des achats) et sauvegarde logique quotidienne.
# Repris de Candidature Express (modules/scheduler).
#
# La cible référence la FAMILLE de la définition de tâche api (ARN sans révision) : ECS
# lance la dernière révision active, donc toujours l'image du dernier déploiement.
# Un échec (code de sortie non nul) déclenche une alerte (module observability).

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  region     = data.aws_region.current.region
  account_id = data.aws_caller_identity.current.account_id

  # Famille par tâche : celle de la tâche (ex. sauvegarde) ou, à défaut, var.task_family.
  job_families = { for k, j in var.jobs : k => coalesce(j.task_family, var.task_family) }
  family_arns  = { for k, f in local.job_families : k => "arn:aws:ecs:${local.region}:${local.account_id}:task-definition/${f}" }
  all_family_arns = distinct(flatten([
    for f in values(local.family_arns) : [f, "${f}:*"]
  ]))
}

resource "aws_scheduler_schedule_group" "this" {
  name = var.name
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name               = "${var.name}-scheduler"
  description        = "EventBridge Scheduler : taches planifiees Eventide"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

data "aws_iam_policy_document" "scheduler" {
  statement {
    sid       = "RunJobTask"
    actions   = ["ecs:RunTask"]
    resources = local.all_family_arns
    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [var.cluster_arn]
    }
  }

  statement {
    sid       = "TagLaunchedTasks"
    actions   = ["ecs:TagResource"]
    resources = ["arn:aws:ecs:${local.region}:${local.account_id}:task/${var.cluster_name}/*"]
    condition {
      test     = "StringEquals"
      variable = "ecs:CreateAction"
      values   = ["RunTask"]
    }
  }

  statement {
    sid       = "PassTaskRoles"
    actions   = ["iam:PassRole"]
    resources = var.pass_role_arns
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "scheduler" {
  name   = "run-jobs"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler.json
}

resource "aws_scheduler_schedule" "job" {
  for_each   = var.jobs
  name       = "${var.name}-${each.key}"
  group_name = aws_scheduler_schedule_group.this.name

  description                  = each.value.description
  schedule_expression          = each.value.schedule
  schedule_expression_timezone = var.timezone
  state                        = var.enabled && each.value.enabled ? "ENABLED" : "DISABLED"

  # Fenêtre souple (15 min par défaut) ; 0 = heure exacte (tâches fréquentes, toutes les 5 ou
  # 15 minutes, qui ne doivent pas se chevaucher).
  flexible_time_window {
    mode                      = each.value.flexible_window_minutes > 0 ? "FLEXIBLE" : "OFF"
    maximum_window_in_minutes = each.value.flexible_window_minutes > 0 ? each.value.flexible_window_minutes : null
  }

  target {
    arn      = var.cluster_arn
    role_arn = aws_iam_role.scheduler.arn

    ecs_parameters {
      task_definition_arn     = local.family_arns[each.key]
      task_count              = 1
      platform_version        = "LATEST"
      enable_ecs_managed_tags = true
      propagate_tags          = "TASK_DEFINITION"
      group                   = "job:${each.key}"

      capacity_provider_strategy {
        capacity_provider = var.capacity_provider
        weight            = 1
      }

      network_configuration {
        subnets          = var.subnet_ids
        security_groups  = var.security_group_ids
        assign_public_ip = false
      }
    }

    input = each.value.command == null ? null : jsonencode({
      containerOverrides = [{
        name    = coalesce(each.value.container_name, var.container_name)
        command = each.value.command
      }]
    })

    retry_policy {
      maximum_event_age_in_seconds = 3600
      maximum_retry_attempts       = 2
    }
  }
}
