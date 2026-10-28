# Budget de connexions PostgreSQL sur l'instance partagée (décision du PO : ev_app 10,
# ev_migrator 2, ev_backup 2, base 14) : le plan ÉCHOUE si l'autoscaling, chevauchement d'un
# déploiement compris, peut ouvrir plus de connexions que la limite de ev_app. Sans AWS.
#   terraform init -backend=false && terraform test

mock_provider "aws" {
  source = "./tests/mocks"
}

mock_provider "random" {}
mock_provider "tls" {}

variables {
  environment              = "prod"
  vpc_id                   = "vpc-0fbfe87b34e2b3903"
  app_subnet_ids           = ["subnet-03bb1c6197c29a369", "subnet-0fcd9f10a65ed1a16"]
  https_listener_arn       = "arn:aws:elasticloadbalancing:us-east-1:466494951409:listener/app/cinaf-streaming-prod-alb/0123456789abcdef/fedcba9876543210"
  alb_security_group_id    = "sg-04bbc536ff0295918"
  listener_rule_priorities = { api = 400, web = 401 }
  github_oidc_provider_arn = "arn:aws:iam::466494951409:oidc-provider/token.actions.githubusercontent.com"
  rds = {
    identifier        = "cinaf-streaming-prod-postgres"
    address           = "cinaf.example.rds.amazonaws.com"
    port              = 5432
    engine_version    = "16.3"
    master_username   = "app_admin"
    security_group_id = "sg-070b4372d5a95ad2d"
  }
  db_name                   = "eventide"
  db_roles                  = { app = "ev_app", migrator = "ev_migrator", backup = "ev_backup" }
  db_role_connection_limits = { app = 10, migrator = 2, backup = 2 }
  db_connection_budget      = 14
  api                       = { cpu = 256, memory = 512, min = 1, max = 2, workers = 1, threads = 8, db_pool_max = 2, requests = 600 }
  github_repository         = "fabriceTAKOUMBO/eventide"
  github_subject_repository = "fabriceTAKOUMBO@75751595/eventide@1234567890"
}

run "production_sizing_fits_the_budget" {
  command = plan

  assert {
    condition     = output.db_connection_limits.app_max == 10 && output.db_connection_limits.total == 14
    error_message = "2 tâches x 1 worker x pool 2 x 2 (déploiement) + 2 = 10 ; 10 + 2 + 2 = 14."
  }
}

run "one_more_task_fails" {
  command = plan

  variables {
    api = { cpu = 256, memory = 512, min = 1, max = 3, workers = 1, threads = 8, db_pool_max = 2, requests = 600 }
  }

  expect_failures = [terraform_data.connection_budget]
}

run "bigger_pool_fails" {
  command = plan

  variables {
    api = { cpu = 256, memory = 512, min = 1, max = 2, workers = 2, threads = 8, db_pool_max = 2, requests = 600 }
  }

  expect_failures = [terraform_data.connection_budget]
}

run "role_limits_above_the_database_budget_fail" {
  command = plan

  variables {
    db_role_connection_limits = { app = 12, migrator = 2, backup = 2 }
  }

  expect_failures = [terraform_data.connection_budget]
}
