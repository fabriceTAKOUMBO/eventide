variable "name" {
  description = "Préfixe de nommage (ev-prod, ev-preprod)."
  type        = string
}

variable "cluster_arn" {
  description = "ARN du cluster ECS."
  type        = string
}

variable "cluster_name" {
  description = "Nom du cluster ECS."
  type        = string
}

variable "task_family" {
  description = "Famille de définition de tâche à lancer (api)."
  type        = string
}

variable "container_name" {
  description = "Conteneur dont la commande est remplacée."
  type        = string
  default     = "api"
}

variable "subnet_ids" {
  description = "Sous-réseaux privés des tâches."
  type        = list(string)
}

variable "security_group_ids" {
  description = "Groupes de sécurité des tâches."
  type        = list(string)
}

variable "pass_role_arns" {
  description = "Rôles (exécution et tâche) que le planificateur transmet à ECS."
  type        = list(string)
}

variable "timezone" {
  description = "Fuseau horaire des expressions cron."
  type        = string
  default     = "Europe/Brussels"
}

variable "enabled" {
  description = "Active les planifications (désactivable pendant un incident ou une restauration)."
  type        = bool
  default     = true
}

variable "jobs" {
  description = "Tâches planifiées : nom => { description, schedule (cron EventBridge), command (null = commande de la définition), enabled, task_family et container_name (facultatifs, sinon ceux du module), flexible_window_minutes (15 par défaut, 0 = heure exacte) }."
  type = map(object({
    description             = string
    schedule                = string
    command                 = optional(list(string))
    enabled                 = optional(bool, true)
    task_family             = optional(string)
    container_name          = optional(string)
    flexible_window_minutes = optional(number, 15)
  }))
}

variable "capacity_provider" {
  description = "Fournisseur de capacité des tâches planifiées : FARGATE ou FARGATE_SPOT (moins cher ; une tâche interrompue est relancée par la planification suivante ou l'alerte d'échec)."
  type        = string
  default     = "FARGATE"

  validation {
    condition     = contains(["FARGATE", "FARGATE_SPOT"], var.capacity_provider)
    error_message = "capacity_provider doit valoir FARGATE ou FARGATE_SPOT."
  }
}
