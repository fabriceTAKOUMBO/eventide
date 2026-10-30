# --- Identité de l'environnement ---

variable "environment" {
  description = "Environnement (prod ou preprod) ; aussi nom de l'environnement GitHub. Préfixe des ressources : ev-<env>."
  type        = string

  validation {
    condition     = contains(["preprod", "prod"], var.environment)
    error_message = "environment doit valoir preprod ou prod."
  }
}

variable "domain" {
  description = "Domaine d'Eventide (zone Route 53 existante). Vide = pas d'entrée publique (ni certificat, ni règles d'écouteur, ni DNS, ni service api)."
  type        = string
  default     = ""
}

variable "zone_id" {
  description = "Zone Route 53 du domaine (null sans domaine)."
  type        = string
  default     = null
}

variable "hostname_suffix" {
  description = "Suffixe des noms d'hôte : le domaine en production (api.<domaine>), preprod.<domaine> en préproduction."
  type        = string
  default     = ""
}

variable "web_hostnames" {
  description = "Hôtes des pages web (premier = origine des liens de partage) : [<domaine>, www.<domaine>] en production."
  type        = list(string)
  default     = []
}

variable "manage_caa" {
  description = "Crée l'enregistrement CAA du domaine (production seulement)."
  type        = bool
  default     = false
}

# --- Infrastructure partagée (lue par la racine, jamais modifiée sauf les ajouts documentés) ---

variable "vpc_id" {
  description = "VPC partagé de CINAF."
  type        = string
}

variable "app_subnet_ids" {
  description = "Sous-réseaux privés « application » partagés (route vers la NAT de CINAF)."
  type        = list(string)
}

variable "https_listener_arn" {
  description = "Écouteur HTTPS 443 de l'ALB partagé : on y AJOUTE nos règles et notre certificat."
  type        = string
}

variable "alb_security_group_id" {
  description = "Groupe de sécurité de l'ALB partagé, cité comme source par notre groupe (jamais modifié)."
  type        = string
}

variable "listener_rule_priorities" {
  description = "Priorités de nos règles d'écouteur (prod : 400-409 ; préproduction : 420-429)."
  type = object({
    api = number
    web = number
  })
}

variable "rds" {
  description = "Instance PostgreSQL partagée (lue par une source de données)."
  type = object({
    identifier        = string
    address           = string
    port              = number
    engine_version    = string
    master_username   = string
    security_group_id = string
  })
}

variable "github_oidc_provider_arn" {
  description = "Fournisseur OIDC GitHub EXISTANT du compte (jamais créé ici)."
  type        = string
}

# --- Base de données ---

# Shared instance: only our own names (eventide*, ev_*), never a database or role of another
# platform (checked again by modules/db_tools and at run time by its scripts).
variable "db_name" {
  description = "Base applicative sur l'instance partagée (eventide)."
  type        = string

  validation {
    condition     = can(regex("^eventide(_[a-z0-9_]{1,40})?$", var.db_name))
    error_message = "db_name : eventide ou eventide_<suffixe> ; jamais une base d'une autre plateforme."
  }
}

variable "db_roles" {
  description = "Rôles PostgreSQL : { app = ev_app (DML), migrator = ev_migrator (propriétaire), backup = ev_backup (lecture) }."
  type = object({
    app      = string
    migrator = string
    backup   = string
  })

  validation {
    condition     = alltrue([for r in values(var.db_roles) : can(regex("^ev_[a-z0-9_]{1,60}$", r))])
    error_message = "db_roles : ev_<nom> (préfixe d'Eventide) ; jamais un rôle d'une autre plateforme."
  }
}

variable "db_role_connection_limits" {
  description = "CONNECTION LIMIT par rôle. Décision du product owner du 28 octobre 2026 : 10, 2, 2 (base 14) ; proposé le 30 octobre 2026 avec la tâche media : 11, 2, 1, même total 14 (ADR § 12, à confirmer)."
  type = object({
    app      = number
    migrator = number
    backup   = number
  })
  default = { app = 11, migrator = 2, backup = 1 }
}

