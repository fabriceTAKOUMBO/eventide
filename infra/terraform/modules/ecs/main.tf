# ECS Fargate d'Eventide : cluster propre, service "api" (Django, qui sert aussi les pages web
# du domaine et le tableau de bord /tableau/), familles "migrate" (migrations, rôle
# ev_migrator), "jobs" (tâches planifiées) et "media" (traitement ffmpeg des fichiers publiés
# depuis le tableau de bord, lancé par l'API), dans les sous-réseaux privés « application »
# partagés. Définitions de tâche durcies (système de fichiers racine en lecture seule,
# utilisateur non-root, capacités Linux retirées, secrets depuis Secrets Manager), un rôle
# d'exécution par usage qui ne lit que SES secrets.
#
# Rôles de tâche (30 octobre 2026, ADR § 12) : seuls api et media en ont un, au moindre
# privilège. api : signer l'envoi direct d'un fichier source dans uploads/ de NOTRE bucket de
# contenu et lancer la famille media dans NOTRE cluster ; media : lire uploads/ et écrire les
# fichiers traités. migrate et jobs n'ont toujours aucun droit AWS à l'exécution. Les adresses
# CloudFront restent signées localement avec la clé injectée.
#
# Adapté de Candidature Express (modules/ecs) : sans web, admin, Service Connect, cache, SMS
# ni travailleur d'import.
#
# Le workflow Deploy enregistre de nouvelles révisions (image du commit déployé) par le
# registraire de tâches (modules/task_registrar), à partir des entrées d'enregistrement de ce
# module (local.register_inputs) ; Terraform reprend le tag déployé via le paramètre SSM image_tag.

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  region     = data.aws_region.current.region
  account_id = data.aws_caller_identity.current.account_id
  api_port   = 8000
  api_image  = "${var.ecr_repository_url}:${var.image_tag}"

  capacity_provider = var.use_fargate_spot ? "FARGATE_SPOT" : "FARGATE"

  log_groups = {
    api  = "/ecs/${var.name}/api"
    jobs = "/ecs/${var.name}/jobs"
  }

  # Deterministic names and ARNs (known at plan time: the IAM policies below are checked by
  # terraform test without AWS). IAM does not require a role to exist to name it in a policy.
  cluster_arn         = "arn:aws:ecs:${local.region}:${local.account_id}:cluster/${var.name}"
  media_family        = "${var.name}-media"
  media_family_arn    = "arn:aws:ecs:${local.region}:${local.account_id}:task-definition/${local.media_family}"
  role_arn_prefix     = "arn:aws:iam::${local.account_id}:role/"
  execution_role_name = { for k in ["api", "migrate", "jobs", "media"] : k => "${var.name}-${k}-execution" }
  task_role_name      = { api = "${var.name}-api-task", media = "${var.name}-media-task" }

  common_linux_parameters = {
    initProcessEnabled = true
    capabilities       = { add = [], drop = ["ALL"] }
  }
}

# --- Cluster -------------------------------------------------------------------------------------

resource "aws_ecs_cluster" "this" {
  name = var.name

  setting {
    name  = "containerInsights"
    value = "disabled" # ≈ 27 USD/mois évités (choix de Candidature Express)
  }
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = local.capacity_provider
    weight            = 1
    base              = 0
  }
}

resource "aws_cloudwatch_log_group" "this" {
  for_each          = local.log_groups
  name              = each.value
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
}

# --- Groupe de sécurité (le nôtre) ----------------------------------------------------------------
# Descriptions en ASCII sans apostrophe (exigence EC2, constat de Candidature Express).

resource "aws_security_group" "api" {
  name        = "${var.name}-api"
  description = "Eventide - taches api, migrations, taches planifiees et outils PostgreSQL"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-api" }
}

# Entrée seulement depuis le groupe de l'ALB partagé (cité comme source : ce groupe n'est pas
# modifié, la règle appartient à NOTRE groupe).
resource "aws_vpc_security_group_ingress_rule" "api_from_alb" {
  security_group_id            = aws_security_group.api.id
  description                  = "API depuis l ALB partage"
  ip_protocol                  = "tcp"
  from_port                    = local.api_port
  to_port                      = local.api_port
  referenced_security_group_id = var.alb_security_group_id
}

