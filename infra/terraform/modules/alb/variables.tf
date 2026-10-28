variable "name" {
  description = "Préfixe de nommage (ev-prod, ev-preprod)."
  type        = string
}

variable "vpc_id" {
  description = "VPC partagé."
  type        = string
}

variable "https_listener_arn" {
  description = "Écouteur HTTPS 443 de l'ALB partagé : on y AJOUTE nos règles et notre certificat."
  type        = string
}

variable "listener_rule_priorities" {
  description = "Priorités de nos règles (plage réservée à Eventide : 400-409 prod, 420-429 préproduction)."
  type = object({
    api = number
    web = number
  })

  validation {
    condition = alltrue([
      for p in [var.listener_rule_priorities.api, var.listener_rule_priorities.web] :
      (p >= 400 && p <= 409) || (p >= 420 && p <= 429)
    ])
    error_message = "Les priorités d'Eventide sont dans 400-409 (production) ou 420-429 (préproduction)."
  }
}

variable "api_hostname" {
  description = "Hôte de l'API (api.<domaine>)."
  type        = string
}

variable "web_hostnames" {
  description = "Hôtes des pages web (<domaine>, www.<domaine>), servis par le même service."
  type        = list(string)
  default     = []
}

variable "certificate_arn" {
  description = "Certificat ACM validé couvrant les hôtes."
  type        = string
}

variable "zone_id" {
  description = "Zone Route 53 du domaine (la nôtre)."
  type        = string
}

variable "api_port" {
  description = "Port du conteneur API."
  type        = number
  default     = 8000
}

variable "health_check_path" {
  description = "Contrôle de santé de l'ALB (contrat § 10, sans base de données)."
  type        = string
  default     = "/v1/health"
}
