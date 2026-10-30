# Un environnement Eventide en HÉBERGEMENT MUTUALISÉ, dans le compte AWS principal, à côté de
# CINAF, JobMinutes et Candidature Express, en réutilisant le VPC, les sous-réseaux privés
# « application », la NAT, l'ALB et l'instance PostgreSQL de CINAF, sans jamais modifier leurs
# ressources (docs/infra/hebergement-mutualise.md). Modèle : modules/shared_platform de
# Candidature Express.
#
# Ressources propres (créées ici) : clé KMS alias/ev-<env>, dépôt ECR, cluster ECS (service api),
# groupe de sécurité, secrets eventide/<env>/*, groupe cible, certificat, enregistrements DNS dans
# NOTRE zone, base et rôles PostgreSQL (par tâche d'amorçage), sauvegardes logiques, contenu
# (S3 + CloudFront + clé de signature), alarmes et sujet SNS, tâches planifiées, registraire des
# définitions de tâche (Lambda), rôle de déploiement GitHub.
#
# Ajouts sur des ressources partagées (points de contact, détaillés et réversibles) :
#   1. règles d'écouteur sur le 443 de l'ALB partagé (priorités 400-409 ; 420-429 en
#      préproduction), par nom d'hôte ;
#   2. certificat ACM ajouté à la liste de l'écouteur (aws_lb_listener_certificate) ;
#   3. une règle d'entrée 5432 sur le groupe de sécurité de la base, depuis NOTRE groupe ;
#   4. une base, trois rôles et une base de test de restauration sur l'instance (amorçage).
# Rien d'autre : ni action par défaut de l'écouteur, ni attributs de l'ALB, ni paramètres RDS,
# ni NAT, ni tables de routage, ni fournisseur OIDC (seulement référencé).
#
# Sans domaine (domain = "", marque à vérifier), l'entrée publique n'existe pas : ni certificat,
# ni règles d'écouteur, ni DNS, ni groupe cible, ni service api ; tout le reste est créé
# (base, contenu, image, tâches), ce qui ne pose QUE les points de contact 3 et 4.
#
# Tableau de bord (30 octobre 2026, ADR § 12) : servi par le service api sur les hôtes web
# EXISTANTS (/tableau/, règle 401) ; envoi direct des fichiers sources du navigateur vers NOTRE
# bucket de contenu (CORS), traitement par la famille ev-<env>-media lancée par l'API, secret
# ADMIN_EMAILS. Aucun nouveau point de contact avec une ressource de CINAF.

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  name          = "ev-${var.environment}"
  secret_prefix = "eventide/${var.environment}"
  ssm_prefix    = "/eventide/${var.environment}"
  region        = data.aws_region.current.region
  account_id    = data.aws_caller_identity.current.account_id

  ingress_enabled = var.domain != ""
  api_hostname    = local.ingress_enabled ? "api.${var.hostname_suffix}" : ""
  web_hostnames   = local.ingress_enabled ? var.web_hostnames : []
  public_web_url  = local.ingress_enabled ? "https://${var.web_hostnames[0]}" : "https://eventide.invalid"
  api_url         = local.ingress_enabled ? "https://${local.api_hostname}" : ""

  # Budget de connexions PostgreSQL : le pool de chaque worker gunicorn borne les connexions
  # d'une tâche ; un déploiement peut doubler les tâches (deployment_maximum_percent). Chaque
  # tâche media en cours ouvre une connexion du rôle applicatif (sans pool).
  connections_per_api_task = var.api.workers * var.api.db_pool_max
  deployment_surge         = ceil(var.deployment_maximum_percent / 100)
  media_connections        = var.media_task_concurrency * 1
  app_connections_needed   = var.api.max * local.connections_per_api_task * local.deployment_surge + var.app_connection_reserve + local.media_connections
  total_connection_limit   = var.db_role_connection_limits.app + var.db_role_connection_limits.migrator + var.db_role_connection_limits.backup

  # Dashboard (contract § 14): the media family is started by the API by NAME (the latest
  # revision registered by the deploy), in our cluster, our subnets and our security group (the
  # same as the jobs tasks: the media task reaches the database exactly like them).
  media_family = "${local.name}-media"

  # Keep-alive de gunicorn au-delà du délai d'inactivité de l'ALB partagé (502 sinon).
  keep_alive_seconds = local.ingress_enabled ? max(75, module.alb[0].idle_timeout + 5) : 75
}

