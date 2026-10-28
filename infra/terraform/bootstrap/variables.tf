variable "aws_account_id" {
  description = "Compte AWS cible (garde-fou : Terraform refuse tout autre compte). Compte principal partagé : 466494951409."
  type        = string
}

variable "region" {
  description = "Région du bucket d'état (celle de la pile, us-east-1)."
  type        = string
  default     = "us-east-1"
}

variable "state_bucket_name" {
  description = "Nom du bucket d'état (vide = eventide-tfstate-<compte>)."
  type        = string
  default     = ""
}

variable "state_access_principal_arns" {
  description = "Motifs d'ARN (StringLike sur aws:PrincipalArn) des SEULS principaux autorisés à lire, écrire, supprimer et déchiffrer les objets de l'état. Vide = rôles Identity Center du jeu d'autorisations AdministratorAccess de ce compte."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for p in var.state_access_principal_arns : startswith(p, "arn:")])
    error_message = "Chaque motif de state_access_principal_arns doit être un ARN (arn:aws:iam::…), jokers * et ? permis."
  }
}

variable "noncurrent_version_retention_days" {
  description = "Conservation des anciennes versions de l'état (jours)."
  type        = number
  default     = 90
}
