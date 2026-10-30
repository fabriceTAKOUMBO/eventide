# --- Compte et région ---

variable "aws_account_id" {
  description = "Compte AWS principal qui héberge CINAF, JobMinutes et Candidature Express (garde-fou : tout autre compte est refusé)."
  type        = string
}

variable "region" {
  description = "Région de calcul : celle de l'ALB et de l'instance PostgreSQL partagés."
  type        = string
  default     = "us-east-1"
}

# --- Domaine (pas encore acheté : vérification de la marque en cours) ---

variable "domain_name" {
  description = "Domaine d'Eventide ; sa zone Route 53 publique est cherchée par son nom. Vide (par défaut) = aucune entrée publique : ni certificat, ni règle d'écouteur, ni DNS, ni service api."
  type        = string
  default     = ""

  validation {
    condition     = var.domain_name == "" || can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.domain_name))
    error_message = "domain_name : vide, ou un domaine en minuscules (ex. eventide.app)."
  }

  # Never a domain of another platform of the shared account (nor one of its subdomains or
  # parents): our listener rules would capture its traffic and our records land in its zone.
  validation {
    condition = alltrue([
      for d in ["cinaf.tv", "jobminutes.com", "candidatureexpress.com"] :
      !(var.domain_name == d || endswith(var.domain_name, ".${d}") || endswith(d, ".${var.domain_name}"))
    ])
    error_message = "domain_name : domaine d'une autre plateforme du compte (CINAF, JobMinutes, Candidature Express), refusé."
  }
}

variable "manage_caa" {
  description = "Crée l'enregistrement CAA du domaine (seule Amazon émet des certificats)."
  type        = bool
  default     = true
}

# --- Infrastructure partagée (identifiants lus par des sources de données, jamais modifiés) ---

variable "vpc_id" {
  description = "VPC partagé de CINAF."
  type        = string
}

variable "app_subnet_ids" {
  description = "Sous-réseaux privés « application » partagés (route par défaut vers la NAT de CINAF)."
  type        = list(string)
}

variable "alb_name" {
  description = "Nom de l'ALB public partagé ; son écouteur 443 reçoit nos règles et notre certificat."
  type        = string
  default     = "cinaf-streaming-prod-alb"
}

variable "rds_instance_identifier" {
  description = "Instance PostgreSQL partagée."
  type        = string
  default     = "cinaf-streaming-prod-postgres"
}

variable "rds_security_group_id" {
  description = "Groupe de sécurité de l'instance partagée : on y ajoute UNE règle d'entrée 5432 par environnement, depuis nos tâches."
  type        = string
}

variable "app_subnet_min_free_ips" {
  description = "Adresses IP libres exigées au plan dans chaque sous-réseau « application » partagé."
  type        = number
  default     = 30
}

variable "listener_priority_base" {
  description = "Début de la plage de priorités réservée à Eventide sur l'écouteur partagé (prod : 400-409 ; préproduction : 420-429). CINAF et JobMinutes utilisent 100 à 210, Candidature Express 300 à 329."
  type        = number
  default     = 400

  validation {
    condition     = var.listener_priority_base == 400
    error_message = "La plage d'Eventide est 400-409 (production) et 420-429 (préproduction) : listener_priority_base = 400."
  }
}

# --- Environnements ---

variable "preprod_enabled" {
  description = "Crée la préproduction (Fargate Spot, arrêtée hors 8 h-20 h en semaine). false par défaut."
  type        = bool
  default     = false
}

# --- Clés KMS ---

variable "kms_restrict_decrypt" {
  description = "Refuse le déchiffrement (secrets, sauvegardes, journaux) à tout principal hors de nos rôles ev-<env>-* et des rôles d'administration."
  type        = bool
  default     = true
}

variable "kms_admin_principal_arns" {
  description = "Motifs d'ARN des rôles d'administration autorisés à déchiffrer (dont la session Terraform). Vide = Identity Center AdministratorAccess de ce compte."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for p in var.kms_admin_principal_arns : startswith(p, "arn:")])
    error_message = "Chaque motif de kms_admin_principal_arns doit être un ARN."
  }
}

variable "kms_extra_decrypt_principal_arns" {
  description = "Principaux supplémentaires autorisés à déchiffrer."
  type        = list(string)
  default     = []
}

# --- Application ---

