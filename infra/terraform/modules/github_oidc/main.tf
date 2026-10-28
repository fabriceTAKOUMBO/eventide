# Rôle de déploiement GitHub Actions d'Eventide, par fédération OIDC (aucune clé AWS longue
# durée dans GitHub). Le fournisseur OIDC GitHub du compte EXISTE déjà (créé par JobMinutes,
# utilisé par Candidature Express) : il est seulement référencé, jamais créé ni modifié.
#
# Le rôle n'est assumable que par un job du dépôt fabriceTAKOUMBO/eventide qui cible
# l'environnement GitHub correspondant, depuis une branche autorisée (sujet personnalisé
# repo:<dépôt au format immuable>:environment:<env>:ref:<ref>). Ses droits se limitent au
# déploiement : pousser l'image dans NOTRE dépôt ECR, faire enregistrer des révisions de NOS
# familles par NOTRE registraire, lancer NOTRE migration, mettre à jour NOTRE service, lire et
# écrire NOS paramètres SSM. Il ne lit ni n'écrit aucune définition de tâche lui-même.
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

# Deploy permissions, every one on Eventide resources only (ARNs below), except
# ecr:GetAuthorizationToken (account-level token, usable only on repositories this policy
# allows). No ecs:DescribeTaskDefinition (only accepts "*": it would read the task definitions
# of CINAF, JobMinutes and Candidature Express, environment variables included) and no
# ecs:RegisterTaskDefinition: new revisions go through OUR task registrar
# (modules/task_registrar), which only registers our families from Terraform's templates.
# Written with jsonencode so that terraform test can check it without AWS (tests/).
locals {
  deploy_policy = {
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid      = "EcrAuth"
          Effect   = "Allow"
          Action   = ["ecr:GetAuthorizationToken"]
          Resource = "*"
        },
        {
          Sid    = "EcrPushPull"
          Effect = "Allow"
          Action = [
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
          Resource = var.ecr_repository_arns
        },
        {
          Sid      = "RegisterRevisionsThroughOurRegistrar"
          Effect   = "Allow"
          Action   = ["lambda:InvokeFunction"]
          Resource = [var.task_registrar_function_arn, "${var.task_registrar_function_arn}:*"]
        },
        {
          Sid      = "RunMigrationTask"
          Effect   = "Allow"
          Action   = ["ecs:RunTask"]
          Resource = ["arn:aws:ecs:${local.region}:${local.account_id}:task-definition/${var.migrate_task_family}:*"]
          Condition = {
            ArnEquals = { "ecs:cluster" = var.ecs_cluster_arn }
          }
        },
        {
          Sid      = "DescribeTasks"
          Effect   = "Allow"
          Action   = ["ecs:DescribeTasks"]
          Resource = ["arn:aws:ecs:${local.region}:${local.account_id}:task/${var.ecs_cluster_name}/*"]
        },
      ],
      length(var.ecs_service_arns) > 0 ? [
        {
          Sid      = "UpdateServices"
          Effect   = "Allow"
          Action   = ["ecs:DescribeServices", "ecs:UpdateService"]
          Resource = var.ecs_service_arns
        },
      ] : [],
      [
        {
          Sid      = "PassTaskRoles"
          Effect   = "Allow"
          Action   = ["iam:PassRole"]
          Resource = var.pass_role_arns
          Condition = {
            StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" }
          }
        },
        {
          Sid      = "ReadDeployConfig"
          Effect   = "Allow"
          Action   = ["ssm:GetParameter"]
          Resource = [var.deploy_config_parameter_arn, var.image_tag_parameter_arn]
        },
        {
          Sid      = "RecordDeployedTag"
          Effect   = "Allow"
          Action   = ["ssm:PutParameter"]
          Resource = [var.image_tag_parameter_arn]
        },
        {
          Sid      = "ReadMigrationLogs"
          Effect   = "Allow"
          Action   = ["logs:GetLogEvents"]
          Resource = ["${var.jobs_log_group_arn}:log-stream:migrate/*"]
        },
      ],
    )
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "deploy"
  role   = aws_iam_role.deploy.id
  policy = jsonencode(local.deploy_policy)
}
