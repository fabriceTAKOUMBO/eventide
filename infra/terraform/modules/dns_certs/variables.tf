variable "zone_id" {
  description = "Zone Route 53 existante du domaine (lue par la racine, jamais créée ici)."
  type        = string
}

variable "zone_name" {
  description = "Nom de la zone (le domaine)."
  type        = string
}

variable "certificate_domains" {
  description = "Noms couverts par le certificat (le premier est le nom principal)."
  type        = list(string)

  validation {
    condition     = length(var.certificate_domains) >= 1
    error_message = "Au moins un nom de domaine est requis."
  }
}

variable "caa_issuers" {
  description = "Autorités autorisées à émettre des certificats (CAA). Liste vide = pas de CAA."
  type        = list(string)
  default     = []
}
