variable "name" {
  description = "Préfixe de nommage (ev-prod, ev-preprod)."
  type        = string
}

variable "kms_key_arn" {
  description = "Clé KMS de l'environnement (chiffrement du sujet SNS)."
  type        = string
}

variable "alert_emails" {
  description = "Destinataires des alertes (confirmation par e-mail requise)."
  type        = list(string)
  default     = []
}

variable "alb_arn_suffix" {
  description = "Suffixe d'ARN de l'ALB partagé (dimension CloudWatch)."
  type        = string
}

variable "target_group_arn_suffix" {
  description = "Suffixe d'ARN de NOTRE groupe cible (null sans domaine : pas d'alarme de groupe cible)."
  type        = string
  default     = null
}

variable "ecs_cluster_name" {
  description = "Nom de notre cluster ECS."
  type        = string
}

variable "ecs_cluster_arn" {
  description = "ARN de notre cluster ECS (alerte d'échec des tâches ponctuelles)."
  type        = string
}

variable "ecs_service_names" {
  description = "Services surveillés ({ api = \"api\" }, vide sans domaine)."
  type        = map(string)
  default     = {}
}

variable "app_log_group_names" {
  description = "Groupes de journaux de l'application ({ api, jobs })."
  type        = map(string)
}

variable "target_5xx_threshold" {
  description = "Erreurs 5xx de l'API sur 5 minutes."
  type        = number
  default     = 10
}

variable "latency_p95_threshold_seconds" {
  description = "Temps de réponse p95 de l'API (s), appel au modèle compris."
  type        = number
  default     = 4
}

variable "ecs_utilization_threshold" {
  description = "Seuil CPU et mémoire des tâches (%)."
  type        = number
  default     = 85
}

variable "model_unavailable_threshold" {
  description = "Échecs d'appel au modèle sur 5 minutes."
  type        = number
  default     = 10
}

variable "log_ingestion_gb_per_day" {
  description = "Alarme si un groupe de journaux ingère plus de N Go (10^9 octets) en 24 h (≈ 0,50 USD/Go)."
  type        = number
  default     = 0.5
}

variable "rds_alarms_enabled" {
  description = "Alarmes sur l'instance PostgreSQL partagée (métriques lues seulement). false par défaut : Candidature Express les a déjà."
  type        = bool
  default     = false
}

variable "rds_instance_id" {
  description = "Identifiant de l'instance partagée."
  type        = string
}

variable "rds_cpu_threshold" {
  description = "Seuil CPU de l'instance partagée (%)."
  type        = number
  default     = 70
}

variable "rds_connections_threshold" {
  description = "Seuil de connexions de l'instance partagée (toutes applications)."
  type        = number
  default     = 300
}
