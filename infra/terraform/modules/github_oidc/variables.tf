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

  validation {
    condition     = length(var.ecr_repository_arns) > 0 && alltrue([for a in var.ecr_repository_arns : can(regex("^arn:aws:ecr:[a-z0-9-]+:[0-9]{12}:repository/ev-[a-z0-9-]+$", a))])
    error_message = "ecr_repository_arns : nos seuls dépôts (repository/ev-*)."
  }
}

variable "ecs_cluster_arn" {
  description = "ARN de notre cluster ECS."
  type        = string

  validation {
    condition     = can(regex("^arn:aws:ecs:[a-z0-9-]+:[0-9]{12}:cluster/ev-[a-z0-9-]+$", var.ecs_cluster_arn))
    error_message = "ecs_cluster_arn : notre seul cluster (cluster/ev-*)."
  }
}

variable "ecs_cluster_name" {
  description = "Nom de notre cluster ECS."
  type        = string

  validation {
    condition     = startswith(var.ecs_cluster_name, "ev-")
    error_message = "ecs_cluster_name : ev-*."
  }
}

variable "ecs_service_arns" {
  description = "Services que le déploiement peut mettre à jour (vide sans domaine)."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for a in var.ecs_service_arns : can(regex("^arn:aws:ecs:[a-z0-9-]+:[0-9]{12}:service/ev-[a-z0-9-]+/[a-z0-9-]+$", a))])
    error_message = "ecs_service_arns : services de nos clusters seulement (service/ev-*/...)."
  }
}

variable "task_registrar_function_arn" {
  description = "Registraire des définitions de tâche (modules/task_registrar) : seul moyen du déploiement d'enregistrer une révision."
  type        = string

  validation {
    condition     = can(regex("^arn:aws:lambda:[a-z0-9-]+:[0-9]{12}:function:ev-[a-z0-9-]+-task-registrar$", var.task_registrar_function_arn))
    error_message = "task_registrar_function_arn : notre registraire (function:ev-*-task-registrar)."
  }
}

variable "migrate_task_family" {
  description = "Famille de la tâche de migration."
  type        = string

  validation {
    condition     = can(regex("^ev-[a-z0-9-]+$", var.migrate_task_family))
    error_message = "migrate_task_family : ev-*."
  }
}

variable "pass_role_arns" {
  description = "Rôles d'exécution référencés par nos définitions de tâche."
  type        = list(string)

  validation {
    condition     = length(var.pass_role_arns) > 0 && alltrue([for a in var.pass_role_arns : can(regex("^arn:aws:iam::[0-9]{12}:role/ev-[a-z0-9-]+$", a))])
    error_message = "pass_role_arns : nos rôles seulement (role/ev-*)."
  }
}

variable "deploy_config_parameter_arn" {
  description = "Paramètre SSM de configuration du déploiement (lecture)."
  type        = string

  validation {
    condition     = can(regex("^arn:aws:ssm:[a-z0-9-]+:[0-9]{12}:parameter/eventide/", var.deploy_config_parameter_arn))
    error_message = "deploy_config_parameter_arn : paramètre /eventide/*."
  }
}

variable "image_tag_parameter_arn" {
  description = "Paramètre SSM du tag déployé (lecture et écriture)."
  type        = string

  validation {
    condition     = can(regex("^arn:aws:ssm:[a-z0-9-]+:[0-9]{12}:parameter/eventide/", var.image_tag_parameter_arn))
    error_message = "image_tag_parameter_arn : paramètre /eventide/*."
  }
}

variable "jobs_log_group_arn" {
  description = "Groupe de journaux des tâches ponctuelles (lecture des journaux de migration)."
  type        = string

  validation {
    condition     = can(regex("^arn:aws:logs:[a-z0-9-]+:[0-9]{12}:log-group:/ecs/ev-[a-z0-9-]+/jobs$", var.jobs_log_group_arn))
    error_message = "jobs_log_group_arn : notre groupe /ecs/ev-*/jobs."
  }
}
