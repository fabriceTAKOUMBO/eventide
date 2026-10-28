# ECS Fargate d'Eventide : cluster propre, service "api" (Django, qui sert aussi les pages web
# du domaine), familles "migrate" (migrations, rôle ev_migrator) et "jobs" (tâches planifiées),
# dans les sous-réseaux privés « application » partagés. Définitions de tâche durcies (système
# de fichiers racine en lecture seule, utilisateur non-root, capacités Linux retirées, secrets
# depuis Secrets Manager), un rôle d'exécution par usage qui ne lit que SES secrets, et aucun
# rôle de tâche : l'API n'appelle aucune API AWS (les adresses CloudFront sont signées
# localement avec la clé injectée).
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

# Sorties : HTTPS (API Google : Play, Play Integrity, Gemini, certificats ; API AWS : ECR,
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
  }
}

resource "aws_iam_role" "execution" {
  for_each           = local.execution_roles
  name               = "${var.name}-${each.key}-execution"
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
}

# Shape of each family, shared by the Terraform revisions below and by the register inputs of
# the deploy (local.register_inputs).
locals {
  task_shapes = {
    api     = { cpu = var.api.cpu, memory = var.api.memory, container = local.api_container }
    migrate = { cpu = 256, memory = 512, container = local.migrate_container }
    jobs    = { cpu = 256, memory = 512, container = local.jobs_container }
  }

  # Exact input of ecs:RegisterTaskDefinition for each family, identical to the Terraform
  # revision (the deploy only replaces the image). The task registrar (modules/task_registrar)
  # registers new revisions from it: the deploy never reads a task definition
  # (ecs:DescribeTaskDefinition only accepts "*" and would expose the task definitions of
  # CINAF, JobMinutes and Candidature Express) and never names a family itself.
  register_inputs = {
    for key, shape in local.task_shapes : key => {
      family                  = "${var.name}-${key}"
      executionRoleArn        = aws_iam_role.execution[key].arn
      networkMode             = "awsvpc"
      requiresCompatibilities = ["FARGATE"]
      cpu                     = tostring(shape.cpu)
      memory                  = tostring(shape.memory)
      runtimePlatform         = { operatingSystemFamily = "LINUX", cpuArchitecture = var.cpu_architecture }
      volumes                 = [{ name = "tmp" }]
      containerDefinitions    = [shape.container]
    }
  }
}

resource "aws_ecs_task_definition" "api" {
  family                   = local.register_inputs.api.family
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = local.task_shapes.api.cpu
  memory                   = local.task_shapes.api.memory
  execution_role_arn       = aws_iam_role.execution["api"].arn
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
