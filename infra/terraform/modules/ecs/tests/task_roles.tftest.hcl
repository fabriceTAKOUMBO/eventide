# Rôles de tâche et famille media (tableau de bord, ADR § 12), sans AWS (fournisseur simulé) :
# droits EXACTS des rôles de tâche api et media (actions, ressources, conditions), uniquement sur
# NOS ressources ; famille ev-<env>-media de 1 vCPU / 2 Go au plus ; secrets du rôle d'exécution
# media sans ADMIN_EMAILS ; migrate et jobs toujours sans rôle de tâche.
#   terraform init -backend=false && terraform test

mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { region = "us-east-1", name = "us-east-1" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "466494951409" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

variables {
  name                       = "ev-prod"
  vpc_id                     = "vpc-0fbfe87b34e2b3903"
  private_subnet_ids         = ["subnet-03bb1c6197c29a369", "subnet-0fcd9f10a65ed1a16"]
  alb_security_group_id      = "sg-04bbc536ff0295918"
  postgres_security_group_id = "sg-070b4372d5a95ad2d"
  api_service_enabled        = false
  ecr_repository_url         = "466494951409.dkr.ecr.us-east-1.amazonaws.com/ev-prod-api"
  ecr_repository_arn         = "arn:aws:ecr:us-east-1:466494951409:repository/ev-prod-api"
  image_tag                  = "bootstrap"
  api                        = { cpu = 256, memory = 512, min = 1, max = 2, requests = 600 }
  api_environment            = { DJANGO_SETTINGS_MODULE = "config.settings.prod" }
  api_secrets = {
    DJANGO_SECRET_KEY = "arn:aws:secretsmanager:us-east-1:466494951409:secret:eventide/prod/django-secret-key-AbCdEf"
    DATABASE_URL      = "arn:aws:secretsmanager:us-east-1:466494951409:secret:eventide/prod/db-app-GhIjKl:url::"
    ADMIN_EMAILS      = "arn:aws:secretsmanager:us-east-1:466494951409:secret:eventide/prod/admin-emails-MnOpQr"
  }
  migrate_environment = { DB_POOL_MAX_SIZE = "0" }
  migrate_secrets = {
    DATABASE_URL = "arn:aws:secretsmanager:us-east-1:466494951409:secret:eventide/prod/db-migrator-StUvWx:url::"
  }
  jobs_environment = { DB_POOL_MAX_SIZE = "0" }
  jobs_secrets = {
    DATABASE_URL = "arn:aws:secretsmanager:us-east-1:466494951409:secret:eventide/prod/db-app-GhIjKl:url::"
  }
  media_environment = { DB_POOL_MAX_SIZE = "0", MEDIA_STORAGE = "s3" }
  media_secrets = {
    DJANGO_SECRET_KEY = "arn:aws:secretsmanager:us-east-1:466494951409:secret:eventide/prod/django-secret-key-AbCdEf"
    DATABASE_URL      = "arn:aws:secretsmanager:us-east-1:466494951409:secret:eventide/prod/db-app-GhIjKl:url::"
  }
  content_bucket_arn = "arn:aws:s3:::ev-prod-content-466494951409"
  kms_key_arn        = "arn:aws:kms:us-east-1:466494951409:key/00000000-0000-0000-0000-000000000000"
}

run "api_task_role_signs_uploads_and_starts_media_tasks_only" {
  command = plan

  assert {
    condition = jsonencode(output.task_role_policies.api) == jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Sid      = "SignDashboardUploads"
          Effect   = "Allow"
          Action   = ["s3:PutObject"]
          Resource = ["arn:aws:s3:::ev-prod-content-466494951409/uploads/*"]
        },
        {
          Sid    = "StartMediaTasks"
          Effect = "Allow"
          Action = ["ecs:RunTask"]
          Resource = [
            "arn:aws:ecs:us-east-1:466494951409:task-definition/ev-prod-media",
            "arn:aws:ecs:us-east-1:466494951409:task-definition/ev-prod-media:*",
          ]
          Condition = {
            ArnEquals                     = { "ecs:cluster" = "arn:aws:ecs:us-east-1:466494951409:cluster/ev-prod" }
            NumericLessThanEqualsIfExists = { "ecs:task-cpu" = "1024", "ecs:task-memory" = "2048" }
          }
        },
        {
          Sid       = "TagMediaTasksAtLaunch"
          Effect    = "Allow"
          Action    = ["ecs:TagResource"]
          Resource  = ["arn:aws:ecs:us-east-1:466494951409:task/ev-prod/*"]
          Condition = { StringEquals = { "ecs:CreateAction" = "RunTask" } }
        },
        {
          Sid    = "PassMediaRolesToEcsOnly"
          Effect = "Allow"
          Action = ["iam:PassRole"]
          Resource = [
            "arn:aws:iam::466494951409:role/ev-prod-media-execution",
            "arn:aws:iam::466494951409:role/ev-prod-media-task",
          ]
          Condition = { StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" } }
        },
      ]
    })
    error_message = "Rôle de la tâche api : PutObject sur uploads/ ; RunTask sur ev-prod-media dans ev-prod ; étiquettes au lancement ; PassRole des seuls rôles media vers ECS. Rien d'autre."
  }
}

