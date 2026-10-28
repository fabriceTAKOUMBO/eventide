# Pile d'amorçage d'Eventide (une fois par compte AWS) : bucket S3 de l'état Terraform des
# environnements, chiffré par une clé KMS dédiée, versionné, accès public bloqué, TLS
# obligatoire. Verrouillage par le fichier de verrou natif S3 (use_lockfile), sans DynamoDB.
#
# L'état des environnements contient des secrets en clair (mots de passe PostgreSQL, clé Django,
# clé privée CloudFront). Le compte est PARTAGÉ avec CINAF, JobMinutes et Candidature Express :
# la clé et le bucket refusent donc explicitement la lecture, l'écriture, la suppression et le
# déchiffrement des objets à tout principal hors de state_access_principal_arns (par défaut :
# rôles Identity Center AdministratorAccess), même s'il a s3:* et kms:* par IAM.
# L'administration (PutKeyPolicy, PutBucketPolicy, ListBucket) n'est pas refusée : un
# administrateur du compte peut toujours corriger ces règles.
#
# Cette pile garde son propre état en local (ignoré par git) : ces refus ne peuvent pas la
# bloquer elle-même. Même modèle que Candidature Express (infra/terraform/bootstrap).

terraform {
  required_version = ">= 1.10, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.68"
    }
  }
}

provider "aws" {
  region              = var.region
  allowed_account_ids = [var.aws_account_id]

  default_tags {
    tags = {
      Project     = "eventide"
      Environment = "shared"
      Component   = "terraform-state"
      ManagedBy   = "terraform"
      Repository  = "fabriceTAKOUMBO/eventide"
      Hosting     = "shared"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  bucket_name = coalesce(var.state_bucket_name, "eventide-tfstate-${data.aws_caller_identity.current.account_id}")

  # Seuls principaux qui lisent, écrivent et déchiffrent l'état. Le chemin du rôle contient la
  # région d'Identity Center quand elle n'est pas us-east-1 (…/sso.amazonaws.com/eu-north-1/…) :
  # le premier joker la couvre.
  state_access_principal_arns = length(var.state_access_principal_arns) > 0 ? var.state_access_principal_arns : [
    "arn:aws:iam::${var.aws_account_id}:role/aws-reserved/sso.amazonaws.com/*AWSReservedSSO_AdministratorAccess_*",
  ]

  # Mêmes motifs en expressions régulières (contrôle de la session ci-dessous).
  state_access_principal_regexes = [
    for p in local.state_access_principal_arns :
    "^${replace(replace(replace(p, "/([.+^$(){}|\\[\\]\\\\])/", "\\$1"), "*", ".*"), "?", ".")}$"
  ]
}

data "aws_iam_policy_document" "kms" {
  statement {
    sid       = "AccountAdministration"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  # Refus explicite du déchiffrement de l'état à tout principal IAM hors de la liste, même avec
  # kms:* par IAM (rôles des autres applications du compte).
  statement {
    sid       = "DenyDecryptOutsideStateAccessPrincipals"
    effect    = "Deny"
    actions   = ["kms:Decrypt", "kms:ReEncryptFrom"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    condition {
      test     = "StringNotLike"
      variable = "aws:PrincipalArn"
      values   = local.state_access_principal_arns
    }
    condition {
      test     = "Bool"
      variable = "aws:PrincipalIsAWSService"
      values   = ["false"]
    }
  }
}

resource "aws_kms_key" "state" {
  description             = "Chiffrement de l'etat Terraform d'Eventide"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.kms.json
}

resource "aws_kms_alias" "state" {
  name          = "alias/eventide-tfstate"
  target_key_id = aws_kms_key.state.key_id
}

resource "aws_s3_bucket" "state" {
  bucket = local.bucket_name

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_retention_days
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.state]
}

data "aws_iam_policy_document" "state" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # Objets de l'état (et fichiers de verrou <clé>.tflock) : lecture, écriture et suppression
  # réservées aux principaux de la liste. ListBucket, PutBucketPolicy et l'administration du
  # bucket ne sont pas refusés (correction toujours possible par un administrateur du compte).
  statement {
    sid       = "DenyObjectAccessOutsideStateAccessPrincipals"
    effect    = "Deny"
    actions   = ["s3:GetObject*", "s3:PutObject", "s3:DeleteObject*"]
    resources = ["${aws_s3_bucket.state.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "StringNotLike"
      variable = "aws:PrincipalArn"
      values   = local.state_access_principal_arns
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state.json

  depends_on = [aws_s3_bucket_public_access_block.state]
}

# Avertissement au plan si la session Terraform ne fait pas partie des principaux autorisés :
# elle créerait un bucket dont elle ne pourrait ni lire ni écrire l'état.
check "terraform_session_can_use_state" {
  data "aws_iam_session_context" "current" {
    arn = data.aws_caller_identity.current.arn
  }

  assert {
    condition     = anytrue([for re in local.state_access_principal_regexes : can(regex(re, data.aws_iam_session_context.current.issuer_arn))])
    error_message = "La session Terraform (${data.aws_iam_session_context.current.issuer_arn}) ne correspond à aucun motif de state_access_principal_arns (${join(", ", local.state_access_principal_arns)}) : après l'apply, elle ne pourra ni lire ni écrire l'état. Appliquer avec une session Identity Center AdministratorAccess, ou ajouter son ARN de rôle à state_access_principal_arns."
  }
}
