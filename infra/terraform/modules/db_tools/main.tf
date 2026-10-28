# Outils PostgreSQL pour une instance PARTAGÉE (hébergement mutualisé) : Eventide n'a pas le
# compte maître de l'instance de CINAF ; il n'en a besoin qu'une fois, pour l'amorçage.
# Repris de Candidature Express (modules/db_tools), à l'identique sauf les noms : variables
# EV_*, marqueur de propriété 'eventide' sur nos rôles, base de test eventide_restore.
#
#   <name>-db-bootstrap     amorçage (base, rôles, limites de connexions, délais, droits) avec
#                           le mot de passe maître lu dans un secret TEMPORAIRE créé puis
#                           supprimé par le product owner ; mots de passe des rôles envoyés
#                           sous forme de vérificateurs SCRAM (jamais en clair) ; arrêt sur un
#                           rôle du même nom non créé par nous ; nettoyage en cas d'échec.
#   <name>-db-backup        sauvegarde logique quotidienne (pg_dump -> S3), planifiée sur
#                           Fargate Spot, avec le rôle en lecture seule <backup>.
#   <name>-db-restore-test  test de restauration dans la base temporaire <restore_db> de la
#                           même instance, comparaison avec la source, puis nettoyage.
#
# Chaque tâche partage un volume de travail éphémère entre ses conteneurs : « init »
# (droits du volume), puis les outils (client PostgreSQL 16 = version majeure de l'instance,
# AWS CLI, Python pour SCRAM), tous en système de fichiers racine en lecture seule,
# capacités Linux retirées, images publiques épinglées par empreinte. Les scripts sont dans
# files/ et testés contre PostgreSQL 16 (tests/run-local.sh, CI Infra).

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  region     = data.aws_region.current.region
  account_id = data.aws_caller_identity.current.account_id

  families = {
    bootstrap = "${var.name}-db-bootstrap"
    backup    = "${var.name}-db-backup"
    restore   = "${var.name}-db-restore-test"
  }

  bucket_name   = "${var.name}-db-backups-${local.account_id}"
  backup_prefix = var.db_name

  master_secret_arn_pattern = "arn:aws:secretsmanager:${local.region}:${local.account_id}:secret:${var.master_password_secret_name}-*"

  db_conn_limit = var.app_connection_limit + var.migrator_connection_limit + var.backup_connection_limit

  lib = file("${path.module}/files/lib.sh")

  common_linux_parameters = {
    initProcessEnabled = true
    capabilities       = { add = [], drop = ["ALL"] }
  }

  pg_environment = {
    PGHOST            = var.db_host
    PGPORT            = tostring(var.db_port)
    PGCONNECT_TIMEOUT = "15"
    PGSSLMODE         = "require" # remplacé par verify-full dès que le bundle RDS est vérifié
    RDS_CA_URL        = var.rds_ca_bundle_url
    RDS_CA_SHA256     = var.rds_ca_bundle_sha256
    WORK_DIR          = "/work"
    HOME              = "/work"
  }

  # Prépare le volume de travail (propriété root, 0755 à la création) pour les conteneurs
  # non-root qui suivent. Root sans aucune capacité : il ne peut modifier que ce répertoire.
  init_container = {
    name                   = "init"
    image                  = var.postgres_image
    essential              = false
    readonlyRootFilesystem = true
    user                   = "0:0"
    entryPoint             = ["sh", "-c"]
    command                = ["chmod 1777 /work && touch /work/init.ok"]
    mountPoints            = [{ sourceVolume = "work", containerPath = "/work", readOnly = false }]
    linuxParameters        = local.common_linux_parameters
  }

  roles = {
    app      = var.app_role
    migrator = var.migrator_role
    backup   = var.backup_role
  }

  timeouts_environment = {
    EV_APP_STATEMENT_TIMEOUT      = var.role_timeouts.app.statement
    EV_APP_LOCK_TIMEOUT           = var.role_timeouts.app.lock
    EV_APP_IDLE_TX_TIMEOUT        = var.role_timeouts.app.idle_in_transaction
    EV_MIGRATOR_STATEMENT_TIMEOUT = var.role_timeouts.migrator.statement
    EV_MIGRATOR_LOCK_TIMEOUT      = var.role_timeouts.migrator.lock
    EV_MIGRATOR_IDLE_TX_TIMEOUT   = var.role_timeouts.migrator.idle_in_transaction
    EV_BACKUP_STATEMENT_TIMEOUT   = var.role_timeouts.backup.statement
    EV_BACKUP_LOCK_TIMEOUT        = var.role_timeouts.backup.lock
    EV_BACKUP_IDLE_TX_TIMEOUT     = var.role_timeouts.backup.idle_in_transaction
  }

  # Per-role resource caps on the shared instance (variables.tf, role_resource_limits).
  resource_limits_environment = merge([
    for key, prefix in { app = "EV_APP", migrator = "EV_MIGRATOR", backup = "EV_BACKUP" } : {
      "${prefix}_WORK_MEM"             = var.role_resource_limits[key].work_mem
      "${prefix}_MAINTENANCE_WORK_MEM" = var.role_resource_limits[key].maintenance_work_mem
      "${prefix}_TEMP_FILE_LIMIT"      = var.role_resource_limits[key].temp_file_limit
      "${prefix}_IDLE_SESSION_TIMEOUT" = var.role_resource_limits[key].idle_session_timeout
    }
  ]...)

  identity_environment = {
    EV_DB_NAME             = var.db_name
    EV_RESTORE_DB_NAME     = var.restore_db_name
    EV_APP_ROLE            = var.app_role
    EV_MIGRATOR_ROLE       = var.migrator_role
    EV_BACKUP_ROLE         = var.backup_role
    EV_MASTER_USER         = var.master_username
    EV_MASTER_DATABASE     = var.master_database
    EV_APP_CONN_LIMIT      = tostring(var.app_connection_limit)
    EV_MIGRATOR_CONN_LIMIT = tostring(var.migrator_connection_limit)
    EV_BACKUP_CONN_LIMIT   = tostring(var.backup_connection_limit)
    EV_DB_CONN_LIMIT       = tostring(local.db_conn_limit)
    EV_RESTORE_CONN_LIMIT  = tostring(var.restore_connection_limit)
  }

  log_options = {
    for k, v in local.families : k => {
      awslogs-group         = var.jobs_log_group_name
      awslogs-region        = local.region
      awslogs-stream-prefix = "db-${k}"
    }
  }
}