run "media_task_role_reads_uploads_and_writes_processed_media_only" {
  command = plan

  assert {
    condition = jsonencode(output.task_role_policies.media) == jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Sid      = "ReadUploadedSources"
          Effect   = "Allow"
          Action   = ["s3:GetObject"]
          Resource = ["arn:aws:s3:::ev-prod-content-466494951409/uploads/*"]
        },
        {
          Sid    = "WriteProcessedMedia"
          Effect = "Allow"
          Action = ["s3:PutObject"]
          Resource = [
            "arn:aws:s3:::ev-prod-content-466494951409/videos/paysages/*",
            "arn:aws:s3:::ev-prod-content-466494951409/images/paysages/*",
            "arn:aws:s3:::ev-prod-content-466494951409/audio/sons/*",
            "arn:aws:s3:::ev-prod-content-466494951409/audio/musiques/*",
          ]
        },
      ]
    })
    error_message = "Rôle de la tâche media : GetObject sur uploads/, PutObject sur les quatre préfixes du contenu ; ni List, ni Delete."
  }
  assert {
    condition = length(setintersection(
      toset(flatten([for p in values(output.task_role_policies) : [for s in p.Statement : s.Action]])),
      toset(["s3:ListBucket", "s3:DeleteObject", "s3:DeleteObjectVersion", "s3:*", "ecs:*", "iam:*", "*"]),
    )) == 0
    error_message = "Aucun droit de liste, de suppression ni joker dans les rôles de tâche."
  }
}