# Le plan échoue si l'autoscaling (et le chevauchement d'un déploiement) peut ouvrir plus de
# connexions que la limite du rôle applicatif, ou si les limites des rôles dépassent le budget
# accordé sur l'instance partagée.
resource "terraform_data" "connection_budget" {
  input = local.total_connection_limit

  lifecycle {
    precondition {
      condition     = local.app_connections_needed <= var.db_role_connection_limits.app
      error_message = "Connexions possibles du rôle applicatif (${local.app_connections_needed} = ${var.api.max} tâches api x ${var.api.workers} worker(s) x pool ${var.api.db_pool_max} x ${local.deployment_surge} (déploiement) + ${var.app_connection_reserve} (tâches planifiées) + ${local.media_connections} (tâches media)) au-delà de sa limite ${var.db_role_connection_limits.app} : réduire api.max, workers ou db_pool_max."
    }
    precondition {
      condition     = local.total_connection_limit <= var.db_connection_budget
      error_message = "Somme des limites des rôles (${local.total_connection_limit}) au-delà du budget ${var.db_connection_budget} accordé sur l'instance partagée."
    }
  }
}

# Shared account capacity: the Fargate vCPU quota is account-wide (CINAF, JobMinutes,
# Candidature Express). The plan fails if this environment could hold more than its vCPU budget
# at its peak: every api task during a deployment (max x surge) plus three one-off tasks
# (migration, scheduled job, backup) of 0.25 vCPU, plus the media tasks that may run at once
# (dashboard processing, media_task_concurrency x media_task.cpu).
locals {
  peak_fargate_vcpu = (var.api.max * local.deployment_surge * var.api.cpu + 3 * 256 + var.media_task_concurrency * var.media_task.cpu) / 1024
}

resource "terraform_data" "shared_capacity_budget" {
  input = local.peak_fargate_vcpu

  lifecycle {
    precondition {
      condition     = local.peak_fargate_vcpu <= var.fargate_vcpu_budget
      error_message = "Pic de vCPU Fargate de l'environnement (${local.peak_fargate_vcpu} = ${var.api.max} tâches api x ${local.deployment_surge} (déploiement) x ${var.api.cpu / 1024} vCPU + 3 tâches ponctuelles x 0,25 + ${var.media_task_concurrency} tâche(s) media x ${var.media_task.cpu / 1024}) au-delà du budget ${var.fargate_vcpu_budget} vCPU : le quota Fargate est commun à tout le compte (CINAF, JobMinutes, Candidature Express). Réduire, ou relever le budget après accord du product owner et lecture du quota."
    }
  }
}

# --- Socle ---------------------------------------------------------------------------------------

module "kms" {
  source                         = "../kms"
  name                           = local.name
  decrypt_allowed_principal_arns = var.kms_decrypt_allowed_principal_arns
}

module "ecr" {
  source       = "../ecr"
  name         = local.name
  force_delete = var.force_destroy
}

resource "aws_ssm_parameter" "image_tag" {
  name        = "${local.ssm_prefix}/deploy/image-tag"
  description = "SHA du commit deploye (ecrit par .github/workflows/deploy.yml)"
  type        = "String"
  value       = "bootstrap"

  lifecycle {
    ignore_changes = [value]
  }
}

module "secrets" {
  source = "../secrets"

  secret_prefix        = local.secret_prefix
  kms_key_arn          = module.kms.key_arn
  recovery_window_days = var.secret_recovery_window_days
  db_host              = var.rds.address
  db_port              = var.rds.port
  db_name              = var.db_name
  db_roles             = var.db_roles
  manual_secrets = {
    "google-play-service-account" = "GOOGLE_PLAY_SERVICE_ACCOUNT_JSON : cle JSON du compte de service lie a la Play Console (API Play Developer et Play Integrity), deposee par le product owner"
    # Dashboard administrators (contract § 14). Placeholder A_REMPLACER = nobody is admin until
    # the product owner fills it (runbook tableau-de-bord.md). Injected into the api task only.
    "admin-emails" = "ADMIN_EMAILS : adresses Google des administrateurs du tableau de bord (separees par des virgules), deposees par le product owner"
  }
}

# --- Entrée publique : ajouts sur l'ALB partagé (seulement avec un domaine) ------------------------

module "dns" {
  count  = local.ingress_enabled ? 1 : 0
  source = "../dns_certs"

  zone_id             = var.zone_id
  zone_name           = var.domain
  certificate_domains = concat([local.api_hostname], local.web_hostnames)
  caa_issuers         = var.manage_caa ? ["amazon.com", "amazontrust.com", "awstrust.com", "amazonaws.com"] : []
}

