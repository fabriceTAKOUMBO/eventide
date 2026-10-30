variable "name" {
  description = "Préfixe de nommage (ev-prod, ev-preprod)."
  type        = string
}

variable "account_id" {
  description = "Identifiant du compte AWS (suffixe du nom du bucket, unique au monde)."
  type        = string
}

variable "secret_prefix" {
  description = "Préfixe des secrets (eventide/prod) : <prefix>/cloudfront-private-key."
  type        = string
}

variable "kms_key_arn" {
  description = "Clé KMS de l'environnement (chiffrement du secret de la clé privée)."
  type        = string
}

variable "secret_recovery_window_days" {
  description = "Délai de récupération du secret supprimé."
  type        = number
  default     = 30
}

variable "domain_name" {
  description = "Nom public du contenu (cdn.<domaine>). Vide = nom *.cloudfront.net de la distribution (aucun certificat, aucun enregistrement DNS)."
  type        = string
  default     = ""

  validation {
    condition     = var.domain_name == "" || can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.domain_name))
    error_message = "domain_name : vide, ou un nom d'hôte en minuscules, sans joker."
  }
}

variable "zone_id" {
  description = "Zone Route 53 du domaine (exigée avec domain_name)."
  type        = string
  default     = null
}

variable "price_class" {
  description = "Classe de prix CloudFront. PriceClass_100 (Amérique du Nord et Europe) : public francophone d'Europe."
  type        = string
  default     = "PriceClass_100"

  validation {
    condition     = contains(["PriceClass_All", "PriceClass_200", "PriceClass_100"], var.price_class)
    error_message = "price_class : PriceClass_All, PriceClass_200 ou PriceClass_100."
  }
}

variable "distribution_enabled" {
  description = "Coupe-circuit : false désactive la distribution (plus aucun contenu téléchargeable)."
  type        = bool
  default     = true
}

variable "noncurrent_version_days" {
  description = "Jours avant l'effacement d'une ancienne version d'un objet remplacé ou supprimé."
  type        = number
  default     = 30
}

variable "cors_allowed_origins" {
  description = "Origines web autorisées à envoyer un fichier au bucket (formulaire POST signé du tableau de bord) : https://<domaine> et https://www.<domaine> en production. Vide = aucune règle CORS (pas de domaine, pas de tableau de bord)."
  type        = list(string)
  default     = []

  # Exact HTTPS origins only: no wildcard, no path, no plain HTTP.
  validation {
    condition     = alltrue([for o in var.cors_allowed_origins : can(regex("^https://[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", o))])
    error_message = "cors_allowed_origins : origines https://<nom d'hôte> exactes seulement (ni joker, ni chemin, ni http)."
  }
}

variable "cors_max_age_seconds" {
  description = "Durée de mise en cache, par le navigateur, de la réponse CORS préalable (secondes)."
  type        = number
  default     = 600

  validation {
    condition     = var.cors_max_age_seconds >= 0 && var.cors_max_age_seconds <= 3600
    error_message = "cors_max_age_seconds : entre 0 et 3600."
  }
}

variable "upload_expiration_days" {
  description = "Jours avant l'effacement des fichiers sources envoyés par le tableau de bord (préfixe uploads/)."
  type        = number
  default     = 7

  validation {
    condition     = var.upload_expiration_days >= 1 && var.upload_expiration_days <= 30
    error_message = "upload_expiration_days : entre 1 et 30."
  }
}

variable "force_destroy" {
  description = "Autorise la suppression d'un bucket non vide (préproduction ou retrait volontaire)."
  type        = bool
  default     = false
}

variable "alarm_topic_arn" {
  description = "Sujet SNS de nos alertes (vide = alarmes sans notification)."
  type        = string
  default     = ""
}

variable "requests_alarm_per_day" {
  description = "Seuil d'alarme : requêtes de contenu par jour."
  type        = number
  default     = 200000
}

variable "bytes_alarm_gb_per_day" {
  description = "Seuil d'alarme : Go diffusés par jour (≈ 15 Mo par session à froid : 30 Go ≈ 2 000 sessions)."
  type        = number
  default     = 30
}

variable "error_rate_alarm_percent" {
  description = "Seuil d'alarme du taux d'erreurs 5xx (%, sur 15 minutes) ; le seuil 4xx est 10 fois plus haut."
  type        = number
  default     = 1
}

variable "budget_enabled" {
  description = "Crée le budget mensuel du contenu (alerte seulement)."
  type        = bool
  default     = true
}

variable "budget_limit_usd" {
  description = "Plafond d'alerte mensuel (USD) de CloudFront et S3 pour Eventide."
  type        = number
  default     = 30
}

variable "budget_emails" {
  description = "Destinataires des alertes du budget. Vide = pas de budget."
  type        = list(string)
  default     = []
}
