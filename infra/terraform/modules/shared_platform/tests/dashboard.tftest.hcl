# Tableau de bord (contrat § 14, ADR § 12), sans AWS (fournisseurs simulés) : variables
# d'intégration de l'API et de la tâche media (noms du contrat avec le backend), secrets injectés
# dans chaque famille (ADMIN_EMAILS dans api seulement ; media sans clé Google ni CloudFront),
# droits des rôles de tâche sur NOS seules ressources, origines CORS = nos seuls hôtes web,
# client OAuth web obligatoirement accepté comme audience.
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
  fargate_vcpu_budget       = 3
  github_repository         = "fabriceTAKOUMBO/eventide"
  github_subject_repository = "fabriceTAKOUMBO@75751595/eventide@1234567890"
}

run "integration_environment_names_our_resources_only" {
  command = plan

  override_resource {
    target          = module.ecs.aws_security_group.api
    override_during = plan
    values = {
      id = "sg-0e7e7e7e7e7e7e7e7"
    }
  }

  assert {
    condition = jsonencode(output.dashboard.environment) == jsonencode({
      CONTENT_BUCKET             = "ev-prod-content-466494951409"
      CONTENT_BUCKET_REGION      = "us-east-1"
      MEDIA_STORAGE              = "s3"
      MEDIA_TASK_CLUSTER         = "ev-prod"
      MEDIA_TASK_CONTAINER       = "media"
      MEDIA_TASK_DEFINITION      = "ev-prod-media"
      MEDIA_TASK_SECURITY_GROUPS = "sg-0e7e7e7e7e7e7e7e7"
      MEDIA_TASK_SUBNETS         = "subnet-03bb1c6197c29a369,subnet-0fcd9f10a65ed1a16"
    })
    error_message = "Variables d'intégration : notre bucket, notre cluster, la famille ev-prod-media, les sous-réseaux et le groupe des tâches jobs (GOOGLE_WEB_CLIENT_ID absent quand il n'est pas configuré)."
  }
  assert {
    condition     = output.dashboard.media_task.family == output.dashboard.environment.MEDIA_TASK_DEFINITION && output.dashboard.media_task.container == "media"
    error_message = "MEDIA_TASK_DEFINITION et MEDIA_TASK_CONTAINER désignent la famille et le conteneur créés."
  }
  assert {
    condition     = output.dashboard.media_task.cpu == 1024 && output.dashboard.media_task.memory == 2048
    error_message = "Tâche media : 1 vCPU / 2 Go par défaut."
  }
  assert {
    condition     = contains(output.dashboard.secrets_by_family.api, "ADMIN_EMAILS")
    error_message = "ADMIN_EMAILS injecté dans l'API."
  }
  assert {
    condition = alltrue([
      for f in ["migrate", "jobs", "media"] : !contains(output.dashboard.secrets_by_family[f], "ADMIN_EMAILS")
    ])
    error_message = "ADMIN_EMAILS dans l'API seulement."
  }
  assert {
    condition     = jsonencode(output.dashboard.secrets_by_family.media) == jsonencode(["DATABASE_URL", "DJANGO_SECRET_KEY"])
    error_message = "Tâche media : la base (rôle applicatif) et la clé Django seulement."
  }
  assert {
    condition     = jsonencode(output.secret_names) == jsonencode(["eventide/prod/admin-emails", "eventide/prod/google-play-service-account"])
    error_message = "Secret ADMIN_EMAILS à remplir par le product owner, sous eventide/prod/."
  }
  assert {
    condition = (
      jsonencode(output.dashboard.task_policies.api.Statement[0].Resource) == jsonencode(["arn:aws:s3:::ev-prod-content-466494951409/uploads/*"]) &&
      jsonencode(output.dashboard.task_policies.media.Statement[0].Resource) == jsonencode(["arn:aws:s3:::ev-prod-content-466494951409/uploads/*"]) &&
      jsonencode(output.dashboard.task_policies.media.Statement[1].Resource) == jsonencode([
        "arn:aws:s3:::ev-prod-content-466494951409/videos/paysages/*",
        "arn:aws:s3:::ev-prod-content-466494951409/images/paysages/*",
        "arn:aws:s3:::ev-prod-content-466494951409/audio/sons/*",
        "arn:aws:s3:::ev-prod-content-466494951409/audio/musiques/*",
      ])
    )
    error_message = "Rôles de tâche : NOTRE bucket de contenu, préfixes uploads/ et fichiers traités seulement."
  }
  assert {
    condition     = length(output.content.uploads.cors_allowed_origins) == 0
    error_message = "Sans domaine : aucune règle CORS (pas de tableau de bord)."
  }
}

run "with_domain_cors_allows_our_web_origins_only" {
  command = plan

  variables {
    domain          = "eventide.example"
    zone_id         = "Z0EVENTIDETEST"
    hostname_suffix = "eventide.example"
    web_hostnames   = ["eventide.example", "www.eventide.example"]
  }

  assert {
    condition     = jsonencode(output.content.uploads.cors_allowed_origins) == jsonencode(["https://eventide.example", "https://www.eventide.example"])
    error_message = "CORS : https://<domaine> et https://www.<domaine>, rien d'autre."
  }
  assert {
    condition     = output.content.uploads.prefix == "uploads/" && output.content.uploads.expiration_days == 7
    error_message = "Sources sous uploads/, effacées après 7 jours."
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

run "web_client_reaches_the_api" {
  command = plan

  variables {
    google_web_client_id    = "123456789012-abcdefghijklmnop.apps.googleusercontent.com"
    google_oauth_client_ids = ["123456789012-abcdefghijklmnop.apps.googleusercontent.com"]
  }

  assert {
    condition     = output.dashboard.environment.GOOGLE_WEB_CLIENT_ID == "123456789012-abcdefghijklmnop.apps.googleusercontent.com"
    error_message = "GOOGLE_WEB_CLIENT_ID transmis à l'API."
  }
}

run "malformed_web_client_is_refused" {
  command = plan

  variables {
    google_web_client_id    = "not-a-client"
    google_oauth_client_ids = ["not-a-client"]
  }

  expect_failures = [var.google_web_client_id]
}