module "alb" {
  count  = local.ingress_enabled ? 1 : 0
  source = "../alb"

  name                     = local.name
  vpc_id                   = var.vpc_id
  https_listener_arn       = var.https_listener_arn
  domain                   = var.domain
  listener_rule_priorities = var.listener_rule_priorities
  api_hostname             = local.api_hostname
  web_hostnames            = local.web_hostnames
  certificate_arn          = module.dns[0].certificate_arn
  zone_id                  = var.zone_id
}

# Point de contact n° 3 : entrée PostgreSQL sur le groupe de sécurité de l'instance partagée,
# depuis le seul groupe de NOS tâches. Règle autonome : les règles de CINAF, JobMinutes et
# Candidature Express ne sont pas touchées. Retrait : terraform destroy -target de cette ressource.
resource "aws_vpc_security_group_ingress_rule" "shared_postgres" {
  security_group_id            = var.rds.security_group_id
  description                  = "Eventide ${var.environment} - taches api, migrations, sauvegardes"
  ip_protocol                  = "tcp"
  from_port                    = var.rds.port
  to_port                      = var.rds.port
  referenced_security_group_id = module.ecs.api_security_group_id

  tags = { Name = "${local.name}-postgres" }

  # Standalone rule: PostgreSQL port only, source = OUR task security group only (never a CIDR,
  # a prefix list or another group), on the database's own security group.
  lifecycle {
    precondition {
      condition     = var.rds.port == 5432
      error_message = "Règle d'entrée sur le groupe de la base partagée : port 5432 seulement (lu : ${var.rds.port})."
    }
  }
}

# --- Contenu (S3 privé + CloudFront + adresses signées) -----------------------------------------

module "content" {
  source = "../content_cdn"

  name                        = local.name
  account_id                  = local.account_id
  secret_prefix               = local.secret_prefix
  kms_key_arn                 = module.kms.key_arn
  secret_recovery_window_days = var.secret_recovery_window_days
  domain_name                 = local.ingress_enabled && var.content_custom_domain ? "cdn.${var.hostname_suffix}" : ""
  zone_id                     = var.zone_id
  force_destroy               = var.force_destroy
  alarm_topic_arn             = module.observability.alerts_topic_arn
  budget_enabled              = var.content_budget_enabled
  budget_limit_usd            = var.content_budget_usd
  budget_emails               = var.budget_emails

  # Dashboard uploads (presigned POST from the browser): our web origins only, none without a
  # domain (no dashboard then).
  cors_allowed_origins = [for h in local.web_hostnames : "https://${h}"]
}

# --- Application ---------------------------------------------------------------------------------

