variable "name" {
  description = "Préfixe de nommage (ev-prod, ev-preprod)."
  type        = string
}

# --- Instance partagée ---

variable "db_host" {
  description = "Hôte de l'instance PostgreSQL partagée."
  type        = string
}

variable "db_port" {
  description = "Port PostgreSQL."
  type        = number
  default     = 5432
}

variable "db_engine_version" {
  description = "Version du moteur de l'instance (lue par la source de données), comparée à postgres_major_version."
  type        = string
}

variable "master_username" {
  description = "Compte maître de l'instance (nom, pas un secret)."
  type        = string
}

variable "master_database" {
  description = "Base où se connecte le compte maître pour l'amorçage."
  type        = string
  default     = "postgres"
}

variable "master_password_secret_name" {
  description = "Nom du secret TEMPORAIRE (chaîne simple) contenant le mot de passe maître, créé puis supprimé par le product owner autour de l'amorçage. Jamais géré par Terraform."
  type        = string
}

# --- Nos bases et rôles ---

# Shared instance: Eventide only ever names its own databases (eventide, eventide_*) and roles
# (ev_*). The task scripts check the same prefixes at run time (files/lib.sh), whatever
# overrides a task run receives.
variable "db_name" {
  description = "Base applicative (eventide)."
  type        = string

  validation {
    condition     = can(regex("^eventide(_[a-z0-9_]{1,54})?$", var.db_name))
    error_message = "db_name : eventide ou eventide_<suffixe> (minuscules, chiffres, tirets bas) ; jamais une base d'une autre plateforme."
  }
}

variable "restore_db_name" {
  description = "Base de test de restauration (vide hors des tests)."
  type        = string

  validation {
    condition     = can(regex("^eventide_[a-z0-9_]{1,54}$", var.restore_db_name))
    error_message = "restore_db_name : eventide_<suffixe> (minuscules, chiffres, tirets bas) ; jamais une base d'une autre plateforme."
  }
}

variable "app_role" {
  description = "Rôle de l'application (DML seulement)."
  type        = string

  validation {
    condition     = can(regex("^ev_[a-z0-9_]{1,60}$", var.app_role))
    error_message = "app_role : ev_<nom> (préfixe d'Eventide)."
  }
}

variable "migrator_role" {
  description = "Rôle propriétaire (migrations, DDL)."
  type        = string

  validation {
    condition     = can(regex("^ev_[a-z0-9_]{1,60}$", var.migrator_role))
    error_message = "migrator_role : ev_<nom> (préfixe d'Eventide)."
  }
}

variable "backup_role" {
  description = "Rôle en lecture seule des sauvegardes (pg_dump)."
  type        = string

  validation {
    condition     = can(regex("^ev_[a-z0-9_]{1,60}$", var.backup_role))
    error_message = "backup_role : ev_<nom> (préfixe d'Eventide)."
  }
}

variable "db_secret_arns" {
  description = "Secrets des rôles (JSON avec la clé password) : { app, migrator, backup }."
  type        = map(string)

  validation {
    condition     = alltrue([for k in ["app", "migrator", "backup"] : contains(keys(var.db_secret_arns), k)])
    error_message = "db_secret_arns doit contenir app, migrator et backup."
  }
}

variable "app_connection_limit" {
  description = "CONNECTION LIMIT du rôle applicatif (tâches api max x workers x threads + tâches ponctuelles + marge)."
  type        = number
}

variable "migrator_connection_limit" {
  description = "CONNECTION LIMIT du rôle de migration."
  type        = number
  default     = 2
}

variable "backup_connection_limit" {
  description = "CONNECTION LIMIT du rôle de sauvegarde."
  type        = number
  default     = 2
}

variable "restore_connection_limit" {
  description = "CONNECTION LIMIT de la base de test de restauration (connexions de ev_migrator, comptées dans sa propre limite)."
  type        = number
  default     = 2
}

variable "role_timeouts" {
  description = "Délais par rôle (syntaxe PostgreSQL, ex. 30s, 5min) : statement_timeout, lock_timeout, idle_in_transaction_session_timeout."
  type = object({
    app      = object({ statement = string, lock = string, idle_in_transaction = string })
    migrator = object({ statement = string, lock = string, idle_in_transaction = string })
    backup   = object({ statement = string, lock = string, idle_in_transaction = string })
  })
  # Mêmes délais que Candidature Express.
  default = {
    app      = { statement = "30s", lock = "5s", idle_in_transaction = "60s" }
    migrator = { statement = "15min", lock = "10s", idle_in_transaction = "5min" }
    backup   = { statement = "0", lock = "60s", idle_in_transaction = "10min" }
  }
}