variable "play_package_name" {
  description = "Paquet Android déclaré dans la Play Console (PLAY_PACKAGE_NAME)."
  type        = string
  default     = ""
}

variable "android_cert_fingerprints" {
  description = "Empreintes SHA-256 du certificat de signature de l'application (Play App Signing), pour assetlinks.json."
  type        = list(string)
  default     = []
}

variable "google_oauth_client_ids" {
  description = "Identifiants clients OAuth Google (publics) acceptés pour la liaison du compte et la connexion au tableau de bord (audience des jetons d'identité)."
  type        = list(string)
  default     = []
}

variable "google_web_client_id" {
  description = "Client OAuth Google « Application Web » du bouton de connexion du tableau de bord /tableau/ (public, GOOGLE_WEB_CLIENT_ID), origines JavaScript autorisées : https://<domaine> et https://www.<domaine> (runbook tableau-de-bord.md). Vide = non configuré. À ajouter aussi à google_oauth_client_ids."
  type        = string
  default     = ""

  validation {
    condition     = var.google_web_client_id == "" || can(regex("^[0-9]+-[a-z0-9]+\\.apps\\.googleusercontent\\.com$", var.google_web_client_id))
    error_message = "google_web_client_id : identifiant de client OAuth Google (<numéro>-<code>.apps.googleusercontent.com)."
  }
  validation {
    condition     = var.google_web_client_id == "" || contains(var.google_oauth_client_ids, var.google_web_client_id)
    error_message = "google_web_client_id doit aussi figurer dans google_oauth_client_ids : l'API vérifie l'audience du jeton de connexion du tableau de bord avec cette liste."
  }
}

variable "rtdn_service_account_email" {
  description = "Compte de service Google qui signe les envois Pub/Sub push des notifications Google Play."
  type        = string
  default     = ""
}

variable "legal_publisher_name" {
  description = "Éditeur affiché sur la politique de confidentialité."
  type        = string
  default     = ""
}

variable "legal_contact_email" {
  description = "Adresse de contact de la politique de confidentialité."
  type        = string
  default     = ""
}

variable "api_extra_environment" {
  description = "Variables non secrètes supplémentaires de l'API (production)."
  type        = map(string)
  default     = {}
}

variable "content_custom_domain" {
  description = "Sert le contenu sur cdn.<domaine> (exige domain_name) plutôt que sur *.cloudfront.net."
  type        = bool
  default     = false
}

variable "rds_alarms_enabled" {
  description = "Alarmes sur la charge de l'instance partagée (métriques lues seulement, aucune action sur l'instance) : CPU, connexions, mémoire, disque, crédits CPU (AGENTS.md, règle 5)."
  type        = bool
  default     = true
}

# --- Exploitation et coûts ---

variable "alert_emails" {
  description = "Destinataires des alertes (confirmation par e-mail requise)."
  type        = list(string)
  default     = []
}

variable "budget_emails" {
  description = "Destinataires des alertes de budget et d'anomalies (e-mail direct)."
  type        = list(string)
  default     = []
}

variable "cost_guardrails_enabled" {
  description = "Budget mensuel, budget du contenu et détection d'anomalies, filtrés sur l'étiquette Project = eventide."
  type        = bool
  default     = true
}

variable "monthly_budget_usd" {
  description = "Budget mensuel (USD) d'Eventide dans ce compte (alertes à 50, 80, 100 % et prévision 100 %)."
  type        = number
  default     = 60
}

variable "content_budget_usd" {
  description = "Budget mensuel (USD) du contenu (CloudFront et S3)."
  type        = number
  default     = 30
}

variable "anomaly_threshold_usd" {
  description = "Impact (USD) à partir duquel une anomalie de coût est signalée."
  type        = number
  default     = 10
}

# --- GitHub ---

variable "github_repository" {
  description = "Dépôt GitHub autorisé à déployer."
  type        = string
  default     = "fabriceTAKOUMBO/eventide"
}

variable "github_subject_repository" {
  description = "Dépôt tel qu'il figure dans le sujet OIDC de GitHub, au format immuable propriétaire@id/nom@id (dépôts créés après juillet 2026), relevé par `gh api repos/fabriceTAKOUMBO/eventide/actions/oidc/customization/sub` (sub_claim_prefix)."
  type        = string
}