variable "db_connection_budget" {
  description = "Plafond de connexions d'Eventide sur l'instance partagée (CONNECTION LIMIT de la base) : 14."
  type        = number
  default     = 14
}

variable "app_connection_reserve" {
  description = "Connexions du rôle applicatif réservées aux tâches planifiées (purge, finalisation des achats)."
  type        = number
  default     = 2
}

variable "media_task_concurrency" {
  description = "Tâches media (tableau de bord) qui peuvent tourner en même temps : comptées dans le budget de connexions (1 connexion du rôle applicatif chacune) et dans le budget de vCPU. L'API doit lancer au plus ce nombre de traitements à la fois (count = 1, pas de nouveau traitement tant qu'un autre est en cours)."
  type        = number
  default     = 1

  validation {
    condition     = var.media_task_concurrency >= 1 && var.media_task_concurrency <= 2 && floor(var.media_task_concurrency) == var.media_task_concurrency
    error_message = "media_task_concurrency : 1 ou 2."
  }
}

variable "media_task" {
  description = "Taille de la tâche media (unités CPU, Mo) : 1 vCPU / 2 Go au plus (quota Fargate commun au compte), comptée dans fargate_vcpu_budget."
  type = object({
    cpu    = number
    memory = number
  })
  default = { cpu = 1024, memory = 2048 }
}

# --- Dimensionnement ---

variable "cpu_architecture" {
  description = "Architecture Fargate (ARM64 = Graviton)."
  type        = string
  default     = "ARM64"
}

variable "use_fargate_spot" {
  description = "Service sur Fargate Spot (préproduction)."
  type        = bool
  default     = false
}

variable "api" {
  description = "Tâches api : cpu, mémoire, min/max, workers gunicorn, threads par worker, taille maximale du pool PostgreSQL par worker (connexions par tâche = workers x db_pool_max), requêtes par tâche et par minute visées."
  type = object({
    cpu         = number
    memory      = number
    min         = number
    max         = number
    workers     = number
    threads     = number
    db_pool_max = number
    requests    = number
  })
}

variable "fargate_vcpu_budget" {
  description = "Pic de vCPU Fargate permis à l'environnement (quota commun à tout le compte partagé) : tâches api pendant un déploiement + 3 tâches ponctuelles + tâches media. Valeur par défaut volontairement basse : chaque environnement fixe la sienne après accord du product owner (envs/shared-prod)."
  type        = number
  default     = 2
}

variable "deployment_maximum_percent" {
  description = "Plafond de tâches pendant un déploiement (200 : remplacement sans coupure) ; compté dans le budget de connexions."
  type        = number
  default     = 200
}

variable "scheduled_stop" {
  description = "Arrêt planifié du service (préproduction) : démarrage et arrêt (cron EventBridge), fuseau horaire."
  type = object({
    enabled  = bool
    start    = optional(string, "cron(0 8 ? * MON-FRI *)")
    stop     = optional(string, "cron(0 20 ? * MON-FRI *)")
    timezone = optional(string, "Europe/Brussels")
  })
  default = { enabled = false }
}

# --- Protections et rétention ---

variable "force_destroy" {
  description = "Autorise la suppression des dépôts ECR et des buckets non vides (préproduction)."
  type        = bool
  default     = false
}

variable "log_retention_days" {
  description = "Rétention des journaux CloudWatch (jours)."
  type        = number
  default     = 30
}

variable "secret_recovery_window_days" {
  description = "Délai de récupération des secrets supprimés."
  type        = number
  default     = 30
}

variable "backup_retention_days" {
  description = "Conservation des sauvegardes logiques (jours)."
  type        = number
  default     = 35
}