check "postgres_client_matches_server" {
  assert {
    condition     = startswith(var.db_engine_version, "${var.postgres_major_version}.")
    error_message = "L'instance partagée est en PostgreSQL ${var.db_engine_version} mais les outils utilisent le client ${var.postgres_major_version} : mettre à jour postgres_image et postgres_major_version (pg_dump doit être de la même version majeure)."
  }
}

# --- Bucket des sauvegardes ---------------------------------------------------------------------

resource "aws_s3_bucket" "backups" {
  bucket        = local.bucket_name
  force_destroy = var.force_destroy
}

resource "aws_s3_bucket_ownership_controls" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

# SSE-KMS avec la clé de l'environnement : la règle de refus de la clé empêche les autres
# applications du compte de lire les sauvegardes, même avec s3:GetObject.
resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    id     = "expire-backups"
    status = "Enabled"
    filter {}
    expiration {
      days = var.backup_retention_days
    }
    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_retention_days
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  rule {
    id     = "remove-expired-delete-markers"
    status = "Enabled"
    filter {}
    expiration {
      expired_object_delete_marker = true
    }
  }

  depends_on = [aws_s3_bucket_versioning.backups]
}

data "aws_iam_policy_document" "bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.backups.arn, "${aws_s3_bucket.backups.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # Sans en-tête de chiffrement : chiffrement par défaut du bucket (notre clé, ci-dessus). Avec
  # en-tête : notre clé seule. Un opérateur négatif (StringNotEquals) vaut VRAI quand la clé de
  # condition est absente de la requête : sans la condition Null = false, ces refus
  # bloqueraient l'envoi sans en-tête de backup_upload.sh et chaque UploadPart d'un envoi en
  # plusieurs parties (qui ne porte jamais ces en-têtes).
  statement {
    sid       = "DenyForeignKmsKey"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.backups.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Null"
      variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
      values   = ["false"]
    }
    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
      values   = [var.kms_key_arn]
    }
  }

  # En-tête x-amz-server-side-encryption sans clé désignée : S3 prendrait SSE-S3 (AES256) ou la
  # clé gérée aws/s3, lisibles par tout principal du compte qui a s3:GetObject.
  statement {
    sid       = "DenyEncryptionHeaderWithoutOurKey"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.backups.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Null"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["false"]
    }
    condition {
      test     = "Null"
      variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
      values   = ["true"]
    }
  }
}

