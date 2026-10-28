terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
      # Fournisseur par défaut = us-east-1 : certificat d'une distribution CloudFront et
      # mesures CloudWatch de CloudFront (espace AWS/CloudFront) n'existent que là.
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0, < 5.0"
    }
  }
}
