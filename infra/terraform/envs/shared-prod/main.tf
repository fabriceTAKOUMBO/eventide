# HÉBERGEMENT MUTUALISÉ — Eventide dans le compte AWS principal (466494951409, us-east-1), à
# côté de CINAF, JobMinutes et Candidature Express, en réutilisant le VPC, les sous-réseaux
# privés « application », la NAT, l'ALB et l'instance PostgreSQL de CINAF, sans jamais modifier
# leurs ressources (décision du product owner, ADR : docs/infra/hebergement-mutualise.md).
# Mêmes règles que Candidature Express (son ADR fait référence).
#
#   - production : toujours ;
#   - préproduction : facultative (preprod_enabled), arrêtée la nuit et le week-end ;
#   - entrée publique (certificat, règles d'écouteur, DNS, service api) : seulement quand
#     domain_name est renseigné (domaine pas encore acheté : vérification de marque en cours).
#
# Les ressources partagées sont lues par des sources de données à partir des identifiants de
# terraform.tfvars ; les seuls ajouts sur elles sont listés dans modules/shared_platform.
#
#   terraform init -backend-config=backend.hcl
#   terraform plan -out=tfplan        (relu : 0 change et 0 destroy sur toute ressource de
#                                      CINAF, JobMinutes ou Candidature Express)
#   terraform apply tfplan            (avec l'accord explicite du product owner, à chaque fois)
# Procédure complète : docs/runbooks/premier-deploiement.md

