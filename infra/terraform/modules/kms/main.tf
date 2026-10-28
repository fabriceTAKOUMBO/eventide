# Clé KMS gérée par le client (CMK) de l'environnement Eventide : Secrets Manager, CloudWatch
# Logs, sujet SNS des alertes, bucket des sauvegardes. Rotation automatique annuelle.
# Même modèle que Candidature Express (modules/kms), sans ElastiCache (pas de cache).

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  partition  = data.aws_partition.current.partition
}

data "aws_iam_policy_document" "key" {
  # Administration de la clé par le compte (les politiques IAM décident ensuite).
  statement {
    sid       = "AccountAdministration"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }

  # CloudWatch Logs : uniquement pour les groupes de journaux de ce compte et de cette région.
  statement {
    sid = "CloudWatchLogs"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*",
    ]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["logs.${local.region}.amazonaws.com"]
    }
    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:*"]
    }
  }

  # Alarmes CloudWatch qui publient dans le sujet SNS chiffré : seulement des alarmes de ce
  # compte (aws:SourceAccount).
  statement {
    sid       = "AlarmPublishersToEncryptedSns"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }

  # Règles EventBridge qui publient dans le sujet SNS chiffré (tâche ponctuelle en échec) :
  # AWS ne prend pas en charge aws:SourceAccount dans une politique de clé pour EventBridge ; la
  # politique du sujet restreint déjà les éditeurs au compte.
  statement {
    sid       = "EventPublishersToEncryptedSns"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }

  # Compte PARTAGÉ : refus explicite du déchiffrement à tout principal IAM hors de la liste,
  # même s'il a kms:* par IAM (rôles de CINAF, JobMinutes, Candidature Express, utilisateurs
  # IAM). Les services AWS qui agissent en leur propre nom ne sont pas concernés.
  # L'administration de la clé reste au compte : la règle se corrige sans perte d'accès.
  dynamic "statement" {
    for_each = length(var.decrypt_allowed_principal_arns) > 0 ? [1] : []
    content {
      sid       = "DenyDecryptOutsideAllowedPrincipals"
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
        values   = var.decrypt_allowed_principal_arns
      }
      condition {
        test     = "Bool"
        variable = "aws:PrincipalIsAWSService"
        values   = ["false"]
      }
    }
  }
}

resource "aws_kms_key" "this" {
  description             = "${var.name} - chiffrement au repos (Secrets Manager, CloudWatch Logs, SNS, sauvegardes)"
  enable_key_rotation     = true
  rotation_period_in_days = 365
  deletion_window_in_days = var.deletion_window_in_days
  policy                  = data.aws_iam_policy_document.key.json
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.name}"
  target_key_id = aws_kms_key.this.key_id
}
