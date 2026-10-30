# Contenu d'Eventide (sons, musiques, photos de paysages), contrat § 8 : bucket S3 PRIVÉ servi par
# une distribution CloudFront propre, accès au bucket par OAC, et lecture réservée aux adresses
# SIGNÉES (groupe de clés de confiance) que l'API délivre après vérification des droits.
# Modèle : modules/map_tiles de Candidature Express (bucket privé + OAC), plus les adresses signées.
#
# Disposition des objets : audio/sons/<id>.ogg, audio/musiques/<id>.ogg, images/paysages/<id>.jpg,
# videos/paysages/<id>.mp4 (déposés par le product owner avec sa session d'administration, ou
# écrits par la tâche ev-<env>-media du tableau de bord, contrat § 13 et § 14).
#
# Tableau de bord (30 octobre 2026, ADR § 12) : le navigateur de l'administrateur envoie le
# fichier source DIRECTEMENT dans ce bucket (formulaire POST signé par l'API, clé
# uploads/<uuid>/source) : CORS limité à POST depuis nos seules origines web, sources effacées
# après 7 jours. Le fichier ne traverse ni l'API ni l'ALB partagé.
#
# Clé de signature : paire RSA 2048 générée par Terraform (tls_private_key) ; la clé publique entre
# dans le groupe de clés de la distribution, la clé privée dans Secrets Manager
# (<secret_prefix>/cloudfront-private-key, chiffrée par notre clé KMS), lue par la tâche api.
# La clé privée figure aussi dans l'état Terraform, protégé par la pile bootstrap.
#
# Uniquement des ressources NOUVELLES et propres à Eventide : aucun contact avec CINAF, JobMinutes
# ni Candidature Express (le compte est partagé : quota de distributions et franchise gratuite de
# CloudFront). Fournisseur par défaut = us-east-1.

data "aws_region" "current" {}

locals {
  bucket_name   = "${var.name}-content-${var.account_id}"
  bucket_arn    = "arn:aws:s3:::${local.bucket_name}"
  origin_id     = "s3-${local.bucket_name}"
  custom_domain = var.domain_name != ""
  tags          = { Component = "content" }

  # Dashboard (contract § 14): sources uploaded by the browser, and the prefixes the media
  # task writes its outputs to (contract § 8 and § 13 layout).
  upload_prefix  = "uploads/"
  media_prefixes = ["videos/paysages/", "images/paysages/", "audio/sons/", "audio/musiques/"]
}

# --- Bucket privé ----------------------------------------------------------------------------------