terraform {
  required_version = ">= 1.10, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.68"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.1"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.8"
    }
  }

  # bucket et kms_key_id : fournis par -backend-config=backend.hcl (voir backend.hcl.example).
  # Verrouillage natif S3 (use_lockfile), sans table DynamoDB.
  backend "s3" {
    key          = "envs/shared-prod/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

locals {
  default_tags = {
    Project    = "eventide"
    ManagedBy  = "terraform"
    Repository = var.github_repository
    Hosting    = "shared"
  }
}

provider "aws" {
  region              = var.region
  allowed_account_ids = [var.aws_account_id]

  default_tags {
    tags = merge(local.default_tags, { Environment = "prod" })
  }
}

# Préproduction : étiquette Environment = preprod (budgets et coûts séparés).
provider "aws" {
  alias               = "preprod"
  region              = var.region
  allowed_account_ids = [var.aws_account_id]

  default_tags {
    tags = merge(local.default_tags, { Environment = "preprod" })
  }
}

# --- Infrastructure partagée : lecture seule ---------------------------------------------------

data "aws_caller_identity" "current" {}

data "aws_vpc" "shared" {
  id = var.vpc_id
}

data "aws_subnet" "app" {
  for_each = toset(var.app_subnet_ids)
  id       = each.value
}

data "aws_lb" "shared" {
  name = var.alb_name
}

data "aws_lb_listener" "https" {
  load_balancer_arn = data.aws_lb.shared.arn
  port              = 443
}

data "aws_db_instance" "shared" {
  db_instance_identifier = var.rds_instance_identifier
}

data "aws_security_group" "rds" {
  id = var.rds_security_group_id
}

# Zone du domaine, cherchée par son nom (créée à l'achat du domaine) ; aucune sans domaine.
data "aws_route53_zone" "this" {
  count        = var.domain_name != "" ? 1 : 0
  name         = var.domain_name
  private_zone = false
}

# Fournisseur OIDC GitHub EXISTANT (créé par JobMinutes) : seulement référencé.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

# Cohérence des identifiants fournis (le plan échoue si l'un d'eux ne correspond pas).
resource "terraform_data" "shared_infrastructure_checks" {
  input = var.vpc_id

  lifecycle {
    precondition {
      condition     = alltrue([for s in data.aws_subnet.app : s.vpc_id == var.vpc_id])
      error_message = "Un sous-réseau de app_subnet_ids n'appartient pas au VPC vpc_id."
    }
    precondition {
      condition     = data.aws_lb.shared.vpc_id == var.vpc_id && data.aws_lb.shared.internal == false
      error_message = "L'ALB alb_name n'est pas l'ALB public du VPC vpc_id."
    }
    # Limites de débit par IP : Django (NUM_PROXIES = 1) prend la dernière adresse de
    # X-Forwarded-For, celle que l'ALB AJOUTE, sans port.
    precondition {
      condition     = data.aws_lb.shared.xff_header_processing_mode == "append" && data.aws_lb.shared.enable_xff_client_port == false
      error_message = "L'ALB partagé ne traite plus X-Forwarded-For comme prévu (attendu : mode append, sans port client ; lu : ${data.aws_lb.shared.xff_header_processing_mode} et ${data.aws_lb.shared.enable_xff_client_port}). Les limites de débit par IP de l'API reposent dessus : ne pas appliquer ; voir avec CINAF."
    }
    precondition {
      condition     = alltrue([for s in data.aws_subnet.app : s.available_ip_address_count >= var.app_subnet_min_free_ips])
      error_message = "Moins de ${var.app_subnet_min_free_ips} adresses IP libres dans un sous-réseau « application » partagé (${join(", ", [for s in data.aws_subnet.app : "${s.id} : ${s.available_ip_address_count}"])}) : nos tâches risquent de ne pas démarrer. Voir avec CINAF."
    }
    precondition {
      condition     = contains(data.aws_db_instance.shared.vpc_security_groups, var.rds_security_group_id)
      error_message = "rds_security_group_id n'est pas un groupe de sécurité de l'instance rds_instance_identifier."
    }
    precondition {
      condition     = startswith(data.aws_db_instance.shared.engine_version, "16.")
      error_message = "L'instance partagée n'est plus en PostgreSQL 16 : mettre à jour postgres_image et postgres_major_version de modules/db_tools avant tout apply."
    }
    precondition {
      condition     = var.domain_name == "" || trimsuffix(one(data.aws_route53_zone.this[*].name), ".") == var.domain_name
      error_message = "La zone Route 53 trouvée ne correspond pas à domain_name."
    }
    # The zone is looked up by name in the shared account, where the zones of the other
    # platforms live too: we only write records (and match listener rules) in a zone the
    # product owner marked as ours (runbook, phase 2).
    precondition {
      condition     = var.domain_name == "" || try(data.aws_route53_zone.this[0].tags["Project"], "") == "eventide"
      error_message = "La zone Route 53 de domain_name ne porte pas l'étiquette Project = eventide : ce n'est peut-être pas la nôtre (compte partagé). Ne pas appliquer ; étiqueter NOTRE zone (runbook, phase 2) ou corriger domain_name."
    }
  }
}

# La session qui applique doit pouvoir déchiffrer avec nos clés KMS (secrets) : sinon l'apply
# échoue à mi-chemin. Avertissement au plan : un plan destiné à être appliqué doit être SANS lui.
check "terraform_session_can_decrypt" {
  data "aws_iam_session_context" "current" {
    arn = data.aws_caller_identity.current.arn
  }

  assert {
    condition     = !var.kms_restrict_decrypt || anytrue([for re in local.terraform_session_regexes : can(regex(re, data.aws_iam_session_context.current.issuer_arn))])
    error_message = "La session Terraform (${data.aws_iam_session_context.current.issuer_arn}) ne figure ni dans kms_admin_principal_arns (par défaut : Identity Center AdministratorAccess) ni dans kms_extra_decrypt_principal_arns : nos clés KMS lui refuseront le déchiffrement et l'apply échouera. Ne pas appliquer ce plan : relancer avec une session Identity Center AdministratorAccess (aws sso login --profile principal)."
  }
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  domain     = var.domain_name
  zone_id    = var.domain_name != "" ? one(data.aws_route53_zone.this[*].zone_id) : null

  rds = {
    identifier        = data.aws_db_instance.shared.db_instance_identifier
    address           = data.aws_db_instance.shared.address
    port              = data.aws_db_instance.shared.port
    engine_version    = data.aws_db_instance.shared.engine_version
    master_username   = data.aws_db_instance.shared.master_username
    security_group_id = data.aws_security_group.rds.id
  }

  kms_admin_principals = length(var.kms_admin_principal_arns) > 0 ? var.kms_admin_principal_arns : [
    "arn:aws:iam::${local.account_id}:role/aws-reserved/sso.amazonaws.com/*AWSReservedSSO_AdministratorAccess_*",
  ]

  # Clé KMS de chaque environnement : seuls nos rôles ev-<env>-* et les rôles d'administration
  # déchiffrent (refus explicite pour tout autre principal du compte partagé).
  kms_decrypt_principals = {
    for env in ["prod", "preprod"] : env => var.kms_restrict_decrypt ? concat(
      ["arn:aws:iam::${local.account_id}:role/ev-${env}-*"],
      local.kms_admin_principals,
      var.kms_extra_decrypt_principal_arns,
    ) : []
  }

  terraform_session_regexes = [
    for p in concat(local.kms_admin_principals, var.kms_extra_decrypt_principal_arns) :
    "^${replace(replace(replace(p, "/([.+^$(){}|\\[\\]\\\\])/", "\\$1"), "*", ".*"), "?", ".")}$"
  ]

  common = {
    vpc_id                   = data.aws_vpc.shared.id
    app_subnet_ids           = var.app_subnet_ids
    https_listener_arn       = data.aws_lb_listener.https.arn
    alb_security_group_id    = one(data.aws_lb.shared.security_groups)
    github_oidc_provider_arn = data.aws_iam_openid_connect_provider.github.arn
  }
}

# --- Production --------------------------------------------------------------------------------

module "prod" {
  source = "../../modules/shared_platform"

  environment     = "prod"
  domain          = local.domain
  zone_id         = local.zone_id
  hostname_suffix = local.domain
  web_hostnames   = local.domain != "" ? [local.domain, "www.${local.domain}"] : []
  manage_caa      = var.manage_caa

  vpc_id                   = local.common.vpc_id
  app_subnet_ids           = local.common.app_subnet_ids
  https_listener_arn       = local.common.https_listener_arn
  alb_security_group_id    = local.common.alb_security_group_id
  github_oidc_provider_arn = local.common.github_oidc_provider_arn
  rds                      = local.rds

  # Plage de priorités réservée à Eventide sur l'écouteur partagé (prod : 400-409).
  listener_rule_priorities = {
    api = var.listener_priority_base
    web = var.listener_priority_base + 1
  }

  # Base et rôles propres sur l'instance partagée ; budget de connexions (décision du PO).
  db_name                   = "eventide"
  db_roles                  = { app = "ev_app", migrator = "ev_migrator", backup = "ev_backup" }
  db_role_connection_limits = { app = 10, migrator = 2, backup = 2 }
  db_connection_budget      = 14
  app_connection_reserve    = 2

  # Graviton (ARM64), à la demande, 1 à 2 tâches. Connexions : 2 tâches x 1 worker x pool 2,
  # doublées pendant un déploiement (200 %), + 2 pour les tâches planifiées = 10 = limite ev_app.
  cpu_architecture           = "ARM64"
  use_fargate_spot           = false
  deployment_maximum_percent = 200
  api                        = { cpu = 256, memory = 512, min = 1, max = 2, workers = 1, threads = 8, db_pool_max = 2, requests = 600 }

  force_destroy               = false
  log_retention_days          = 30
  secret_recovery_window_days = 30
  backup_retention_days       = 35

  kms_decrypt_allowed_principal_arns = local.kms_decrypt_principals["prod"]

  play_package_name          = var.play_package_name
  android_cert_fingerprints  = var.android_cert_fingerprints
  google_oauth_client_ids    = var.google_oauth_client_ids
  rtdn_service_account_email = var.rtdn_service_account_email
  voice                      = var.voice
  legal_publisher_name       = var.legal_publisher_name
  legal_contact_email        = var.legal_contact_email
  api_extra_environment      = var.api_extra_environment
  content_custom_domain      = var.content_custom_domain
  content_budget_enabled     = var.cost_guardrails_enabled
  content_budget_usd         = var.content_budget_usd

  alert_emails       = var.alert_emails
  budget_emails      = var.budget_emails
  rds_alarms_enabled = var.rds_alarms_enabled

  github_repository         = var.github_repository
  github_subject_repository = var.github_subject_repository
  github_allowed_git_refs   = ["refs/heads/main"]

  depends_on = [terraform_data.shared_infrastructure_checks]
}

# --- Préproduction (facultative) -----------------------------------------------------------------

module "preprod" {
  count     = var.preprod_enabled ? 1 : 0
  source    = "../../modules/shared_platform"
  providers = { aws = aws.preprod }

  environment     = "preprod"
  domain          = local.domain
  zone_id         = local.zone_id
  hostname_suffix = local.domain != "" ? "preprod.${local.domain}" : ""
  web_hostnames   = local.domain != "" ? ["preprod.${local.domain}"] : []
  manage_caa      = false

  vpc_id                   = local.common.vpc_id
  app_subnet_ids           = local.common.app_subnet_ids
  https_listener_arn       = local.common.https_listener_arn
  alb_security_group_id    = local.common.alb_security_group_id
  github_oidc_provider_arn = local.common.github_oidc_provider_arn
  rds                      = local.rds

  # Préproduction : 420-429.
  listener_rule_priorities = {
    api = var.listener_priority_base + 20
    web = var.listener_priority_base + 21
  }

  db_name                   = "eventide_preprod"
  db_roles                  = { app = "ev_preprod_app", migrator = "ev_preprod_migrator", backup = "ev_preprod_backup" }
  db_role_connection_limits = { app = 4, migrator = 1, backup = 1 }
  db_connection_budget      = 6
  app_connection_reserve    = 1

  # Fargate Spot, une tâche les jours ouvrés de 8 h à 20 h (heure de Bruxelles), zéro sinon.
  cpu_architecture           = "ARM64"
  use_fargate_spot           = true
  deployment_maximum_percent = 200
  api                        = { cpu = 256, memory = 512, min = 0, max = 1, workers = 1, threads = 4, db_pool_max = 1, requests = 600 }
  scheduled_stop             = { enabled = true }

  force_destroy               = true
  log_retention_days          = 14
  secret_recovery_window_days = 0
  backup_retention_days       = 7

  kms_decrypt_allowed_principal_arns = local.kms_decrypt_principals["preprod"]

  play_package_name          = var.play_package_name
  android_cert_fingerprints  = var.android_cert_fingerprints
  google_oauth_client_ids    = var.google_oauth_client_ids
  rtdn_service_account_email = var.rtdn_service_account_email
  voice                      = var.voice
  legal_publisher_name       = var.legal_publisher_name
  legal_contact_email        = var.legal_contact_email
  content_budget_enabled     = false

  alert_emails       = var.alert_emails
  budget_emails      = var.budget_emails
  rds_alarms_enabled = false

  github_repository         = var.github_repository
  github_subject_repository = var.github_subject_repository
  github_allowed_git_refs   = ["refs/heads/*"]

  depends_on = [terraform_data.shared_infrastructure_checks]
}
