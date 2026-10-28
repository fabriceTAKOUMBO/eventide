# Rôle de déploiement GitHub Actions d'Eventide, par fédération OIDC (aucune clé AWS longue
# durée dans GitHub). Le fournisseur OIDC GitHub du compte EXISTE déjà (créé par JobMinutes,
# utilisé par Candidature Express) : il est seulement référencé, jamais créé ni modifié.
#
# Le rôle n'est assumable que par un job du dépôt fabriceTAKOUMBO/eventide qui cible
# l'environnement GitHub correspondant, depuis une branche autorisée (sujet personnalisé
# repo:<dépôt au format immuable>:environment:<env>:ref:<ref>). Ses droits se limitent au
# déploiement : pousser l'image dans NOTRE dépôt ECR, enregistrer des révisions de tâches,
# lancer NOTRE migration, mettre à jour NOTRE service, lire et écrire NOS paramètres SSM.
# Il ne peut ni modifier l'infrastructure ni lire les secrets applicatifs.
# Repris de Candidature Express (modules/github_oidc), sans la création du fournisseur.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  oidc_host  = "token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
    # Environnement GitHub ET branche vérifiés par AWS, indépendamment des protections côté
    # GitHub. Au format immuable, le dépôt est identifié par les numéros du propriétaire et du
    # dépôt : un dépôt recréé plus tard sous le même nom ne correspond pas.
    condition {
      test     = "StringLike"
      variable = "${local.oidc_host}:sub"
      values = [
        for ref in var.allowed_git_refs :
        "repo:${var.github_subject_repository}:environment:${var.github_environment}:ref:${ref}"
      ]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name                 = "${var.name}-github-deploy"
  description          = "GitHub Actions (${var.github_repository}, environnement ${var.github_environment}) : deploiement ECS Eventide"
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "deploy" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPushPull"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImageScanFindings",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = var.ecr_repository_arns
  }

  # DescribeTaskDefinition n'accepte que « * » ; pour RegisterTaskDefinition, une restriction par
  # famille n'est pas prouvée (même constat et même risque accepté que Candidature Express, ADR § 7).
  statement {
    sid       = "TaskDefinitions"
    actions   = ["ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition"]
    resources = ["*"]
  }

  statement {
    sid       = "RunMigrationTask"
    actions   = ["ecs:RunTask"]
    resources = ["arn:aws:ecs:${local.region}:${local.account_id}:task-definition/${var.migrate_task_family}:*"]
    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [var.ecs_cluster_arn]
    }
  }

  statement {
    sid       = "DescribeTasks"
    actions   = ["ecs:DescribeTasks"]
    resources = ["arn:aws:ecs:${local.region}:${local.account_id}:task/${var.ecs_cluster_name}/*"]
  }

  dynamic "statement" {
    for_each = length(var.ecs_service_arns) > 0 ? [1] : []
    content {
      sid       = "UpdateServices"
      actions   = ["ecs:DescribeServices", "ecs:UpdateService"]
      resources = var.ecs_service_arns
    }
  }

  statement {
    sid       = "PassTaskRoles"
    actions   = ["iam:PassRole"]
    resources = var.pass_role_arns
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  statement {
    sid       = "ReadDeployConfig"
    actions   = ["ssm:GetParameter"]
    resources = [var.deploy_config_parameter_arn, var.image_tag_parameter_arn]
  }

  statement {
    sid       = "RecordDeployedTag"
    actions   = ["ssm:PutParameter"]
    resources = [var.image_tag_parameter_arn]
  }

  statement {
    sid       = "ReadMigrationLogs"
    actions   = ["logs:GetLogEvents"]
    resources = ["${var.jobs_log_group_arn}:log-stream:migrate/*"]
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "deploy"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}