resource "aws_s3_bucket_policy" "backups" {
  bucket     = aws_s3_bucket.backups.id
  policy     = data.aws_iam_policy_document.bucket.json
  depends_on = [aws_s3_bucket_public_access_block.backups]
}

# --- IAM ------------------------------------------------------------------------------------------

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

locals {
  # Rôles d'exécution : journaux et SEULS les secrets de la tâche (images publiques : pas d'ECR).
  execution_secrets = {
    bootstrap = [var.db_secret_arns["app"], var.db_secret_arns["migrator"], var.db_secret_arns["backup"], local.master_secret_arn_pattern]
    backup    = [var.db_secret_arns["backup"]]
    restore   = [var.db_secret_arns["migrator"]]
  }
}

resource "aws_iam_role" "execution" {
  for_each           = local.families
  name               = "${var.name}-db-${each.key}-execution"
  description        = "Role d'execution ECS de la tache ${each.value} : journaux et ses propres secrets"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "execution" {
  for_each = local.families

  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:${local.region}:${local.account_id}:log-group:${var.jobs_log_group_name}:log-stream:db-${each.key}/*"]
  }

  statement {
    sid       = "OwnSecretsOnly"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = local.execution_secrets[each.key]
  }

  statement {
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

resource "aws_iam_role_policy" "execution" {
  for_each = local.families
  name     = "execution"
  role     = aws_iam_role.execution[each.key].id
  policy   = data.aws_iam_policy_document.execution[each.key].json
}

# Rôles de tâche : écriture (sauvegarde) ou lecture (restauration) du bucket, rien d'autre.
resource "aws_iam_role" "task" {
  for_each           = { backup = local.families.backup, restore = local.families.restore }
  name               = "${var.name}-db-${each.key}-task"
  description        = "Role de la tache ${each.value} : bucket des sauvegardes uniquement"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "backup_task" {
  statement {
    sid       = "WriteBackups"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.backups.arn}/${local.backup_prefix}/*"]
  }

  statement {
    sid       = "EncryptBackups"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [var.kms_key_arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${local.region}.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "restore_task" {
  statement {
    sid       = "ListBackups"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.backups.arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${local.backup_prefix}/*"]
    }
  }

  statement {
    sid       = "ReadBackups"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.backups.arn}/${local.backup_prefix}/*"]
  }

  statement {
    sid       = "DecryptBackups"
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${local.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "backup_task" {
  name   = "write-backups"
  role   = aws_iam_role.task["backup"].id
  policy = data.aws_iam_policy_document.backup_task.json
}

resource "aws_iam_role_policy" "restore_task" {
  name   = "read-backups"
  role   = aws_iam_role.task["restore"].id
  policy = data.aws_iam_policy_document.restore_task.json
}

# --- Définitions de tâche ----------------------------------------------------------------------

resource "aws_ecs_task_definition" "bootstrap" {
  family                   = local.families.bootstrap
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution["bootstrap"].arn

  container_definitions = jsonencode([
    merge(local.init_container, {
      logConfiguration = { logDriver = "awslogs", options = local.log_options.bootstrap }
    }),
    {
      name                   = "scram"
      image                  = var.python_image
      essential              = false
      readonlyRootFilesystem = true
      user                   = "70:70"
      dependsOn              = [{ containerName = "init", condition = "COMPLETE" }]
      entryPoint             = ["python", "-I", "-c"]
      command                = [file("${path.module}/files/scram_verifiers.py")]
      environment = [
        { name = "EV_SCRAM_ROLES", value = "app=APP_DB_PASSWORD,migrator=MIGRATOR_DB_PASSWORD,backup=BACKUP_DB_PASSWORD" },
        { name = "WORK_DIR", value = "/work" },
      ]
      secrets = [
        { name = "APP_DB_PASSWORD", valueFrom = "${var.db_secret_arns["app"]}:password::" },
        { name = "BACKUP_DB_PASSWORD", valueFrom = "${var.db_secret_arns["backup"]}:password::" },
        { name = "MIGRATOR_DB_PASSWORD", valueFrom = "${var.db_secret_arns["migrator"]}:password::" },
      ]
      mountPoints      = [{ sourceVolume = "work", containerPath = "/work", readOnly = false }]
      linuxParameters  = local.common_linux_parameters
      logConfiguration = { logDriver = "awslogs", options = local.log_options.bootstrap }
    },
    {
      name                   = "bootstrap"
      image                  = var.postgres_image
      essential              = true
      readonlyRootFilesystem = true
      user                   = "70:70"
      dependsOn              = [{ containerName = "scram", condition = "COMPLETE" }]
      entryPoint             = ["sh", "-c"]
      command                = [join("\n", [local.lib, file("${path.module}/files/bootstrap.sh")])]
      environment = [for k, v in merge(local.pg_environment, local.identity_environment, local.timeouts_environment, local.resource_limits_environment, {
        PGAPPNAME                = "${var.name}-db-bootstrap"
        EV_SQL_BOOTSTRAP         = file("${path.module}/files/bootstrap.sql")
        EV_SQL_BOOTSTRAP_CLEANUP = file("${path.module}/files/bootstrap_cleanup.sql")
        EV_SQL_GRANTS            = file("${path.module}/files/grants.sql")
      }) : { name = k, value = v }]
      secrets = [
        { name = "EV_MASTER_PASSWORD", valueFrom = local.master_secret_arn_pattern_ref },
        { name = "MIGRATOR_DB_PASSWORD", valueFrom = "${var.db_secret_arns["migrator"]}:password::" },
      ]
      mountPoints      = [{ sourceVolume = "work", containerPath = "/work", readOnly = false }]
      linuxParameters  = local.common_linux_parameters
      logConfiguration = { logDriver = "awslogs", options = local.log_options.bootstrap }
    },
  ])

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }

  volume {
    name = "work"
  }
}

locals {
  # Secret temporaire désigné par son nom (ARN partiel, sans suffixe aléatoire) : il n'existe
  # que le temps de l'amorçage (créé puis supprimé par le product owner).
  master_secret_arn_pattern_ref = "arn:aws:secretsmanager:${local.region}:${local.account_id}:secret:${var.master_password_secret_name}"
}

resource "aws_ecs_task_definition" "backup" {
  family                   = local.families.backup
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution["backup"].arn
  task_role_arn            = aws_iam_role.task["backup"].arn

  container_definitions = jsonencode([
    merge(local.init_container, {
      logConfiguration = { logDriver = "awslogs", options = local.log_options.backup }
    }),
    {
      name                   = "dump"
      image                  = var.postgres_image
      essential              = false
      readonlyRootFilesystem = true
      user                   = "70:70"
      dependsOn              = [{ containerName = "init", condition = "COMPLETE" }]
      entryPoint             = ["sh", "-c"]
      command                = [join("\n", [local.lib, file("${path.module}/files/backup_dump.sh")])]
      environment = [for k, v in merge(local.pg_environment, {
        PGDATABASE = var.db_name
        PGUSER     = var.backup_role
        PGAPPNAME  = "${var.name}-db-backup"
      }) : { name = k, value = v }]
      secrets          = [{ name = "PGPASSWORD", valueFrom = "${var.db_secret_arns["backup"]}:password::" }]
      mountPoints      = [{ sourceVolume = "work", containerPath = "/work", readOnly = false }]
      linuxParameters  = local.common_linux_parameters
      logConfiguration = { logDriver = "awslogs", options = local.log_options.backup }
    },
    {
      name                   = "upload"
      image                  = var.aws_cli_image
      essential              = true
      readonlyRootFilesystem = true
      user                   = "65534:65534"
      dependsOn              = [{ containerName = "dump", condition = "COMPLETE" }]
      entryPoint             = ["/bin/sh", "-c"]
      command                = [join("\n", [local.lib, file("${path.module}/files/backup_upload.sh")])]
      environment = [for k, v in {
        BACKUP_BUCKET      = aws_s3_bucket.backups.id
        BACKUP_PREFIX      = local.backup_prefix
        EV_DB_NAME         = var.db_name
        WORK_DIR           = "/work"
        HOME               = "/work"
        AWS_REGION         = local.region
        AWS_DEFAULT_REGION = local.region
      } : { name = k, value = v }]
      mountPoints      = [{ sourceVolume = "work", containerPath = "/work", readOnly = false }]
      linuxParameters  = local.common_linux_parameters
      logConfiguration = { logDriver = "awslogs", options = local.log_options.backup }
    },
  ])

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }

  volume {
    name = "work"
  }
}

resource "aws_ecs_task_definition" "restore" {
  family                   = local.families.restore
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution["restore"].arn
  task_role_arn            = aws_iam_role.task["restore"].arn

  container_definitions = jsonencode([
    merge(local.init_container, {
      logConfiguration = { logDriver = "awslogs", options = local.log_options.restore }
    }),
    {
      name                   = "download"
      image                  = var.aws_cli_image
      essential              = false
      readonlyRootFilesystem = true
      user                   = "65534:65534"
      dependsOn              = [{ containerName = "init", condition = "COMPLETE" }]
      entryPoint             = ["/bin/sh", "-c"]
      command                = [join("\n", [local.lib, file("${path.module}/files/restore_download.sh")])]
      environment = [for k, v in {
        BACKUP_BUCKET      = aws_s3_bucket.backups.id
        BACKUP_PREFIX      = local.backup_prefix
        WORK_DIR           = "/work"
        HOME               = "/work"
        AWS_REGION         = local.region
        AWS_DEFAULT_REGION = local.region
      } : { name = k, value = v }]
      mountPoints      = [{ sourceVolume = "work", containerPath = "/work", readOnly = false }]
      linuxParameters  = local.common_linux_parameters
      logConfiguration = { logDriver = "awslogs", options = local.log_options.restore }
    },
    {
      name                   = "restore"
      image                  = var.postgres_image
      essential              = true
      readonlyRootFilesystem = true
      user                   = "70:70"
      dependsOn              = [{ containerName = "download", condition = "COMPLETE" }]
      entryPoint             = ["sh", "-c"]
      command                = [join("\n", [local.lib, file("${path.module}/files/restore_test.sh")])]
      environment = [for k, v in merge(local.pg_environment, {
        EV_DB_NAME         = var.db_name
        EV_RESTORE_DB_NAME = var.restore_db_name
        EV_MIGRATOR_ROLE   = var.migrator_role
        PGAPPNAME          = "${var.name}-db-restore-test"
        EV_SQL_COUNT       = file("${path.module}/files/count_rows.sql")
      }) : { name = k, value = v }]
      secrets          = [{ name = "MIGRATOR_DB_PASSWORD", valueFrom = "${var.db_secret_arns["migrator"]}:password::" }]
      mountPoints      = [{ sourceVolume = "work", containerPath = "/work", readOnly = false }]
      linuxParameters  = local.common_linux_parameters
      logConfiguration = { logDriver = "awslogs", options = local.log_options.restore }
    },
  ])

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }

  volume {
    name = "work"
  }
}

# --- Alerte « aucune sauvegarde réussie depuis 24 h » -------------------------------------------
# Chaque envoi réussi écrit l'événement db_backup_uploaded dans les journaux des tâches ; sans
# lui pendant une journée (tâche en échec, interrompue, planification désactivée), l'alarme
# se déclenche. Les échecs eux-mêmes sont aussi signalés par la règle « tâche en échec ».

resource "aws_cloudwatch_log_metric_filter" "backup_uploaded" {
  name           = "${var.name}-db-backup-uploaded"
  log_group_name = var.jobs_log_group_name
  pattern        = "{ $.event = \"db_backup_uploaded\" }"

  metric_transformation {
    name      = "DbBackupUploaded"
    namespace = var.metric_namespace
    value     = "1"
    unit      = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "backup_missing" {
  count               = var.backup_alarm_enabled ? 1 : 0
  alarm_name          = "${var.name}-db-backup-missing"
  alarm_description   = "Aucune sauvegarde logique de ${var.db_name} envoyee dans S3 depuis 24 h (tache ${local.families.backup}, journaux ${var.jobs_log_group_name}, flux db-backup/*)."
  namespace           = var.metric_namespace
  metric_name         = "DbBackupUploaded"
  statistic           = "Sum"
  period              = 86400
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [var.alarm_topic_arn]
  ok_actions          = [var.alarm_topic_arn]

  depends_on = [aws_cloudwatch_log_metric_filter.backup_uploaded]
}