# Sorties : HTTPS (API Google : Play, Play Integrity, certificats ; API AWS : ECR,
# journaux, Secrets Manager) et 5432 vers le SEUL groupe de la base partagée.
resource "aws_vpc_security_group_egress_rule" "api_https" {
  security_group_id = aws_security_group.api.id
  description       = "HTTPS (Google, AWS)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "api_postgres" {
  security_group_id            = aws_security_group.api.id
  description                  = "PostgreSQL partage"
  ip_protocol                  = "tcp"
  from_port                    = var.postgres_port
  to_port                      = var.postgres_port
  referenced_security_group_id = var.postgres_security_group_id
}

# --- IAM : rôles d'exécution (un par usage, accès à ses seuls secrets) -----------------------------

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:ecs:${local.region}:${local.account_id}:*"]
    }
  }
}

# ARN d'un secret à partir d'une référence ECS (ARN complet, éventuellement suivi de
# ":clé-json:étape:version") : les 7 premiers segments séparés par ":".
locals {
  execution_roles = {
    api = {
      log_group   = local.log_groups.api
      secret_arns = distinct([for ref in values(var.api_secrets) : join(":", slice(split(":", ref), 0, 7))])
    }
    migrate = {
      log_group   = local.log_groups.jobs
      secret_arns = distinct([for ref in values(var.migrate_secrets) : join(":", slice(split(":", ref), 0, 7))])
    }
    jobs = {
      log_group   = local.log_groups.jobs
      secret_arns = distinct([for ref in values(var.jobs_secrets) : join(":", slice(split(":", ref), 0, 7))])
    }
    # Media processing: like jobs (image, logs in the jobs group), only ITS secrets (database
    # and Django key; never ADMIN_EMAILS, the Google Play key nor the CloudFront key).
    media = {
      log_group   = local.log_groups.jobs
      secret_arns = distinct([for ref in values(var.media_secrets) : join(":", slice(split(":", ref), 0, 7))])
    }
  }
}

resource "aws_iam_role" "execution" {
  for_each           = local.execution_roles
  name               = local.execution_role_name[each.key]
  description        = "Role d execution ECS (${each.key}) : image, journaux, ses propres secrets"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "execution" {
  for_each = local.execution_roles

  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid       = "EcrPull"
    actions   = ["ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage"]
    resources = [var.ecr_repository_arn]
  }

  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:${local.region}:${local.account_id}:log-group:${each.value.log_group}:log-stream:*"]
  }

  dynamic "statement" {
    for_each = length(each.value.secret_arns) > 0 ? [1] : []
    content {
      sid       = "OwnSecretsOnly"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = each.value.secret_arns
    }
  }

  dynamic "statement" {
    for_each = length(each.value.secret_arns) > 0 ? [1] : []
    content {
      sid       = "DecryptSecrets"
      actions   = ["kms:Decrypt"]
      resources = [var.kms_key_arn]
      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["secretsmanager.${local.region}.amazonaws.com"]
      }
    }
  }
}

resource "aws_iam_role_policy" "execution" {
  for_each = local.execution_roles
  name     = "execution"
  role     = aws_iam_role.execution[each.key].id
  policy   = data.aws_iam_policy_document.execution[each.key].json
}

# --- IAM : rôles de tâche (api et media seulement, tableau de bord) --------------------------------
# Every resource below is OURS: the content bucket (ev-<env>-content-<account>), the media family
# (ev-<env>-media) in our cluster (ev-<env>), our media roles. Nothing on a resource of CINAF,
# JobMinutes or Candidature Express. Written with jsonencode so that terraform test checks the
# exact statements without AWS (tests/task_roles.tftest.hcl).

