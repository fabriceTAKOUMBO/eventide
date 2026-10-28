variable "name" {
  description = "Préfixe de nommage (ev-prod, ev-preprod) : cluster, familles, rôles, groupes."
  type        = string
}

variable "vpc_id" {
  description = "VPC partagé."
  type        = string
}

variable "private_subnet_ids" {
  description = "Sous-réseaux privés « application » partagés (route vers la NAT de CINAF)."
  type        = list(string)
}

variable "alb_security_group_id" {
  description = "Groupe de sécurité de l'ALB partagé, cité comme source (jamais modifié)."
  type        = string
}

variable "postgres_security_group_id" {
  description = "Groupe de sécurité de l'instance PostgreSQL partagée (seule destination 5432)."
  type        = string
}

variable "postgres_port" {
  description = "Port PostgreSQL."
  type        = number
  default     = 5432
}

variable "api_service_enabled" {
  description = "Crée le service api (exige le groupe cible, donc un domaine)."
  type        = bool
}

variable "target_group_arn" {
  description = "Groupe cible de l'API (null sans domaine)."
  type        = string
  default     = null
}

variable "request_count_resource_label" {
  description = "Libellé <alb>/<groupe cible> de la métrique ALBRequestCountPerTarget (null sans domaine)."
  type        = string
  default     = null
}

variable "ecr_repository_url" {
  description = "Dépôt ECR de l'image de l'API."
  type        = string
}

variable "ecr_repository_arn" {
  description = "ARN du dépôt ECR (lecture par les rôles d'exécution)."
  type        = string
}

variable "image_tag" {
  description = "Tag d'image (SHA du commit déployé, lu dans le paramètre SSM ; « bootstrap » avant le premier déploiement)."
  type        = string
}

variable "cpu_architecture" {
  description = "ARM64 (Graviton) ou X86_64."
  type        = string
  default     = "ARM64"

  validation {
    condition     = contains(["ARM64", "X86_64"], var.cpu_architecture)
    error_message = "cpu_architecture : ARM64 ou X86_64."
  }
}

variable "use_fargate_spot" {
  description = "Service sur Fargate Spot (préproduction)."
  type        = bool
  default     = false
}

variable "api" {
  description = "Service api : cpu, mémoire, tâches min/max, requêtes par tâche et par minute visées."
  type = object({
    cpu      = number
    memory   = number
    min      = number
    max      = number
    requests = number
  })
}

variable "scheduled_scaling" {
  description = "Préproduction : min et max du service pilotés par des actions planifiées (Terraform les ignore après la création)."
  type        = bool
  default     = false
}

variable "deployment_maximum_percent" {
  description = "Plafond de tâches pendant un déploiement (200 = remplacement sans coupure) ; entre dans le budget de connexions."
  type        = number
  default     = 200
}

variable "api_environment" {
  description = "Variables non secrètes de l'API."
  type        = map(string)
}

variable "api_secrets" {
  description = "Secrets de l'API : nom de variable => référence Secrets Manager (ARN[:clé-json::])."
  type        = map(string)
}

variable "migrate_environment" {
  description = "Variables de la tâche de migration."
  type        = map(string)
}

variable "migrate_secrets" {
  description = "Secrets de la tâche de migration (rôle ev_migrator)."
  type        = map(string)
}

variable "jobs_environment" {
  description = "Variables des tâches planifiées."
  type        = map(string)
}

variable "jobs_secrets" {
  description = "Secrets des tâches planifiées."
  type        = map(string)
}

variable "log_retention_days" {
  description = "Rétention des journaux CloudWatch (jours)."
  type        = number
  default     = 30
}

variable "kms_key_arn" {
  description = "Clé KMS de l'environnement (journaux, secrets)."
  type        = string
}
