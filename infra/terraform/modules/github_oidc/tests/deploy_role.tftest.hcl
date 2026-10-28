# Rôle de déploiement GitHub : tous ses droits portent sur des ressources d'Eventide (sauf le
# jeton ECR, propre au compte) ; il ne lit ni n'écrit aucune définition de tâche lui-même
# (pas d'ecs:DescribeTaskDefinition ni d'ecs:RegisterTaskDefinition : registraire à nous).
# Sans AWS (fournisseur simulé).

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

variables {
  name                        = "ev-prod"
  oidc_provider_arn           = "arn:aws:iam::466494951409:oidc-provider/token.actions.githubusercontent.com"
  github_repository           = "fabriceTAKOUMBO/eventide"
  github_subject_repository   = "fabriceTAKOUMBO@75751595/eventide@1234567890"
  github_environment          = "prod"
  ecr_repository_arns         = ["arn:aws:ecr:us-east-1:466494951409:repository/ev-prod-api"]
  ecs_cluster_arn             = "arn:aws:ecs:us-east-1:466494951409:cluster/ev-prod"
  ecs_cluster_name            = "ev-prod"
  ecs_service_arns            = ["arn:aws:ecs:us-east-1:466494951409:service/ev-prod/api"]
  task_registrar_function_arn = "arn:aws:lambda:us-east-1:466494951409:function:ev-prod-task-registrar"
  migrate_task_family         = "ev-prod-migrate"
  pass_role_arns              = ["arn:aws:iam::466494951409:role/ev-prod-api-execution", "arn:aws:iam::466494951409:role/ev-prod-migrate-execution"]
  deploy_config_parameter_arn = "arn:aws:ssm:us-east-1:466494951409:parameter/eventide/prod/deploy/config"
  image_tag_parameter_arn     = "arn:aws:ssm:us-east-1:466494951409:parameter/eventide/prod/deploy/image-tag"
  jobs_log_group_arn          = "arn:aws:logs:us-east-1:466494951409:log-group:/ecs/ev-prod/jobs"
}

run "deploy_role_never_touches_a_task_definition_itself" {
  command = plan

  assert {
    condition = length(setintersection(
      toset(flatten([for s in output.deploy_policy.Statement : s.Action])),
      toset(["ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition", "ecs:DeregisterTaskDefinition", "ecs:ListTaskDefinitions", "ecs:*", "*"]),
    )) == 0
    error_message = "Le rôle de déploiement ne doit ni lire ni écrire de définition de tâche (registraire d'Eventide)."
  }
  assert {
    condition = alltrue([
      for s in output.deploy_policy.Statement : s.Resource != "*" if s.Sid != "EcrAuth"
    ])
    error_message = "Seul ecr:GetAuthorizationToken porte sur « * »."
  }
  assert {
    condition = alltrue(flatten([
      for s in output.deploy_policy.Statement : [
        for r in flatten([s.Resource]) : can(regex("(/|:|function:)ev-|parameter/eventide/", r))
      ] if s.Sid != "EcrAuth"
    ]))
    error_message = "Chaque ressource du rôle de déploiement est une ressource d'Eventide (ev-*, /eventide/*)."
  }
  assert {
    condition     = contains(flatten([for s in output.deploy_policy.Statement : s.Action]), "lambda:InvokeFunction")
    error_message = "Les révisions passent par le registraire."
  }
}

run "foreign_service_is_refused" {
  command = plan

  variables {
    ecs_service_arns = ["arn:aws:ecs:us-east-1:466494951409:service/cinaf-streaming-prod/api"]
  }

  expect_failures = [var.ecs_service_arns]
}

run "foreign_pass_role_is_refused" {
  command = plan

  variables {
    pass_role_arns = ["arn:aws:iam::466494951409:role/ce-prod-api-execution"]
  }

  expect_failures = [var.pass_role_arns]
}