locals {
  # Dashboard integration (contract with the backend, ADR § 12): same names in the api service,
  # the scheduled tasks and the media task. Never empty, hence kept out of the filtered map below
  # (whose "!= ''" filter turns the whole map unknown as soon as one value is unknown at plan
  # time): each value stays readable in the plan and in the tests.
  dashboard_environment = merge(
    {
      CONTENT_BUCKET             = module.content.bucket_name
      CONTENT_BUCKET_REGION      = local.region
      MEDIA_STORAGE              = "s3"
      MEDIA_TASK_CLUSTER         = module.ecs.cluster_name
      MEDIA_TASK_DEFINITION      = local.media_family
      MEDIA_TASK_CONTAINER       = "media"
      MEDIA_TASK_SUBNETS         = join(",", var.app_subnet_ids)
      MEDIA_TASK_SECURITY_GROUPS = module.ecs.api_security_group_id
    },
    var.google_web_client_id != "" ? { GOOGLE_WEB_CLIENT_ID = var.google_web_client_id } : {},
  )

  api_environment = merge({ for k, v in merge(
    {
      DJANGO_SETTINGS_MODULE     = "config.settings.prod"
      DJANGO_READ_DOT_ENV        = "false"
      ALLOWED_HOSTS              = local.ingress_enabled ? join(",", concat([local.api_hostname], local.web_hostnames)) : "localhost"
      PUBLIC_WEB_BASE_URL        = local.public_web_url
      NUM_PROXIES                = "1"
      DB_POOL_MAX_SIZE           = tostring(var.api.db_pool_max)
      PLAY_PACKAGE_NAME          = var.play_package_name
      ANDROID_CERT_FINGERPRINTS  = join(",", var.android_cert_fingerprints)
      PLAY_INTEGRITY_ENFORCED    = "true"
      GOOGLE_OAUTH_CLIENT_IDS    = join(",", var.google_oauth_client_ids)
      RTDN_AUDIENCE              = var.rtdn_audience != "" ? var.rtdn_audience : (local.ingress_enabled ? "${local.api_url}/v1/play/rtdn" : "")
      RTDN_SERVICE_ACCOUNT_EMAIL = var.rtdn_service_account_email
      CONTENT_BASE_URL           = module.content.content_base_url
      CLOUDFRONT_KEY_PAIR_ID     = module.content.key_pair_id
      LEGAL_PUBLISHER_NAME       = var.legal_publisher_name
      LEGAL_CONTACT_EMAIL        = var.legal_contact_email
      LOG_LEVEL                  = "INFO"
      # Connexions PostgreSQL par tâche = workers x pool : liées au budget (connection_budget).
      WEB_CONCURRENCY   = tostring(var.api.workers)
      GUNICORN_CMD_ARGS = "--worker-class gthread --threads ${var.api.threads} --timeout 30 --graceful-timeout 25 --keep-alive ${local.keep_alive_seconds} --max-requests 2000 --max-requests-jitter 200 --worker-tmp-dir /tmp --no-control-socket --access-logfile - --access-logformat '%(h)s %(t)s \"%(m)s %(U)s %(H)s\" %(s)s %(b)s %(L)s' --error-logfile - --log-level info"
    },
    var.api_extra_environment,
  ) : k => v if v != "" }, local.dashboard_environment)

  api_secrets = {
    DJANGO_SECRET_KEY                = module.secrets.django_secret_key_arn
    DATABASE_URL                     = "${module.secrets.db_secret_arns["app"]}:url::"
    GOOGLE_PLAY_SERVICE_ACCOUNT_JSON = module.secrets.manual_secret_arns["google-play-service-account"]
    CLOUDFRONT_PRIVATE_KEY           = module.content.private_key_secret_arn
    # Dashboard administrators: the api service only (never migrate, jobs or media).
    ADMIN_EMAILS = module.secrets.manual_secret_arns["admin-emails"]
  }

  # Migrations : rôle propriétaire, sans aucun secret Google ni CloudFront ; pas de pool.
  migrate_environment = merge(local.api_environment, { DB_POOL_MAX_SIZE = "0" })
  migrate_secrets = {
    DJANGO_SECRET_KEY = module.secrets.django_secret_key_arn
    DATABASE_URL      = "${module.secrets.db_secret_arns["migrator"]}:url::"
  }

  # Tâches planifiées (purge, finalisation des achats) : rôle applicatif, compte de service Google.
  jobs_environment = merge(local.api_environment, { DB_POOL_MAX_SIZE = "0" })
  jobs_secrets = {
    DJANGO_SECRET_KEY                = module.secrets.django_secret_key_arn
    DATABASE_URL                     = "${module.secrets.db_secret_arns["app"]}:url::"
    GOOGLE_PLAY_SERVICE_ACCOUNT_JSON = module.secrets.manual_secret_arns["google-play-service-account"]
  }

  # Media processing (dashboard): application role, no pool (one short connection per task).
  # It runs ffmpeg on files uploaded from a browser: only the database and the Django key, never
  # ADMIN_EMAILS, the Google Play key (the task calls no Google API) nor the CloudFront key.
  media_environment = merge(local.api_environment, { DB_POOL_MAX_SIZE = "0" })
  media_secrets = {
    DJANGO_SECRET_KEY = module.secrets.django_secret_key_arn
    DATABASE_URL      = "${module.secrets.db_secret_arns["app"]}:url::"
  }
}

module "ecs" {
  source = "../ecs"

  name                         = local.name
  vpc_id                       = var.vpc_id
  private_subnet_ids           = var.app_subnet_ids
  alb_security_group_id        = var.alb_security_group_id
  postgres_security_group_id   = var.rds.security_group_id
  postgres_port                = var.rds.port
  api_service_enabled          = local.ingress_enabled
  target_group_arn             = local.ingress_enabled ? module.alb[0].target_group_arn : null
  request_count_resource_label = local.ingress_enabled ? "${module.alb[0].arn_suffix}/${module.alb[0].target_group_arn_suffix}" : null
  ecr_repository_url           = module.ecr.repository_urls["api"]
  ecr_repository_arn           = module.ecr.repository_arns["api"]
  image_tag                    = nonsensitive(aws_ssm_parameter.image_tag.value)
  cpu_architecture             = var.cpu_architecture
  use_fargate_spot             = var.use_fargate_spot
  scheduled_scaling            = var.scheduled_stop.enabled
  deployment_maximum_percent   = var.deployment_maximum_percent

