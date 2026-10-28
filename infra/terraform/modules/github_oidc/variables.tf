variable "name" {
  description = "Préfixe de nommage (ev-prod, ev-preprod)."
  type        = string
}

variable "oidc_provider_arn" {
  description = "Fournisseur OIDC GitHub EXISTANT du compte, lu par une source de données (jamais créé ici)."
  type        = string
}

variable "github_repository" {
  description = "Dépôt GitHub autorisé (propriétaire/nom), pour les descriptions."
  type        = string
}

variable "github_subject_repository" {
  description = "Dépôt tel qu'il figure dans le sujet OIDC, au format immuable de GitHub (propriétaire@id/nom@id), relevé par `gh api repos/<dépôt>/actions/oidc/customization/sub`."
  type        = string

  validation {
    condition     = can(regex("^[^@/]+@[0-9]+/[^@/]+@[0-9]+$", var.github_subject_repository))
    error_message = "github_subject_repository : format immuable propriétaire@id/nom@id."
  }
}

variable "github_environment" {
  description = "Environnement GitHub autorisé à assumer le rôle (prod ou preprod)."
  type        = string
}

variable "allowed_git_refs" {
  description = "Références Git autorisées (motifs StringLike) : [\"refs/heads/main\"] en production."
  type        = list(string)
  default     = ["refs/heads/main"]
}

variable "ecr_repository_arns" {
  description = "Dépôts ECR où pousser l'image."
  type        = list(string)
}

variable "ecs_cluster_arn" {
  description = "ARN de notre cluster ECS."
  type        = string
}

variable "ecs_cluster_name" {
  description = "Nom de notre cluster ECS."
  type        = string
}

variable "ecs_service_arns" {
  description = "Services que le déploiement peut mettre à jour (vide sans domaine)."
  type        = list(string)
  default     = []
}

variable "migrate_task_family" {
  description = "Famille de la tâche de migration."
  type        = string
}

variable "pass_role_arns" {
  description = "Rôles d'exécution référencés par nos définitions de tâche."
  type        = list(string)
}

variable "deploy_config_parameter_arn" {
  description = "Paramètre SSM de configuration du déploiement (lecture)."
  type        = string
}

variable "image_tag_parameter_arn" {
  description = "Paramètre SSM du tag déployé (lecture et écriture)."
  type        = string
}

variable "jobs_log_group_arn" {
  description = "Groupe de journaux des tâches ponctuelles (lecture des journaux de migration)."
  type        = string
}
