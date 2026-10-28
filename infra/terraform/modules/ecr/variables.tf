variable "name" {
  description = "Préfixe de nommage (ev-prod, ev-preprod)."
  type        = string
}

variable "repositories" {
  description = "Dépôts à créer (suffixes)."
  type        = list(string)
  default     = ["api"]
}

variable "keep_last_images" {
  description = "Nombre d'images conservées par dépôt."
  type        = number
  default     = 20
}

variable "force_delete" {
  description = "Autorise la suppression d'un dépôt contenant des images (préproduction uniquement)."
  type        = bool
  default     = false
}