resource "aws_s3_bucket" "this" {
  bucket        = local.bucket_name
  force_destroy = var.force_destroy
  tags          = local.tags
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# SSE-S3 : contenu sans donnée personnelle ; une clé KMS imposerait d'ouvrir sa politique à
# CloudFront (coût et complexité sans gain).
resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    id     = "old-versions-and-incomplete-uploads"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_days
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  # Dashboard sources (uploads/<uuid>/source, up to 300 MB): current version expired after
  # upload_expiration_days, the bytes (noncurrent version, the bucket is versioned) one day
  # later; incomplete multipart uploads aborted after one day. Where rules overlap, S3 applies
  # the shorter delay.
  rule {
    id     = "expire-dashboard-uploads"
    status = "Enabled"
    filter {
      prefix = local.upload_prefix
    }
    expiration {
      days = var.upload_expiration_days
    }
    noncurrent_version_expiration {
      noncurrent_days = 1
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  # Delete markers left by the rule above, once their noncurrent version is gone.
  rule {
    id     = "remove-upload-delete-markers"
    status = "Enabled"
    filter {
      prefix = local.upload_prefix
    }
    expiration {
      expired_object_delete_marker = true
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}

# Browser uploads from the dashboard (presigned POST): POST only, from OUR web origins only
# (https://<domain>, https://www.<domain> in production; https://preprod.<domain> in
# preproduction). No GET: content is read through CloudFront with signed URLs. No rule without a
# domain (no dashboard then).
resource "aws_s3_bucket_cors_configuration" "this" {
  count  = length(var.cors_allowed_origins) > 0 ? 1 : 0
  bucket = aws_s3_bucket.this.id

  cors_rule {
    id              = "dashboard-uploads"
    allowed_methods = ["POST"]
    allowed_origins = var.cors_allowed_origins
    # A presigned POST carries its fields in the multipart body: only Content-Type (preflight
    # sent when the page watches the upload progress).
    allowed_headers = ["content-type"]
    expose_headers  = ["ETag"]
    max_age_seconds = var.cors_max_age_seconds
  }
}

data "aws_iam_policy_document" "bucket" {
  statement {
    sid       = "AllowCloudFrontRead"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.this.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.this.arn]
    }
  }

  # Sans s3:ListBucket, S3 répond 403 à un fichier absent ; avec, 404 (alarmes plus lisibles).
  statement {
    sid       = "AllowCloudFrontListForNotFound"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.this.arn]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.this.arn]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = data.aws_iam_policy_document.bucket.json

  depends_on = [aws_s3_bucket_public_access_block.this]
}

# --- Clé de signature des adresses ---------------------------------------------------------------

resource "tls_private_key" "signing" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "aws_cloudfront_public_key" "signing" {
  name        = "${var.name}-content-signing"
  comment     = "Eventide : signature des adresses du contenu (cle privee dans Secrets Manager)"
  encoded_key = tls_private_key.signing.public_key_pem
}

resource "aws_cloudfront_key_group" "signing" {
  name    = "${var.name}-content"
  comment = "Cles de confiance des adresses signees d'Eventide"
  items   = [aws_cloudfront_public_key.signing.id]
}

resource "aws_secretsmanager_secret" "signing_key" {
  name                    = "${var.secret_prefix}/cloudfront-private-key"
  description             = "CLOUDFRONT_PRIVATE_KEY : cle privee RSA (PEM) de signature des adresses CloudFront d'Eventide"
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = var.secret_recovery_window_days
}

resource "aws_secretsmanager_secret_version" "signing_key" {
  secret_id     = aws_secretsmanager_secret.signing_key.id
  secret_string = tls_private_key.signing.private_key_pem
}

# --- Certificat propre (facultatif, nom cdn.<domaine>) -------------------------------------------

resource "aws_acm_certificate" "this" {
  count             = local.custom_domain ? 1 : 0
  domain_name       = var.domain_name
  validation_method = "DNS"
  tags              = local.tags

  lifecycle {
    create_before_destroy = true

    precondition {
      condition     = data.aws_region.current.region == "us-east-1"
      error_message = "content_cdn doit utiliser le fournisseur us-east-1 : le certificat d'une distribution CloudFront y est obligatoire."
    }
  }
}

resource "aws_route53_record" "validation" {
  # Clé connue au plan (le nom demandé) ; valeurs données par le certificat.
  for_each = local.custom_domain ? toset([var.domain_name]) : toset([])

  zone_id         = var.zone_id
  name            = one(aws_acm_certificate.this[0].domain_validation_options).resource_record_name
  type            = one(aws_acm_certificate.this[0].domain_validation_options).resource_record_type
  records         = [one(aws_acm_certificate.this[0].domain_validation_options).resource_record_value]
  ttl             = 300
  allow_overwrite = false
}

resource "aws_acm_certificate_validation" "this" {
  count                   = local.custom_domain ? 1 : 0
  certificate_arn         = aws_acm_certificate.this[0].arn
  validation_record_fqdns = [for r in aws_route53_record.validation : r.fqdn]
}

# --- CloudFront ----------------------------------------------------------------------------------

resource "aws_cloudfront_origin_access_control" "this" {
  name                              = "${var.name}-content"
  description                       = "Acces CloudFront au bucket prive ${local.bucket_name}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Clé de cache minimale : les paramètres de signature (Expires, Signature, Key-Pair-Id) sont
# vérifiés par CloudFront mais n'entrent pas dans la clé, si bien qu'un objet reste en cache
# quelle que soit l'adresse signée qui l'a demandé. Remplacer un fichier = nouveau nom ou
# invalidation.
resource "aws_cloudfront_cache_policy" "content" {
  name        = "${var.name}-content"
  comment     = "Contenu Eventide : 1 jour minimum, 30 jours par defaut, 1 an maximum"
  min_ttl     = 86400
  default_ttl = 2592000
  max_ttl     = 31536000

  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_brotli = false
    enable_accept_encoding_gzip   = false

    cookies_config {
      cookie_behavior = "none"
    }
    headers_config {
      header_behavior = "none"
    }
    query_strings_config {
      query_string_behavior = "none"
    }
  }
}

resource "aws_cloudfront_distribution" "this" {
  enabled         = var.distribution_enabled
  is_ipv6_enabled = true
  http_version    = "http2and3"
  price_class     = var.price_class
  aliases         = local.custom_domain ? [var.domain_name] : []
  comment         = "${var.name} content (audio, images), signed URLs only"
  tags            = local.tags

  # Pas de journaux d'accès (adresses IP), pas de WAF au départ (lecture signée seulement).

  origin {
    domain_name              = aws_s3_bucket.this.bucket_regional_domain_name
    origin_id                = local.origin_id
    origin_access_control_id = aws_cloudfront_origin_access_control.this.id
  }

  default_cache_behavior {
    target_origin_id       = local.origin_id
    viewer_protocol_policy = "https-only"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = false # Opus et JPEG sont déjà compressés
    cache_policy_id        = aws_cloudfront_cache_policy.content.id
    trusted_key_groups     = [aws_cloudfront_key_group.signing.id]
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = !local.custom_domain
    acm_certificate_arn            = local.custom_domain ? aws_acm_certificate_validation.this[0].certificate_arn : null
    ssl_support_method             = local.custom_domain ? "sni-only" : null
    minimum_protocol_version       = local.custom_domain ? "TLSv1.2_2021" : "TLSv1"
  }
}

resource "aws_route53_record" "alias" {
  for_each = local.custom_domain ? toset(["A", "AAAA"]) : toset([])

  zone_id = var.zone_id
  name    = var.domain_name
  type    = each.value

  alias {
    name                   = aws_cloudfront_distribution.this.domain_name
    zone_id                = aws_cloudfront_distribution.this.hosted_zone_id
    evaluate_target_health = false
  }
}

# --- Alarmes (mesures standard et gratuites de CloudFront, lues dans us-east-1) ------------------

locals {
  alarm_actions = var.alarm_topic_arn == "" ? [] : [var.alarm_topic_arn]

  alarms = {
    requests-day = {
      metric      = "Requests"
      statistic   = "Sum"
      period      = 86400
      periods     = 1
      threshold   = var.requests_alarm_per_day
      description = "Plus de ${var.requests_alarm_per_day} requetes de contenu par jour : emballement de l application ou abus."
    }
    bytes-day = {
      metric      = "BytesDownloaded"
      statistic   = "Sum"
      period      = 86400
      periods     = 1
      threshold   = var.bytes_alarm_gb_per_day * 1073741824
      description = "Plus de ${var.bytes_alarm_gb_per_day} Go de contenu diffuses par jour (le cout suit ce volume, au-dela de la franchise du compte)."
    }
    "5xx" = {
      metric      = "5xxErrorRate"
      statistic   = "Average"
      period      = 300
      periods     = 3
      threshold   = var.error_rate_alarm_percent
      description = "Taux d erreurs 5xx superieur a ${var.error_rate_alarm_percent} % pendant 15 minutes : origine S3 ou OAC casses."
    }
    "4xx" = {
      metric      = "4xxErrorRate"
      statistic   = "Average"
      period      = 300
      periods     = 3
      threshold   = var.error_rate_alarm_percent * 10
      description = "Taux d erreurs 4xx superieur a ${var.error_rate_alarm_percent * 10} % pendant 15 minutes : signatures refusees (cle, Key-Pair-Id), fichiers absents."
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "this" {
  for_each = local.alarms

  alarm_name          = "${var.name}-content-${each.key}"
  alarm_description   = "${each.value.description} Distribution ${aws_cloudfront_distribution.this.id}."
  namespace           = "AWS/CloudFront"
  metric_name         = each.value.metric
  dimensions          = { DistributionId = aws_cloudfront_distribution.this.id, Region = "Global" }
  statistic           = each.value.statistic
  period              = each.value.period
  evaluation_periods  = each.value.periods
  threshold           = each.value.threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
  tags                = local.tags
}

# --- Budget du contenu (alerte seulement : AWS ne coupe rien) -------------------------------------

resource "aws_budgets_budget" "this" {
  count        = var.budget_enabled && length(var.budget_emails) > 0 ? 1 : 0
  name         = "${var.name}-content-mensuel"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:Project$eventide"]
  }
  cost_filter {
    name   = "Service"
    values = ["Amazon CloudFront", "Amazon Simple Storage Service"]
  }

  dynamic "notification" {
    for_each = [
      { type = "ACTUAL", threshold = 80 },
      { type = "FORECASTED", threshold = 100 },
    ]
    content {
      comparison_operator        = "GREATER_THAN"
      notification_type          = notification.value.type
      threshold                  = notification.value.threshold
      threshold_type             = "PERCENTAGE"
      subscriber_email_addresses = var.budget_emails
    }
  }
}
