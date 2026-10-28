# Plan de envs/shared-prod SANS AWS : fournisseurs simulés (mock_provider), sources de données
# de l'infrastructure partagée remplacées par les valeurs relevées (inventaire du 9 octobre 2026
# par Candidature Express). Aucun appel réseau, aucun identifiant AWS.
#   terraform init -backend=false && terraform test
# Vérifie : le plan passe sans domaine et avec domaine ; les gardes de l'infrastructure partagée
# (X-Forwarded-For, version PostgreSQL) font échouer le plan quand elles sont fausses.

# Toutes les configurations du fournisseur AWS sont simulées (défaut ET alias preprod) : sans
# cela, la configuration non simulée tenterait un vrai appel STS.
mock_provider "aws" {
  source = "./tests/mocks"
}

mock_provider "aws" {
  alias  = "preprod"
  source = "./tests/mocks"
}

mock_provider "random" {}
mock_provider "tls" {}

variables {
  aws_account_id            = "466494951409"
  vpc_id                    = "vpc-0fbfe87b34e2b3903"
  app_subnet_ids            = ["subnet-03bb1c6197c29a369", "subnet-0fcd9f10a65ed1a16"]
  rds_security_group_id     = "sg-070b4372d5a95ad2d"
  github_subject_repository = "fabriceTAKOUMBO@75751595/eventide@1234567890"
  alert_emails              = ["alertes@example.com"]
  budget_emails             = ["alertes@example.com"]
}

run "without_domain_no_public_entry" {
  command = plan

  assert {
    condition     = output.prod.api_url == "" && output.prod.web_url == ""
    error_message = "Sans domaine, aucune URL publique."
  }
  assert {
    condition     = output.prod.shared_alb == null
    error_message = "Sans domaine, l'ALB partagé ne doit pas être utilisé."
  }
  assert {
    condition     = output.prod.db_connection_limits.total == 14 && output.prod.db_connection_limits.app == 10
    error_message = "Budget de connexions attendu : 10 + 2 + 2 = 14."
  }
  assert {
    condition     = output.prod.db_connection_limits.app_max <= 10
    error_message = "L'autoscaling ne doit pas dépasser la limite de ev_app."
  }
  assert {
    condition     = output.preprod == null
    error_message = "La préproduction est désactivée par défaut."
  }
  assert {
    condition     = contains(output.prod.secrets_to_fill, "eventide/prod/gemini-api-key")
    error_message = "Secrets sous eventide/prod/*."
  }
}

run "with_domain_public_entry" {
  command = plan

  variables {
    domain_name = "eventide.example"
  }

  assert {
    condition     = output.prod.api_url == "https://api.eventide.example"
    error_message = "Hôte de l'API : api.<domaine>."
  }
  assert {
    condition     = output.prod.web_url == "https://eventide.example"
    error_message = "Origine des liens de partage : le domaine nu."
  }
  assert {
    condition     = output.prod.shared_alb != null
    error_message = "Avec un domaine, l'entrée passe par l'ALB partagé."
  }
}

run "with_preprod" {
  command = plan

  variables {
    domain_name     = "eventide.example"
    preprod_enabled = true
  }

  assert {
    condition     = output.preprod.api_url == "https://api.preprod.eventide.example"
    error_message = "Hôte de préproduction : api.preprod.<domaine>."
  }
  assert {
    condition     = output.preprod.db_connection_limits.total <= output.preprod.db_connection_limits.budget
    error_message = "Budget de connexions de la préproduction."
  }
}

run "shared_alb_xff_changed_fails" {
  command = plan

  override_data {
    target = data.aws_lb.shared
    values = {
      arn                        = "arn:aws:elasticloadbalancing:us-east-1:466494951409:loadbalancer/app/cinaf-streaming-prod-alb/0123456789abcdef"
      vpc_id                     = "vpc-0fbfe87b34e2b3903"
      internal                   = false
      xff_header_processing_mode = "preserve"
      enable_xff_client_port     = false
      security_groups            = ["sg-04bbc536ff0295918"]
      idle_timeout               = 60
    }
  }

  expect_failures = [terraform_data.shared_infrastructure_checks]
}

run "postgres_17_fails" {
  command = plan

  override_data {
    target = data.aws_db_instance.shared
    values = {
      db_instance_identifier = "cinaf-streaming-prod-postgres"
      address                = "cinaf.example.rds.amazonaws.com"
      port                   = 5432
      engine_version         = "17.2"
      master_username        = "app_admin"
      vpc_security_groups    = ["sg-070b4372d5a95ad2d"]
    }
  }

  expect_failures = [terraform_data.shared_infrastructure_checks]
}
