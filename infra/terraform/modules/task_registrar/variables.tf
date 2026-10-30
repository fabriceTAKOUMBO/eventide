variable "name" {
  description = "Préfixe de nommage (ev-prod, ev-preprod) : fonction <name>-task-registrar, familles <name>-<clé>."
  type        = string

  validation {
    condition     = can(regex("^ev-[a-z0-9]+$", var.name))
    error_message = "name : ev-<environnement> (préfixe d'Eventide)."
  }
}

variable "register_inputs" {
  description = "Entrées exactes de RegisterTaskDefinition par clé de famille (sortie register_inputs du module ecs). Chaque famille doit valoir <name>-<clé>."
  type        = any

  # Closed list of OUR family keys (the handler checks the same list).
  validation {
    condition     = alltrue([for k, v in var.register_inputs : contains(["api", "migrate", "jobs", "media"], k)])
    error_message = "Clés de famille : api, migrate, jobs ou media seulement."
  }
  validation {
    condition     = alltrue([for k, v in var.register_inputs : try(v.family, "") == "${var.name}-${k}"])
    error_message = "Chaque modèle doit porter la famille <name>-<clé> (ev-<env>-api, -migrate, -jobs, -media)."
  }
}

variable "image_repository_url" {
  description = "Dépôt ECR de l'image (sans tag) : seuls les conteneurs de ce dépôt reçoivent le nouveau tag."
  type        = string
}

variable "pass_role_arns" {
  description = "Rôles référencés par les modèles (rôles d'exécution, rôles de tâche de api et media) : iam:PassRole vers ECS."
  type        = list(string)

  validation {
    condition     = length(var.pass_role_arns) > 0 && alltrue([for a in var.pass_role_arns : can(regex("^arn:aws:iam::[0-9]{12}:role/ev-[a-z0-9-]+$", a))])
    error_message = "pass_role_arns : nos rôles seulement (role/ev-*)."
  }
}

variable "revision_tags" {
  description = "Étiquettes posées sur chaque révision enregistrée (Project = eventide…)."
  type        = map(string)

  validation {
    condition     = lookup(var.revision_tags, "Project", "") == "eventide"
    error_message = "revision_tags doit contenir Project = eventide."
  }
}

variable "kms_key_arn" {
  description = "Clé KMS de l'environnement (journaux de la fonction)."
  type        = string
}

variable "log_retention_days" {
  description = "Rétention des journaux de la fonction (jours)."
  type        = number
  default     = 30
}