  api = {
    cpu      = var.api.cpu
    memory   = var.api.memory
    min      = var.api.min
    max      = var.api.max
    requests = var.api.requests
  }

  api_environment     = local.api_environment
  api_secrets         = local.api_secrets
  migrate_environment = local.migrate_environment
  migrate_secrets     = local.migrate_secrets
  jobs_environment    = local.jobs_environment
  jobs_secrets        = local.jobs_secrets
  media_environment   = local.media_environment
  media_secrets       = local.media_secrets

  # Media task (dashboard): its size is counted in the vCPU budget above; its role only reads
  # uploads/ and writes the processed files of OUR content bucket.
  media                  = { cpu = var.media_task.cpu, memory = var.media_task.memory }
  content_bucket_arn     = module.content.bucket_arn
  content_upload_prefix  = module.content.upload_prefix
  content_media_prefixes = module.content.media_prefixes

  log_retention_days = var.log_retention_days
  kms_key_arn        = module.kms.key_arn

  depends_on = [terraform_data.connection_budget]
}

# Arrêt planifié (préproduction) : min = max = 0 le soir et le week-end, réveil le matin.
resource "aws_appautoscaling_scheduled_action" "start" {
  count              = var.scheduled_stop.enabled && local.ingress_enabled ? 1 : 0
  name               = "${local.name}-api-start"
  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = module.ecs.autoscaling_resource_id
  schedule           = var.scheduled_stop.start
  timezone           = var.scheduled_stop.timezone

  scalable_target_action {
    min_capacity = 1
    max_capacity = var.api.max
  }
}

resource "aws_appautoscaling_scheduled_action" "stop" {
  count              = var.scheduled_stop.enabled && local.ingress_enabled ? 1 : 0
  name               = "${local.name}-api-stop"
  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = module.ecs.autoscaling_resource_id
  schedule           = var.scheduled_stop.stop
  timezone           = var.scheduled_stop.timezone

  scalable_target_action {
    min_capacity = 0
    max_capacity = 0
  }

  depends_on = [aws_appautoscaling_scheduled_action.start]
}

# --- Base de données : amorçage, sauvegardes, restauration ---------------------------------------

module "db_tools" {
  source = "../db_tools"

  name                        = local.name
  db_host                     = var.rds.address
  db_port                     = var.rds.port
  db_engine_version           = var.rds.engine_version
  master_username             = var.rds.master_username
  master_password_secret_name = "${local.secret_prefix}/bootstrap/rds-master-password"

  db_name                   = var.db_name
  restore_db_name           = "${var.db_name}_restore"
  app_role                  = var.db_roles.app
  migrator_role             = var.db_roles.migrator
  backup_role               = var.db_roles.backup
  db_secret_arns            = module.secrets.db_secret_arns
  app_connection_limit      = var.db_role_connection_limits.app
  migrator_connection_limit = var.db_role_connection_limits.migrator
  backup_connection_limit   = var.db_role_connection_limits.backup

  cpu_architecture      = var.cpu_architecture
  jobs_log_group_name   = module.ecs.log_group_names["jobs"]
  kms_key_arn           = module.kms.key_arn
  backup_retention_days = var.backup_retention_days
  force_destroy         = var.force_destroy
  metric_namespace      = module.observability.metric_namespace
  alarm_topic_arn       = module.observability.alerts_topic_arn
}

module "scheduler" {
  source = "../scheduler"

  name               = local.name
  cluster_arn        = module.ecs.cluster_arn
  cluster_name       = module.ecs.cluster_name
  task_family        = module.ecs.task_families["jobs"]
  container_name     = module.ecs.container_names["jobs"]
  subnet_ids         = var.app_subnet_ids
  security_group_ids = [module.ecs.api_security_group_id]
  capacity_provider  = "FARGATE_SPOT"
  timezone           = "Europe/Brussels"
  pass_role_arns     = concat([module.ecs.execution_role_arns["jobs"]], module.db_tools.pass_role_arns)