locals {
  task_role_policies = {
    api = {
      Version = "2012-10-17"
      Statement = [
        {
          # The browser posts the source file straight to S3 with a form signed by the API
          # (presigned POST): the signer must be allowed to put the object. Only uploads/.
          Sid      = "SignDashboardUploads"
          Effect   = "Allow"
          Action   = ["s3:PutObject"]
          Resource = ["${var.content_bucket_arn}/${var.content_upload_prefix}*"]
        },
        {
          # Start the media family only, only in our cluster. Task-level CPU and memory
          # overrides above the media task's size are refused where ECS reports them (shared
          # Fargate vCPU quota; IfExists: no override, no key).
          Sid      = "StartMediaTasks"
          Effect   = "Allow"
          Action   = ["ecs:RunTask"]
          Resource = [local.media_family_arn, "${local.media_family_arn}:*"]
          Condition = {
            ArnEquals = { "ecs:cluster" = local.cluster_arn }
            NumericLessThanEqualsIfExists = {
              "ecs:task-cpu"    = tostring(var.media.cpu)
              "ecs:task-memory" = tostring(var.media.memory)
            }
          }
        },
        {
          # Tags propagated from the task definition (Project = eventide: cost allocation of
          # the media tasks), at launch only, on tasks of our cluster only.
          Sid      = "TagMediaTasksAtLaunch"
          Effect   = "Allow"
          Action   = ["ecs:TagResource"]
          Resource = ["arn:aws:ecs:${local.region}:${local.account_id}:task/${var.name}/*"]
          Condition = {
            StringEquals = { "ecs:CreateAction" = "RunTask" }
          }
        },
        {
          Sid    = "PassMediaRolesToEcsOnly"
          Effect = "Allow"
          Action = ["iam:PassRole"]
          Resource = [
            "${local.role_arn_prefix}${local.execution_role_name["media"]}",
            "${local.role_arn_prefix}${local.task_role_name["media"]}",
          ]
          Condition = {
            StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" }
          }
        },
      ]
    }
    media = {
      Version = "2012-10-17"
      Statement = [
        {
          Sid      = "ReadUploadedSources"
          Effect   = "Allow"
          Action   = ["s3:GetObject"]
          Resource = ["${var.content_bucket_arn}/${var.content_upload_prefix}*"]
        },
        {
          # Processed files (contract § 8 and § 13 layout). No List, no Delete: sources expire
          # by the bucket lifecycle, published files are never deleted by a task.
          Sid      = "WriteProcessedMedia"
          Effect   = "Allow"
          Action   = ["s3:PutObject"]
          Resource = [for p in var.content_media_prefixes : "${var.content_bucket_arn}/${p}*"]
        },
      ]
    }
  }
}

resource "aws_iam_role" "task" {
  for_each           = local.task_role_name
  name               = each.value
  description        = each.key == "api" ? "Role de la tache api : envoi direct vers uploads/ du contenu, lancement de la tache media" : "Role de la tache media : lecture de uploads/, ecriture des fichiers traites"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy" "task" {
  for_each = local.task_role_name
  name     = each.key == "api" ? "dashboard-uploads-and-media-tasks" : "process-media"
  role     = aws_iam_role.task[each.key].id
  policy   = jsonencode(local.task_role_policies[each.key])
}

# --- Définitions de tâche -------------------------------------------------------------------------

