# Envoi direct des fichiers sources du tableau de bord vers NOTRE bucket de contenu (ADR § 12),
# sans AWS (fournisseurs simulés) : CORS limité à POST depuis nos origines web exactes, sources
# effacées après 7 jours, envois en plusieurs parties abandonnés après 1 jour, règle existante
# du bucket conservée.
#   terraform init -backend=false && terraform test

mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { region = "us-east-1", name = "us-east-1" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

mock_provider "tls" {}

variables {
  name          = "ev-prod"
  account_id    = "466494951409"
  secret_prefix = "eventide/prod"
  kms_key_arn   = "arn:aws:kms:us-east-1:466494951409:key/00000000-0000-0000-0000-000000000000"
}

run "without_origins_no_cors_rule" {
  command = plan

  assert {
    condition     = length(aws_s3_bucket_cors_configuration.this) == 0
    error_message = "Sans domaine (aucune origine web) : aucune règle CORS."
  }
  assert {
    condition     = output.bucket_name == "ev-prod-content-466494951409" && output.bucket_arn == "arn:aws:s3:::ev-prod-content-466494951409"
    error_message = "Notre bucket de contenu, connu dès le plan."
  }
}

run "cors_allows_post_from_our_web_origins_only" {
  command = plan

  variables {
    cors_allowed_origins = ["https://eventide.example", "https://www.eventide.example"]
  }

  assert {
    condition     = length(aws_s3_bucket_cors_configuration.this) == 1 && length(aws_s3_bucket_cors_configuration.this[0].cors_rule) == 1
    error_message = "Une seule règle CORS."
  }
  assert {
    condition = alltrue([
      for r in aws_s3_bucket_cors_configuration.this[0].cors_rule : (
        jsonencode(sort(r.allowed_methods)) == jsonencode(["POST"]) &&
        jsonencode(sort(r.allowed_origins)) == jsonencode(["https://eventide.example", "https://www.eventide.example"]) &&
        jsonencode(sort(r.allowed_headers)) == jsonencode(["content-type"]) &&
        r.max_age_seconds == 600
      )
    ])
    error_message = "CORS : POST seulement, depuis https://<domaine> et https://www.<domaine>, en-tête Content-Type seulement, 10 minutes de cache."
  }
}

run "uploads_expire_and_existing_rule_is_kept" {
  command = plan

  assert {
    condition = (
      [for r in aws_s3_bucket_lifecycle_configuration.this.rule : r.id] ==
      ["old-versions-and-incomplete-uploads", "expire-dashboard-uploads", "remove-upload-delete-markers"]
    )
    error_message = "Règle existante conservée, plus les deux règles des sources du tableau de bord."
  }
  assert {
    condition = (
      aws_s3_bucket_lifecycle_configuration.this.rule[0].noncurrent_version_expiration[0].noncurrent_days == 30 &&
      aws_s3_bucket_lifecycle_configuration.this.rule[0].abort_incomplete_multipart_upload[0].days_after_initiation == 7
    )
    error_message = "La règle existante (anciennes versions 30 jours, envois incomplets 7 jours) n'est pas modifiée."
  }
  assert {
    condition = (
      aws_s3_bucket_lifecycle_configuration.this.rule[1].filter[0].prefix == "uploads/" &&
      aws_s3_bucket_lifecycle_configuration.this.rule[1].expiration[0].days == 7 &&
      aws_s3_bucket_lifecycle_configuration.this.rule[1].noncurrent_version_expiration[0].noncurrent_days == 1 &&
      aws_s3_bucket_lifecycle_configuration.this.rule[1].abort_incomplete_multipart_upload[0].days_after_initiation == 1 &&
      aws_s3_bucket_lifecycle_configuration.this.rule[1].status == "Enabled"
    )
    error_message = "Sources uploads/ : effacées après 7 jours (et leur ancienne version 1 jour après), envois incomplets abandonnés après 1 jour."
  }
  assert {
    condition = (
      aws_s3_bucket_lifecycle_configuration.this.rule[2].filter[0].prefix == "uploads/" &&
      aws_s3_bucket_lifecycle_configuration.this.rule[2].expiration[0].expired_object_delete_marker == true
    )
    error_message = "Marqueurs de suppression de uploads/ retirés."
  }
  assert {
    condition     = output.upload_prefix == "uploads/" && output.media_prefixes == ["videos/paysages/", "images/paysages/", "audio/sons/", "audio/musiques/"]
    error_message = "Disposition du contenu (contrat § 8 et § 13)."
  }
}

run "wildcard_or_http_origin_is_refused" {
  command = plan

  variables {
    cors_allowed_origins = ["https://*.eventide.example", "http://eventide.example"]
  }

  expect_failures = [var.cors_allowed_origins]
}
