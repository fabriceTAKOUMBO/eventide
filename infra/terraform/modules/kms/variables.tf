variable "name" {
  description = "Préfixe de nommage (ev-prod, ev-preprod) : alias alias/<name>."
  type        = string
}

variable "deletion_window_in_days" {
  description = "Délai avant suppression effective de la clé (7 à 30 jours)."
  type        = number
  default     = 30
}

variable "decrypt_allowed_principal_arns" {
  description = "Motifs d'ARN (StringLike) des seuls principaux IAM autorisés à déchiffrer avec la clé (nos rôles ev-<env>-*, Identity Center AdministratorAccess). Vide = aucune restriction."
  type        = list(string)
  default     = []
}