locals {
  api_container = {
    name                   = "api"
    image                  = local.api_image
    essential              = true
    readonlyRootFilesystem = true
    user                   = "10001:10001"
    portMappings = [{
      containerPort = local.api_port
      hostPort      = local.api_port
      protocol      = "tcp"
    }]
    environment     = [for k in sort(keys(var.api_environment)) : { name = k, value = var.api_environment[k] }]
    secrets         = [for k in sort(keys(var.api_secrets)) : { name = k, valueFrom = var.api_secrets[k] }]
    mountPoints     = [{ sourceVolume = "tmp", containerPath = "/tmp", readOnly = false }]
    linuxParameters = local.common_linux_parameters
    stopTimeout     = 30
    healthCheck = {
      command     = ["CMD", "python", "-c", "import sys, urllib.request; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/v1/health', timeout=4).status == 200 else 1)"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 30
    }
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = local.log_groups.api
        awslogs-region        = local.region
        awslogs-stream-prefix = "api"
        mode                  = "non-blocking"
        max-buffer-size       = "25m"
      }
    }
  }

  migrate_container = {
    name                   = "migrate"
    image                  = local.api_image
    essential              = true
    readonlyRootFilesystem = true
    user                   = "10001:10001"
    command                = ["python", "manage.py", "migrate", "--noinput"]
    environment            = [for k in sort(keys(var.migrate_environment)) : { name = k, value = var.migrate_environment[k] }]
    secrets                = [for k in sort(keys(var.migrate_secrets)) : { name = k, valueFrom = var.migrate_secrets[k] }]
    mountPoints            = [{ sourceVolume = "tmp", containerPath = "/tmp", readOnly = false }]
    linuxParameters        = local.common_linux_parameters
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = local.log_groups.jobs
        awslogs-region        = local.region
        awslogs-stream-prefix = "migrate"
      }
    }
  }

  # Tâches planifiées : image de l'API, commande remplacée par EventBridge Scheduler.
  jobs_container = {
    name                   = "jobs"
    image                  = local.api_image
    essential              = true
    readonlyRootFilesystem = true
    user                   = "10001:10001"
    command                = ["python", "manage.py", "check"]
    environment            = [for k in sort(keys(var.jobs_environment)) : { name = k, value = var.jobs_environment[k] }]
    secrets                = [for k in sort(keys(var.jobs_secrets)) : { name = k, valueFrom = var.jobs_secrets[k] }]
    mountPoints            = [{ sourceVolume = "tmp", containerPath = "/tmp", readOnly = false }]
    linuxParameters        = local.common_linux_parameters
    stopTimeout            = 30
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = local.log_groups.jobs
        awslogs-region        = local.region
        awslogs-stream-prefix = "jobs"
      }
    }
  }

  # Media processing (dashboard, contract § 14): API image (ffmpeg inside), command replaced
  # by the API at RunTask (containerOverrides). Writes only to /tmp (task ephemeral storage,
  # 20 GiB by default: a 300 MB source and its intermediate files fit).
  media_container = {
    name                   = "media"
    image                  = local.api_image
    essential              = true
    readonlyRootFilesystem = true
    user                   = "10001:10001"
    command                = ["python", "manage.py", "check"]
    environment            = [for k in sort(keys(var.media_environment)) : { name = k, value = var.media_environment[k] }]
    secrets                = [for k in sort(keys(var.media_secrets)) : { name = k, valueFrom = var.media_secrets[k] }]
    mountPoints            = [{ sourceVolume = "tmp", containerPath = "/tmp", readOnly = false }]
    linuxParameters        = local.common_linux_parameters
    stopTimeout            = 30
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = local.log_groups.jobs
        awslogs-region        = local.region
        awslogs-stream-prefix = "media"
      }
    }
  }
}

# Shape of each family, shared by the Terraform revisions below and by the register inputs of
# the deploy (local.register_inputs).
locals {
  task_shapes = {
    api     = { cpu = var.api.cpu, memory = var.api.memory, container = local.api_container, task_role = true }
    migrate = { cpu = 256, memory = 512, container = local.migrate_container, task_role = false }
    jobs    = { cpu = 256, memory = 512, container = local.jobs_container, task_role = false }
    media   = { cpu = var.media.cpu, memory = var.media.memory, container = local.media_container, task_role = true }
  }

  # Exact input of ecs:RegisterTaskDefinition for each family, identical to the Terraform
  # revision (the deploy only replaces the image). The task registrar (modules/task_registrar)
  # registers new revisions from it: the deploy never reads a task definition
  # (ecs:DescribeTaskDefinition only accepts "*" and would expose the task definitions of
  # CINAF, JobMinutes and Candidature Express) and never names a family itself. taskRoleArn
  # only for the families that have a task role (api, media).
  register_inputs = {
    for key, shape in local.task_shapes : key => merge(
      {
        family                  = "${var.name}-${key}"
        executionRoleArn        = aws_iam_role.execution[key].arn
        networkMode             = "awsvpc"
        requiresCompatibilities = ["FARGATE"]
        cpu                     = tostring(shape.cpu)
        memory                  = tostring(shape.memory)
        runtimePlatform         = { operatingSystemFamily = "LINUX", cpuArchitecture = var.cpu_architecture }
        volumes                 = [{ name = "tmp" }]
        containerDefinitions    = [shape.container]
      },
      shape.task_role ? { taskRoleArn = aws_iam_role.task[key].arn } : {},
    )
  }
}

resource "aws_ecs_task_definition" "api" {
  family                   = local.register_inputs.api.family
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = local.task_shapes.api.cpu
  memory                   = local.task_shapes.api.memory
  execution_role_arn       = aws_iam_role.execution["api"].arn
  task_role_arn            = aws_iam_role.task["api"].arn
  container_definitions    = jsonencode(local.register_inputs.api.containerDefinitions)

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }

  volume {
    name = "tmp"
  }
}