# Per-role resource caps on the SHARED instance (CINAF, JobMinutes, Candidature Express): memory
# per sort or hash (work_mem), maintenance memory (maintenance_work_mem), temporary files per
# session (temp_file_limit) and idle sessions closed by the server (idle_session_timeout). The
# bootstrap also sets max_parallel_workers_per_gather = 0 and max_parallel_maintenance_workers
# = 0 for every role: our queries never take the instance's parallel workers.
# Semantics (PostgreSQL 16, checked against a local 16 with a non-superuser CREATEROLE master
# account, as on RDS): all are settable by ALTER ROLE ... SET by the role's creator, except
# temp_file_limit (superuser-only parameter: set only if the master account holds SET privilege
# on it, otherwise reported by the event db_bootstrap_temp_file_limit_skipped). work_mem,
# maintenance_work_mem and idle_session_timeout stay user-settable: only our own code could
# raise them in a session, and it never does. temp_file_limit, once set, cannot be raised.
variable "role_resource_limits" {
  description = "Plafonds de ressources par rôle (syntaxe PostgreSQL : 4MB, 1GB, 15min) : work_mem, maintenance_work_mem, temp_file_limit, idle_session_timeout."
  type = object({
    app      = object({ work_mem = string, maintenance_work_mem = string, temp_file_limit = string, idle_session_timeout = string })
    migrator = object({ work_mem = string, maintenance_work_mem = string, temp_file_limit = string, idle_session_timeout = string })
    backup   = object({ work_mem = string, maintenance_work_mem = string, temp_file_limit = string, idle_session_timeout = string })
  })
  default = {
    # ev_app: short OLTP queries through a connection pool (idle pooled connections are
    # health-checked by Django before use, CONN_HEALTH_CHECKS, so a server-closed one is replaced).
    app = { work_mem = "4MB", maintenance_work_mem = "16MB", temp_file_limit = "256MB", idle_session_timeout = "15min" }
    # ev_migrator: Django migrations (index builds) and the restore test (pg_restore).
    migrator = { work_mem = "16MB", maintenance_work_mem = "64MB", temp_file_limit = "1GB", idle_session_timeout = "10min" }
    # ev_backup: pg_dump (COPY only).
    backup = { work_mem = "4MB", maintenance_work_mem = "16MB", temp_file_limit = "256MB", idle_session_timeout = "10min" }
  }

  validation {
    condition = alltrue(flatten([
      for role in values(var.role_resource_limits) : [
        for v in values(role) : can(regex("^[1-9][0-9]{0,5}(kB|MB|GB|ms|s|min|h)$", v))
      ]
    ]))
    error_message = "role_resource_limits : valeurs positives avec unité (kB, MB, GB, ms, s, min, h), ex. 4MB ou 15min (0 = illimité est refusé)."
  }
}

# --- Exécution ---

variable "cpu_architecture" {
  description = "Architecture des tâches (ARM64 ou X86_64) ; les images publiques sont multi-architecture."
  type        = string
  default     = "ARM64"
}

variable "postgres_major_version" {
  description = "Version majeure du client PostgreSQL (doit être celle de l'instance)."
  type        = string
  default     = "16"
}

variable "postgres_image" {
  description = "Image du client PostgreSQL (psql, pg_dump, pg_restore), épinglée par empreinte (index multi-architecture)."
  type        = string
  default     = "public.ecr.aws/docker/library/postgres:16-alpine@sha256:721873c34ceb9f8d8fc265984940dc982404c105f19ad51be9fdc5970a6080ea"
}

variable "python_image" {
  description = "Image Python (calcul des vérificateurs SCRAM), même empreinte que la base de backend/Dockerfile (et que Candidature Express)."
  type        = string
  default     = "public.ecr.aws/docker/library/python:3.12-slim-bookworm@sha256:34386ef0cb081344d7ec1c103ba398e6e9f64e9ab3a1509accc92a4e24a07258"
}

variable "aws_cli_image" {
  description = "Image AWS CLI v2 (envoi et lecture S3), épinglée par empreinte."
  type        = string
  default     = "public.ecr.aws/aws-cli/aws-cli:2.37.10@sha256:3dacc5db57c923c4223e949795f538ecf1f2212b2b7d5a028b47b97f91564c0d"
}

variable "rds_ca_bundle_url" {
  description = "Bundle des autorités de certification RDS (sslmode=verify-full). Vide = TLS sans vérification du serveur (déconseillé)."
  type        = string
  default     = "https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem"
}

variable "rds_ca_bundle_sha256" {
  description = "Empreinte SHA-256 attendue du bundle (la même que dans backend/Dockerfile)."
  type        = string
  default     = "90a6f1a7978a1b1b096dca6c57511ca48d3b8cf052f8e704baf358f34ea2f21b"
}

variable "jobs_log_group_name" {
  description = "Groupe de journaux des tâches ponctuelles (flux db-bootstrap/*, db-backup/*, db-restore/*)."
  type        = string
}

variable "kms_key_arn" {
  description = "Clé KMS de l'environnement (secrets, bucket des sauvegardes)."
  type        = string
}

# --- Sauvegardes ---

variable "backup_retention_days" {
  description = "Conservation des sauvegardes logiques (jours)."
  type        = number
  default     = 35
}

variable "noncurrent_retention_days" {
  description = "Conservation des versions remplacées ou supprimées (jours) : rattrapage d'une suppression accidentelle."
  type        = number
  default     = 7
}

variable "force_destroy" {
  description = "Autorise la suppression du bucket non vide (préproduction)."
  type        = bool
  default     = false
}

variable "metric_namespace" {
  description = "Espace de noms CloudWatch des métriques issues des journaux."
  type        = string
}

variable "alarm_topic_arn" {
  description = "Sujet SNS des alertes."
  type        = string
  default     = null
}

variable "backup_alarm_enabled" {
  description = "Alarme « aucune sauvegarde depuis 24 h » (exige alarm_topic_arn)."
  type        = bool
  default     = true
}