run "media_family_shape_and_roles" {
  command = plan

  assert {
    condition     = aws_ecs_task_definition.media.family == "ev-prod-media" && aws_ecs_task_definition.media.cpu == "1024" && aws_ecs_task_definition.media.memory == "2048"
    error_message = "Famille ev-prod-media, 1 vCPU / 2 Go."
  }
  assert {
    condition     = length(aws_ecs_task_definition.media.ephemeral_storage) == 0
    error_message = "Stockage éphémère par défaut (20 Gio)."
  }
  assert {
    condition = (
      aws_iam_role.task["api"].name == "ev-prod-api-task" &&
      aws_iam_role.task["media"].name == "ev-prod-media-task" &&
      aws_iam_role.execution["media"].name == "ev-prod-media-execution" &&
      length(aws_iam_role.task) == 2
    )
    error_message = "Rôles de tâche d'api et de media seulement, à nos noms ; rôle d'exécution propre à media."
  }
  assert {
    condition = (
      contains(keys(output.register_inputs.api), "taskRoleArn") &&
      contains(keys(output.register_inputs.media), "taskRoleArn") &&
      !contains(keys(output.register_inputs.migrate), "taskRoleArn") &&
      !contains(keys(output.register_inputs.jobs), "taskRoleArn")
    )
    error_message = "Modèles du registraire : rôle de tâche pour api et media seulement."
  }
  assert {
    condition     = output.register_inputs.media.family == "ev-prod-media" && output.register_inputs.media.cpu == "1024" && output.register_inputs.media.memory == "2048"
    error_message = "Modèle media du registraire identique à la révision Terraform."
  }
  assert {
    condition = (
      jsondecode(aws_ecs_task_definition.media.container_definitions)[0].name == "media" &&
      jsondecode(aws_ecs_task_definition.media.container_definitions)[0].command == ["python", "manage.py", "check"] &&
      jsondecode(aws_ecs_task_definition.media.container_definitions)[0].image == "466494951409.dkr.ecr.us-east-1.amazonaws.com/ev-prod-api:bootstrap" &&
      jsondecode(aws_ecs_task_definition.media.container_definitions)[0].readonlyRootFilesystem == true &&
      jsondecode(aws_ecs_task_definition.media.container_definitions)[0].user == "10001:10001"
    )
    error_message = "Conteneur media : image de l'API, commande par défaut manage.py check, racine en lecture seule, non-root."
  }
  assert {
    condition = (
      jsondecode(aws_ecs_task_definition.media.container_definitions)[0].logConfiguration.options.awslogs-group == "/ecs/ev-prod/jobs" &&
      jsondecode(aws_ecs_task_definition.media.container_definitions)[0].logConfiguration.options.awslogs-stream-prefix == "media"
    )
    error_message = "Journaux de media dans notre groupe /ecs/ev-prod/jobs (rétention de l'environnement), flux media/."
  }
  assert {
    condition     = output.task_families.media == "ev-prod-media" && output.container_names.media == "media"
    error_message = "Famille et conteneur publiés pour le déploiement."
  }
}

run "media_execution_role_reads_its_own_secrets_only" {
  command = plan

  assert {
    condition = jsonencode(output.execution_secret_arns.media) == jsonencode([
      "arn:aws:secretsmanager:us-east-1:466494951409:secret:eventide/prod/db-app-GhIjKl",
      "arn:aws:secretsmanager:us-east-1:466494951409:secret:eventide/prod/django-secret-key-AbCdEf",
    ])
    error_message = "Rôle d'exécution media : secret de la base (rôle applicatif) et clé Django."
  }
  assert {
    condition     = !contains(output.execution_secret_arns.media, "arn:aws:secretsmanager:us-east-1:466494951409:secret:eventide/prod/admin-emails-MnOpQr")
    error_message = "Le rôle d'exécution media ne lit pas ADMIN_EMAILS."
  }
  assert {
    condition     = contains(output.execution_secret_arns.api, "arn:aws:secretsmanager:us-east-1:466494951409:secret:eventide/prod/admin-emails-MnOpQr")
    error_message = "Le rôle d'exécution api lit ADMIN_EMAILS."
  }
}

run "media_task_above_1_vcpu_2_gb_is_refused" {
  command = plan

  variables {
    media = { cpu = 2048, memory = 4096 }
  }

  expect_failures = [var.media]
}

run "admin_emails_in_the_media_task_is_refused" {
  command = plan

  variables {
    media_secrets = {
      DATABASE_URL = "arn:aws:secretsmanager:us-east-1:466494951409:secret:eventide/prod/db-app-GhIjKl:url::"
      ADMIN_EMAILS = "arn:aws:secretsmanager:us-east-1:466494951409:secret:eventide/prod/admin-emails-MnOpQr"
    }
  }

  expect_failures = [var.media_secrets]
}

run "foreign_bucket_is_refused" {
  command = plan

  variables {
    content_bucket_arn = "arn:aws:s3:::cinaf-streaming-prod-media"
  }

  expect_failures = [var.content_bucket_arn]
}