  # Les planifications visent la FAMILLE jobs : ECS lance sa dernière révision active, que le
  # workflow Deploy enregistre après le service api stable.
  jobs = {
    "purge-expired" = {
      description = "Compteurs de limites de debit expires"
      schedule    = "cron(10 3 * * ? *)"
      command     = ["python", "manage.py", "purge_expired"]
    }
    "finalize-purchases" = {
      description = "Acquittement des achats Google Play pas encore finalises"
      schedule    = "cron(20 * * * ? *)"
      command     = ["python", "manage.py", "finalize_purchases"]
    }
    "db-backup" = {
      description = "Sauvegarde logique quotidienne (pg_dump vers S3)"
      schedule    = "cron(40 3 * * ? *)"
      task_family = module.db_tools.task_families["backup"]
    }
  }
}

# --- Exploitation ------------------------------------------------------------------------------

module "observability" {
  source = "../observability"

  name                    = local.name
  kms_key_arn             = module.kms.key_arn
  alert_emails            = var.alert_emails
  alb_arn_suffix          = local.ingress_enabled ? module.alb[0].arn_suffix : ""
  target_alarms_enabled   = local.ingress_enabled
  target_group_arn_suffix = local.ingress_enabled ? module.alb[0].target_group_arn_suffix : null
  ecs_cluster_name        = module.ecs.cluster_name
  ecs_cluster_arn         = module.ecs.cluster_arn
  ecs_service_names       = module.ecs.service_names
  app_log_group_names     = module.ecs.log_group_names
  rds_alarms_enabled      = var.rds_alarms_enabled
  rds_instance_id         = var.rds.identifier
}

# --- Déploiement continu -------------------------------------------------------------------------

# Registers new revisions of OUR families only (the deploy role never reads nor writes a task
# definition itself: modules/task_registrar).
module "task_registrar" {
  source = "../task_registrar"

  name                 = local.name
  register_inputs      = module.ecs.register_inputs
  image_repository_url = module.ecr.repository_urls["api"]
  # Roles named by the templates: execution roles, and the task roles of api and media.
  pass_role_arns     = concat(values(module.ecs.execution_role_arns), values(module.ecs.task_role_arns))
  kms_key_arn        = module.kms.key_arn
  log_retention_days = var.log_retention_days
  revision_tags = {
    Project     = "eventide"
    Environment = var.environment
    Repository  = var.github_repository
    Hosting     = "shared"
    ManagedBy   = "github-deploy"
  }
}

resource "aws_ssm_parameter" "deploy_config" {
  name        = "${local.ssm_prefix}/deploy/config"
  description = "Configuration lue par .github/workflows/deploy.yml (aucun secret)"
  type        = "String"
  tier        = "Standard"
  value = jsonencode({
    environment      = var.environment
    hosting          = "shared"
    region           = local.region
    cpu_architecture = var.cpu_architecture
    cluster          = module.ecs.cluster_name
    services         = module.ecs.service_names
    task_families    = module.ecs.task_families
    task_registrar   = module.task_registrar.function_name
    containers       = module.ecs.container_names
    ecr              = { api = module.ecr.repository_urls["api"] }
    network = {
      subnets         = var.app_subnet_ids
      security_groups = [module.ecs.api_security_group_id]
    }
    jobs_log_group      = module.ecs.log_group_names["jobs"]
    image_tag_parameter = aws_ssm_parameter.image_tag.name
    urls = local.ingress_enabled ? {
      api = local.api_url
      web = local.public_web_url
    } : {}
  })
}

module "github_oidc" {
  source = "../github_oidc"

  name                        = local.name
  oidc_provider_arn           = var.github_oidc_provider_arn
  github_repository           = var.github_repository
  github_subject_repository   = var.github_subject_repository
  github_environment          = var.environment
  allowed_git_refs            = var.github_allowed_git_refs
  ecr_repository_arns         = values(module.ecr.repository_arns)
  ecs_cluster_arn             = module.ecs.cluster_arn
  ecs_cluster_name            = module.ecs.cluster_name
  ecs_service_arns            = module.ecs.service_arns
  task_registrar_function_arn = module.task_registrar.function_arn
  migrate_task_family         = module.ecs.task_families["migrate"]
  # Roles of the revisions the deploy runs (migrate) or puts in the api service (api execution
  # and task roles); never the media roles (the deploy does not start media tasks).
  pass_role_arns = concat(
    [for k, arn in module.ecs.execution_role_arns : arn if k != "media"],
    [module.ecs.task_role_arns["api"]],
  )
  deploy_config_parameter_arn = aws_ssm_parameter.deploy_config.arn
  image_tag_parameter_arn     = aws_ssm_parameter.image_tag.arn
  jobs_log_group_arn          = module.ecs.log_group_arns["jobs"]
}