variable "kms_decrypt_allowed_principal_arns" {
  description = "Motifs d'ARN des seuls principaux autorisés à déchiffrer avec la clé de l'environnement (vide = pas de restriction)."
  type        = list(string)
  default     = []
}

# --- Application ---

variable "play_package_name" {
  description = "Paquet Android (Play Console)."
  type        = string
  default     = ""
}

variable "android_cert_fingerprints" {
  description = "Empreintes SHA-256 du certificat de signature (assetlinks.json)."
  type        = list(string)
  default     = []
}

variable "google_oauth_client_ids" {
  description = "Identifiants clients OAuth acceptés comme audience des jetons d'identité Google."
  type        = list(string)
  default     = []
}

variable "google_web_client_id" {
  description = "Client OAuth Google « Application Web » du bouton « Se connecter avec Google » du tableau de bord (GOOGLE_WEB_CLIENT_ID, public). Vide = non configuré. Doit aussi figurer dans google_oauth_client_ids (audience vérifiée par l'API)."
  type        = string
  default     = ""

  validation {
    condition     = var.google_web_client_id == "" || can(regex("^[0-9]+-[a-z0-9]+\\.apps\\.googleusercontent\\.com$", var.google_web_client_id))
    error_message = "google_web_client_id : identifiant de client OAuth Google (<numéro>-<code>.apps.googleusercontent.com)."
  }
  validation {
    condition     = var.google_web_client_id == "" || contains(var.google_oauth_client_ids, var.google_web_client_id)
    error_message = "google_web_client_id doit aussi figurer dans google_oauth_client_ids : l'API vérifie l'audience du jeton de connexion du tableau de bord avec cette liste."
  }
}

variable "rtdn_audience" {
  description = "Audience du jeton OIDC de l'abonnement Pub/Sub push des RTDN (vide = https://api.<suffixe>/v1/play/rtdn)."
  type        = string
  default     = ""
}

variable "rtdn_service_account_email" {
  description = "Compte de service Google qui signe les envois Pub/Sub push des RTDN."
  type        = string
  default     = ""
}

variable "legal_publisher_name" {
  description = "Éditeur affiché sur /confidentialite."
  type        = string
  default     = ""
}

variable "legal_contact_email" {
  description = "Adresse de contact affichée sur /confidentialite."
  type        = string
  default     = ""
}

variable "api_extra_environment" {
  description = "Variables non secrètes supplémentaires de l'API (remplacent les valeurs du module, sauf celles de l'intégration du tableau de bord : CONTENT_BUCKET, MEDIA_TASK_*…)."
  type        = map(string)
  default     = {}
}

variable "content_custom_domain" {
  description = "Sert le contenu sur cdn.<suffixe> (certificat ACM propre) plutôt que sur le nom *.cloudfront.net."
  type        = bool
  default     = false
}

variable "content_budget_enabled" {
  description = "Budget mensuel du contenu (CloudFront et S3)."
  type        = bool
  default     = true
}

variable "content_budget_usd" {
  description = "Plafond d'alerte mensuel du contenu (USD)."
  type        = number
  default     = 30
}

# --- Exploitation ---

variable "alert_emails" {
  description = "Destinataires des alertes (confirmation par e-mail requise)."
  type        = list(string)
  default     = []
}

variable "budget_emails" {
  description = "Destinataires des alertes de budget."
  type        = list(string)
  default     = []
}

variable "rds_alarms_enabled" {
  description = "Alarmes sur l'instance partagée (métriques lues seulement ; déjà posées par Candidature Express)."
  type        = bool
  default     = false
}

# --- GitHub ---

variable "github_repository" {
  description = "Dépôt GitHub autorisé à déployer."
  type        = string
}

variable "github_subject_repository" {
  description = "Dépôt au format immuable du sujet OIDC (propriétaire@id/nom@id)."
  type        = string
}

variable "github_allowed_git_refs" {
  description = "Références Git autorisées à déployer."
  type        = list(string)
  default     = ["refs/heads/main"]
}
