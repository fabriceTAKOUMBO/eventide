# Plan de envs/shared-prod SANS AWS : fournisseurs simulés (mock_provider), sources de données
# de l'infrastructure partagée remplacées par les valeurs relevées (inventaire du 9 octobre 2026
# par Candidature Express). Aucun appel réseau, aucun identifiant AWS.
#   terraform init -backend=false && terraform test
# Vérifie : le plan passe sans domaine et avec domaine ; les gardes de l'infrastructure partagée
# (X-Forwarded-For, version PostgreSQL) font échouer le plan quand elles sont fausses.
# Also: our listener rules (priorities and host names), the refusal of another platform's
# domain or of a zone not marked Project = eventide, the RDS load alarms (prod only), and the
# dashboard (ADR § 12): media task counted in both budgets, CORS origins = our web hosts only,
# ADMIN_EMAILS secret to fill, web OAuth client accepted as an audience.

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
mock_provider "archive" {}

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
    condition     = output.prod.db_connection_limits.total == 14 && output.prod.db_connection_limits.app == 11 && output.prod.db_connection_limits.backup == 1
    error_message = "Budget de connexions attendu : 11 + 2 + 1 = 14 (total inchangé avec la tâche media)."
  }
  assert {
    condition     = output.prod.db_connection_limits.app_max == 11 && output.prod.db_connection_limits.media == 1
    error_message = "L'autoscaling, les tâches planifiées et la tâche media ne doivent pas dépasser la limite de ev_app (8 + 2 + 1 = 11)."
  }
  assert {
    condition     = output.preprod == null
    error_message = "La préproduction est désactivée par défaut."
  }
  assert {
    condition     = jsonencode(output.prod.secrets_to_fill) == jsonencode(["eventide/prod/admin-emails", "eventide/prod/google-play-service-account"])
    error_message = "Secrets à remplir sous eventide/prod/* (dont ADMIN_EMAILS du tableau de bord)."
  }
  assert {
    condition     = length(output.prod.contact_points.listener_rules) == 0 && !output.prod.contact_points.listener_certificate
    error_message = "Sans domaine : ni règle d'écouteur, ni certificat (seul point de contact réseau : la règle 5432)."
  }
  assert {
    condition     = output.prod.contact_points.postgres_ingress.port == 5432 && output.prod.contact_points.postgres_ingress.cidr_ipv4 == null && output.prod.contact_points.postgres_ingress.security_group_id == "sg-070b4372d5a95ad2d"
    error_message = "Règle d'entrée 5432 sur le groupe de la base, sans bloc CIDR."
  }
  assert {
    condition     = length(output.prod.contact_points.rds_metric_alarms) == 5
    error_message = "Alarmes de charge de l'instance partagée (métriques seulement) : CPU, connexions, mémoire, disque, crédits."
  }
  assert {
    condition     = output.prod.shared_capacity.peak_fargate_vcpu == 2.75 && output.prod.shared_capacity.fargate_vcpu_budget == 3
    error_message = "Part du quota Fargate commun au compte : 1,75 + 1 (tâche media) = 2,75 vCPU, budget 3."
  }
  assert {
    # CONTENT_BUCKET and CONTENT_BUCKET_REGION come from data sources deferred to apply here
    # (module depends_on): checked by modules/shared_platform/tests/dashboard.tftest.hcl.
    condition = (
      output.prod.dashboard.environment.MEDIA_STORAGE == "s3" &&
      output.prod.dashboard.environment.MEDIA_TASK_CLUSTER == "ev-prod" &&
      output.prod.dashboard.environment.MEDIA_TASK_DEFINITION == "ev-prod-media" &&
      output.prod.dashboard.environment.MEDIA_TASK_CONTAINER == "media" &&
      output.prod.dashboard.environment.MEDIA_TASK_SUBNETS == "subnet-03bb1c6197c29a369,subnet-0fcd9f10a65ed1a16"
    )
    error_message = "Intégration du tableau de bord : notre bucket, notre cluster, la famille ev-prod-media, nos sous-réseaux."
  }
  assert {
    condition     = output.prod.ecs_task_families.media == "ev-prod-media"
    error_message = "Famille media créée (enregistrée ensuite par le déploiement)."
  }
  assert {
    condition     = length(output.prod.content.uploads.cors_allowed_origins) == 0
    error_message = "Sans domaine : aucune règle CORS sur le bucket de contenu."
  }
  assert {
    condition     = output.prod.task_registrar_function == "ev-prod-task-registrar"
    error_message = "Registraire des définitions de tâche d'Eventide."
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
  assert {
    condition     = output.prod.contact_points.listener_rules.api.priority == 400 && output.prod.contact_points.listener_rules.web.priority == 401
    error_message = "Règles de production : 400 (api) et 401 (domaine nu et www)."
  }
  assert {
    condition = (
      join(",", output.prod.contact_points.listener_rules.api.hosts) == "api.eventide.example" &&
      join(",", output.prod.contact_points.listener_rules.web.hosts) == "eventide.example,www.eventide.example"
    )
    error_message = "Nos règles ne correspondent qu'à nos noms d'hôte."
  }
  assert {
    condition     = output.prod.contact_points.listener_certificate
    error_message = "Notre certificat ajouté à l'écouteur (SNI)."
  }
  assert {
    condition     = jsonencode(output.prod.content.uploads.cors_allowed_origins) == jsonencode(["https://eventide.example", "https://www.eventide.example"])
    error_message = "Envoi direct vers le bucket : POST depuis https://<domaine> et https://www.<domaine> seulement."
  }
  assert {
    condition     = length(output.prod.contact_points.listener_rules) == 2
    error_message = "Tableau de bord sur les hôtes web existants : aucune règle d'écouteur de plus (400 et 401 seulement)."
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
  assert {
    condition = (
      output.preprod.contact_points.listener_rules.api.priority == 420 &&
      output.preprod.contact_points.listener_rules.web.priority == 421 &&
      join(",", output.preprod.contact_points.listener_rules.api.hosts) == "api.preprod.eventide.example" &&
      join(",", output.preprod.contact_points.listener_rules.web.hosts) == "preprod.eventide.example"
    )
    error_message = "Règles de préproduction : 420 et 421, sur les seuls noms preprod."
  }
  assert {
    condition     = length(output.preprod.contact_points.rds_metric_alarms) == 0
    error_message = "Une seule série d'alarmes sur l'instance partagée (production)."
  }
  assert {
    condition     = jsonencode(output.preprod.content.uploads.cors_allowed_origins) == jsonencode(["https://preprod.eventide.example"])
    error_message = "CORS de préproduction : son seul hôte web."
  }
  assert {
    condition     = output.preprod.shared_capacity.peak_fargate_vcpu == 2.25 && output.preprod.shared_capacity.fargate_vcpu_budget == 2.5
    error_message = "Préproduction : 1,25 + 1 (tâche media) = 2,25 vCPU, budget 2,5."
  }
  assert {
    condition     = output.preprod.dashboard.environment.MEDIA_TASK_DEFINITION == "ev-preprod-media" && output.preprod.dashboard.environment.MEDIA_TASK_CLUSTER == "ev-preprod"
    error_message = "La préproduction lance SA famille media dans SON cluster."
  }
  assert {
    condition     = output.preprod.db_connection_limits.app_max <= output.preprod.db_connection_limits.app
    error_message = "Préproduction : 2 + 1 + 1 (tâche media) dans la limite de ev_preprod_app."
  }
}

run "web_client_must_be_an_accepted_audience" {
  command = plan

  variables {
    google_web_client_id    = "123456789012-abcdefghijklmnop.apps.googleusercontent.com"
    google_oauth_client_ids = ["999999999999-androidclient.apps.googleusercontent.com"]
  }

  expect_failures = [var.google_web_client_id]
}

run "domain_of_another_platform_is_refused" {
  command = plan

  variables {
    domain_name = "app.candidatureexpress.com"
  }

  expect_failures = [var.domain_name]
}

run "zone_not_marked_ours_fails" {
  command = plan

  variables {
    domain_name = "eventide.example"
  }

  override_data {
    target = data.aws_route53_zone.this
    values = {
      zone_id = "Z0SOMEONEELSE"
      name    = "eventide.example."
      tags    = { Project = "cinaf" }
    }
  }

  expect_failures = [terraform_data.shared_infrastructure_checks]
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
