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

  validation {
    condition     = alltrue([for k, v in var.register_inputs : can(regex("^[a-z0-9]+$", k))])
    error_message = "Clés de famille : minuscules et chiffres (api, migrate, jobs)."
  }
}

variable "image_repository_url" {
  description = "Dépôt ECR de l'image (sans tag) : seuls les conteneurs de ce dépôt reçoivent le nouveau tag."
  type        = string
}

variable "pass_role_arns" {
  description = "Rôles d'exécution référencés par les modèles (iam:PassRole vers ECS)."
  type        = list(string)
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
