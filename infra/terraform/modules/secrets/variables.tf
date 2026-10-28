variable "secret_prefix" {
  description = "Préfixe des noms de secrets (eventide/prod, eventide/preprod)."
  type        = string
}

variable "kms_key_arn" {
  description = "Clé KMS de chiffrement des secrets."
  type        = string
}

variable "recovery_window_days" {
  description = "Délai de récupération d'un secret supprimé (0 = suppression immédiate)."
  type        = number
  default     = 30
}

variable "db_host" {
  description = "Hôte de l'instance PostgreSQL partagée."
  type        = string
}

variable "db_port" {
  description = "Port PostgreSQL."
  type        = number
  default     = 5432
}

variable "db_name" {
  description = "Base applicative (eventide)."
  type        = string
}

variable "db_roles" {
  description = "Rôles PostgreSQL : clé du secret => nom du rôle ({ app = ev_app, migrator = ev_migrator, backup = ev_backup })."
  type        = map(string)
}

variable "db_ca_bundle_path" {
  description = "Chemin, dans l'image de l'API, du bundle d'autorités RDS (sslmode=verify-full)."
  type        = string
  default     = "/app/certs/rds-global-bundle.pem"
}

variable "manual_secrets" {
  description = "Secrets remplis à la main après création : nom => description."
  type        = map(string)
  default     = {}
}