resource "aws_ecs_task_definition" "migrate" {
  family                   = local.register_inputs.migrate.family
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = local.task_shapes.migrate.cpu
  memory                   = local.task_shapes.migrate.memory
  execution_role_arn       = aws_iam_role.execution["migrate"].arn
  container_definitions    = jsonencode(local.register_inputs.migrate.containerDefinitions)

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }

  volume {
    name = "tmp"
  }
}

resource "aws_ecs_task_definition" "jobs" {
  family                   = local.register_inputs.jobs.family
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = local.task_shapes.jobs.cpu
  memory                   = local.task_shapes.jobs.memory
  execution_role_arn       = aws_iam_role.execution["jobs"].arn
  container_definitions    = jsonencode(local.register_inputs.jobs.containerDefinitions)

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }

  volume {
    name = "tmp"
  }
}

# Media processing, started by the API (ecs:RunTask, family ev-<env>-media, our cluster only).
# Default ephemeral storage (20 GiB, ADR § 12).
resource "aws_ecs_task_definition" "media" {
  family                   = local.register_inputs.media.family
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = local.task_shapes.media.cpu
  memory                   = local.task_shapes.media.memory
  execution_role_arn       = aws_iam_role.execution["media"].arn
  task_role_arn            = aws_iam_role.task["media"].arn
  container_definitions    = jsonencode(local.register_inputs.media.containerDefinitions)

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }

  volume {
    name = "tmp"
  }
}

# --- Service api (seulement quand l'entrée publique existe : un domaine est configuré) -----------

resource "aws_ecs_service" "api" {
  count                             = var.api_service_enabled ? 1 : 0
  name                              = "api"
  cluster                           = aws_ecs_cluster.this.id
  task_definition                   = aws_ecs_task_definition.api.arn
  desired_count                     = var.api.min
  platform_version                  = "LATEST"
  health_check_grace_period_seconds = 60
  enable_ecs_managed_tags           = true
  propagate_tags                    = "SERVICE"
  wait_for_steady_state             = false

  capacity_provider_strategy {
    capacity_provider = local.capacity_provider
    weight            = 1
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.api.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = "api"
    container_port   = local.api_port
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = var.deployment_maximum_percent

  lifecycle {
    # Nombre de tâches piloté par la mise à l'échelle automatique.
    ignore_changes = [desired_count]

    precondition {
      condition     = var.target_group_arn != null
      error_message = "Le service api exige un groupe cible (entrée publique, domaine configuré)."
    }
  }

  depends_on = [aws_ecs_cluster_capacity_providers.this]
}

# --- Mise à l'échelle automatique (CPU, mémoire, requêtes par tâche) ------------------------------

resource "aws_appautoscaling_target" "api" {
  count              = var.api_service_enabled && !var.scheduled_scaling ? 1 : 0
  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.api[0].name}"
  min_capacity       = var.api.min
  max_capacity       = var.api.max
}

# Préproduction : min et max pilotés par des actions planifiées (arrêt la nuit, hors module).
resource "aws_appautoscaling_target" "api_scheduled" {
  count              = var.api_service_enabled && var.scheduled_scaling ? 1 : 0
  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.api[0].name}"
  min_capacity       = var.api.min
  max_capacity       = var.api.max

  lifecycle {
    ignore_changes = [min_capacity, max_capacity]
  }
}

locals {
  scaling_target = one(concat(aws_appautoscaling_target.api, aws_appautoscaling_target.api_scheduled))
}

resource "aws_appautoscaling_policy" "api" {
  for_each = var.api_service_enabled ? {
    cpu      = { metric = "ECSServiceAverageCPUUtilization", target = 60, label = null }
    memory   = { metric = "ECSServiceAverageMemoryUtilization", target = 75, label = null }
    requests = { metric = "ALBRequestCountPerTarget", target = var.api.requests, label = var.request_count_resource_label }
  } : {}
  name               = "${var.name}-api-${each.key}"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = local.scaling_target.service_namespace
  scalable_dimension = local.scaling_target.scalable_dimension
  resource_id        = local.scaling_target.resource_id

  target_tracking_scaling_policy_configuration {
    target_value       = each.value.target
    scale_in_cooldown  = 300
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = each.value.metric
      resource_label         = each.value.label
    }
  }
}
