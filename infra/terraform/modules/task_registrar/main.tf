# Task registrar of Eventide: a Lambda function, owned by Eventide, that registers a new
# revision of one of OUR task definition families (ev-<env>-api, -migrate, -jobs, -media) with a
# new image, from the exact RegisterTaskDefinition input written by Terraform (packaged with the
# code, never supplied by the caller). Closed list of family keys (variables.tf and the code).
#
# Why (shared account with CINAF, JobMinutes and Candidature Express, AGENTS.md rule 2): the
# GitHub deploy role only gets lambda:InvokeFunction on this function. It no longer calls
# ecs:DescribeTaskDefinition (only accepts "*": it could read the task definitions of the other
# platforms, plaintext environment variables included) nor ecs:RegisterTaskDefinition (a
# restriction to a family is not verified: the Service Authorization Reference and the ECS
# developer guide disagree). The code accepts only a family key of its own configuration and a
# commit SHA (files/handler.py, tested by tests/test_handler.py).
#
# Residual: this function's role holds ecs:RegisterTaskDefinition on "*" for the same reason;
# only Terraform (an apply approved by the product owner) can change the code that uses it.
# No VPC (no NAT traffic), no reserved concurrency (taken from the account's unreserved pool:
# a few invocations per deployment).

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  region        = data.aws_region.current.region
  account_id    = data.aws_caller_identity.current.account_id
  function_name = "${var.name}-task-registrar"
  log_group     = "/aws/lambda/${local.function_name}"

  config = {
    family_prefix    = "${var.name}-"
    image_repository = var.image_repository_url
    templates        = var.register_inputs
    tags             = var.revision_tags
  }

  policy = {
    Version = "2012-10-17"
    Statement = [
      {
        # No verified resource-level restriction for this action (see above): the family is
        # fixed by the packaged templates and checked by the code before the call.
        Sid      = "RegisterOwnFamiliesOnly"
        Effect   = "Allow"
        Action   = ["ecs:RegisterTaskDefinition"]
        Resource = "*"
      },
      {
        # Tags of the new revision (Project = eventide), on our families only.
        Sid      = "TagNewRevisions"
        Effect   = "Allow"
        Action   = ["ecs:TagResource"]
        Resource = "arn:aws:ecs:${local.region}:${local.account_id}:task-definition/${var.name}-*:*"
        Condition = {
          StringEquals = { "ecs:CreateAction" = "RegisterTaskDefinition" }
        }
      },
      {
        # Execution roles, and the task roles of api and media (named by their templates).
        Sid      = "PassOurExecutionRoles"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = var.pass_role_arns
        Condition = {
          StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" }
        }
      },
      {
        Sid      = "OwnLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${local.region}:${local.account_id}:log-group:${local.log_group}:log-stream:*"
      },
    ]
  }
}

data "archive_file" "package" {
  type        = "zip"
  output_path = "${path.module}/.build/${local.function_name}.zip"

  source {
    content  = file("${path.module}/files/handler.py")
    filename = "handler.py"
  }

  source {
    content  = jsonencode(local.config)
    filename = "config.json"
  }
}

resource "aws_cloudwatch_log_group" "this" {
  name              = local.log_group
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = local.function_name
  description        = "Registraire des definitions de tache Eventide (${var.name}) : familles ${var.name}-* seulement"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy" "this" {
  name   = "register-own-task-definitions"
  role   = aws_iam_role.this.id
  policy = jsonencode(local.policy)
}

resource "aws_lambda_function" "this" {
  function_name    = local.function_name
  description      = "Eventide : nouvelle revision d une famille ${var.name}-* (image du commit deploye)"
  role             = aws_iam_role.this.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  architectures    = ["arm64"]
  memory_size      = 128
  timeout          = 30
  filename         = data.archive_file.package.output_path
  source_code_hash = data.archive_file.package.output_base64sha256

  depends_on = [aws_cloudwatch_log_group.this, aws_iam_role_policy.this]
}
