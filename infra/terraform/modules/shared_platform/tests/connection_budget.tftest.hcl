# Budget de connexions PostgreSQL sur l'instance partagée (base 14 ; répartition proposée le
# 30 octobre 2026 avec la tâche media : ev_app 11, ev_migrator 2, ev_backup 1) : le plan ÉCHOUE
# si l'autoscaling, chevauchement d'un déploiement compris, tâches planifiées et tâche media
# comprises, peut ouvrir plus de connexions que la limite de ev_app. Sans AWS.
# Also: the standalone 5432 rule on the shared database security group (port 5432, source =
# our group only, never a CIDR) and the share of the account-wide Fargate vCPU quota, media
# task included.
#   terraform init -backend=false && terraform test

mock_provider "aws" {
  source = "./tests/mocks"
}

mock_provider "random" {}
mock_provider "tls" {}
mock_provider "archive" {}

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
  db_role_connection_limits = { app = 11, migrator = 2, backup = 1 }
  db_connection_budget      = 14
  api                       = { cpu = 256, memory = 512, min = 1, max = 2, workers = 1, threads = 8, db_pool_max = 2, requests = 600 }
  media_task                = { cpu = 1024, memory = 2048 }
  media_task_concurrency    = 1
  fargate_vcpu_budget       = 3
  github_repository         = "fabriceTAKOUMBO/eventide"
  github_subject_repository = "fabriceTAKOUMBO@75751595/eventide@1234567890"
}

run "production_sizing_fits_the_budget" {
  command = plan

  assert {
    condition     = output.db_connection_limits.app_max == 11 && output.db_connection_limits.media == 1 && output.db_connection_limits.total == 14
    error_message = "2 tâches x 1 worker x pool 2 x 2 (déploiement) + 2 (planifiées) + 1 (media) = 11 ; 11 + 2 + 1 = 14."
  }
  assert {
    condition     = output.shared_capacity.peak_fargate_vcpu == 2.75 && output.shared_capacity.media_task_vcpu == 1
    error_message = "Pic de production : (2 x 2 x 256 + 3 x 256 + 1 x 1024) / 1024 = 2,75 vCPU, dont 1 pour la tâche media."
  }
}

# The media task's connection is counted: with the split decided on 28 October 2026
# (10 / 2 / 2), the production sizing no longer fits.
run "media_connection_is_counted_in_the_app_role_limit" {
  command = plan

  variables {
    db_role_connection_limits = { app = 10, migrator = 2, backup = 2 }
  }

  expect_failures = [terraform_data.connection_budget]
}

# The media task is counted in the share of the account-wide Fargate quota: 2.75 > 2.5.
run "media_task_is_counted_in_the_vcpu_budget" {
  command = plan

  variables {
    fargate_vcpu_budget = 2.5
  }

  expect_failures = [terraform_data.shared_capacity_budget]
}

run "two_concurrent_media_tasks_exceed_both_budgets" {
  command = plan

  variables {
    media_task_concurrency = 2
  }

  # 8 + 2 + 2 = 12 > 11 connections; 1.75 + 2 = 3.75 > 3 vCPU.
  expect_failures = [terraform_data.connection_budget, terraform_data.shared_capacity_budget]
}

run "one_more_task_fails" {
  command = plan

  variables {
    api = { cpu = 256, memory = 512, min = 1, max = 3, workers = 1, threads = 8, db_pool_max = 2, requests = 600 }
  }

  # 3 tasks: over the ev_app limit AND over the share of the account-wide Fargate quota.
  expect_failures = [terraform_data.connection_budget, terraform_data.shared_capacity_budget]
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
    db_role_connection_limits = { app = 12, migrator = 2, backup = 1 }
  }

  expect_failures = [terraform_data.connection_budget]
}

run "longer_deployment_overlap_fails" {
  command = plan

  variables {
    deployment_maximum_percent = 300
  }

  expect_failures = [terraform_data.connection_budget, terraform_data.shared_capacity_budget]
}

run "shared_postgres_rule_is_port_5432_from_our_group_only" {
  command = plan

  override_resource {
    target          = module.ecs.aws_security_group.api
    override_during = plan
    values = {
      id = "sg-0e7e7e7e7e7e7e7e7"
    }
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.shared_postgres.security_group_id == "sg-070b4372d5a95ad2d"
    error_message = "La règle est posée sur le groupe de la base partagée."
  }
  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.shared_postgres.ip_protocol == "tcp" &&
      aws_vpc_security_group_ingress_rule.shared_postgres.from_port == 5432 &&
      aws_vpc_security_group_ingress_rule.shared_postgres.to_port == 5432
    )
    error_message = "Port 5432 seulement."
  }
  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.shared_postgres.cidr_ipv4 == null &&
      aws_vpc_security_group_ingress_rule.shared_postgres.cidr_ipv6 == null &&
      aws_vpc_security_group_ingress_rule.shared_postgres.prefix_list_id == null
    )
    error_message = "Jamais de bloc CIDR ni de liste de préfixes : seulement notre groupe."
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.shared_postgres.referenced_security_group_id == "sg-0e7e7e7e7e7e7e7e7"
    error_message = "Source : le groupe de NOS tâches."
  }
  assert {
    condition     = output.shared_capacity.peak_fargate_vcpu == 2.75
    error_message = "Pic de production : (2 x 2 x 256 + 3 x 256 + 1024) / 1024 = 2,75 vCPU."
  }
}

run "postgres_port_other_than_5432_fails" {
  command = plan

  variables {
    rds = {
      identifier        = "cinaf-streaming-prod-postgres"
      address           = "cinaf.example.rds.amazonaws.com"
      port              = 5433
      engine_version    = "16.3"
      master_username   = "app_admin"
      security_group_id = "sg-070b4372d5a95ad2d"
    }
  }

  expect_failures = [aws_vpc_security_group_ingress_rule.shared_postgres]
}

run "bigger_tasks_exceed_the_shared_fargate_budget" {
  command = plan

  variables {
    api = { cpu = 1024, memory = 2048, min = 1, max = 2, workers = 1, threads = 8, db_pool_max = 2, requests = 600 }
  }

  expect_failures = [terraform_data.shared_capacity_budget]
}

run "database_or_role_of_another_platform_is_refused" {
  command = plan

  variables {
    db_name  = "cinaf"
    db_roles = { app = "cinaf_app", migrator = "ev_migrator", backup = "ev_backup" }
  }

  expect_failures = [var.db_name, var.db_roles]
}
