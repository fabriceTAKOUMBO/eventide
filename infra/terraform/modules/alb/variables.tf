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

  # Both rules of one environment in the same block (400-409 or 420-429), never equal.
  validation {
    condition = (
      var.listener_rule_priorities.api != var.listener_rule_priorities.web &&
      floor(var.listener_rule_priorities.api / 10) == floor(var.listener_rule_priorities.web / 10)
    )
    error_message = "Les deux priorités d'un environnement sont distinctes et dans la même plage (400-409 ou 420-429)."
  }
}

variable "domain" {
  description = "Domaine d'Eventide : chaque nom d'hôte de nos règles est ce domaine ou l'un de ses sous-domaines (jamais un nom d'une autre plateforme)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.domain))
    error_message = "domain : un domaine en minuscules, sans joker (ex. eventide.app)."
  }
}

# Hostnames of our listener rules: exact names (no wildcard), inside our domain only. The shared
# listener serves CINAF, JobMinutes and Candidature Express: a rule must never match their hosts.
variable "api_hostname" {
  description = "Hôte de l'API (api.<domaine>)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.api_hostname))
    error_message = "api_hostname : un nom d'hôte exact en minuscules, sans joker (* ou ?)."
  }
}

variable "web_hostnames" {
  description = "Hôtes des pages web (<domaine>, www.<domaine>), servis par le même service."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.web_hostnames) <= 4 && alltrue([for h in var.web_hostnames : can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", h))])
    error_message = "web_hostnames : au plus 4 noms d'hôte exacts en minuscules, sans joker (* ou ?)."
  }
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
