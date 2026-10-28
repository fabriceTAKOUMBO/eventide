# Registraire des définitions de tâche : une fonction à nous, sans VPC, dont le rôle n'a que
# les droits nécessaires ; le nom et les étiquettes sont ceux d'Eventide. Sans AWS (fournisseurs
# simulés). Le code de la fonction est testé par tests/test_handler.py.

mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { region = "us-east-1", name = "us-east-1" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "466494951409" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

mock_provider "archive" {}

variables {
  name = "ev-prod"
  register_inputs = {
    api = {
      family               = "ev-prod-api"
      containerDefinitions = [{ name = "api", image = "466494951409.dkr.ecr.us-east-1.amazonaws.com/ev-prod-api:bootstrap" }]
    }
  }
  image_repository_url = "466494951409.dkr.ecr.us-east-1.amazonaws.com/ev-prod-api"
  pass_role_arns       = ["arn:aws:iam::466494951409:role/ev-prod-api-execution"]
  revision_tags        = { Project = "eventide", Environment = "prod" }
  kms_key_arn          = "arn:aws:kms:us-east-1:466494951409:key/00000000-0000-0000-0000-000000000000"
}

run "registrar_is_ours_and_minimal" {
  command = plan

  assert {
    condition     = aws_lambda_function.this.function_name == "ev-prod-task-registrar" && aws_iam_role.this.name == "ev-prod-task-registrar"
    error_message = "Fonction et rôle nommés ev-<env>-task-registrar."
  }
  assert {
    condition     = length(aws_lambda_function.this.vpc_config) == 0
    error_message = "Aucun VPC : la fonction ne passe ni par le réseau ni par la NAT partagés."
  }
  assert {
    condition     = join(",", output.policy_actions) == "ecs:RegisterTaskDefinition,ecs:TagResource,iam:PassRole,logs:CreateLogStream,logs:PutLogEvents"
    error_message = "Droits du registraire : enregistrer, étiqueter, passer nos rôles, écrire ses journaux ; rien d'autre (pas de DescribeTaskDefinition)."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.this.policy).Statement[1].Resource == "arn:aws:ecs:us-east-1:466494951409:task-definition/ev-prod-*:*"
    error_message = "Étiquetage limité à nos familles."
  }
  assert {
    condition     = join(",", jsondecode(aws_iam_role_policy.this.policy).Statement[2].Resource) == "arn:aws:iam::466494951409:role/ev-prod-api-execution"
    error_message = "PassRole limité à nos rôles d'exécution."
  }
}

run "foreign_name_is_refused" {
  command = plan

  variables {
    name = "ce-prod"
  }

  expect_failures = [var.name]
}

run "revisions_must_carry_project_eventide" {
  command = plan

  variables {
    revision_tags = { Project = "cinaf" }
  }

  expect_failures = [var.revision_tags]
}
