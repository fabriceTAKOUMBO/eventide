output "content_base_url" {
  description = "Origine du contenu (CONTENT_BASE_URL de l'API)."
  value       = local.custom_domain ? "https://${var.domain_name}" : "https://${aws_cloudfront_distribution.this.domain_name}"
}

output "key_pair_id" {
  description = "Identifiant de la clé publique CloudFront (CLOUDFRONT_KEY_PAIR_ID de l'API)."
  value       = aws_cloudfront_public_key.signing.id
}

output "private_key_secret_arn" {
  description = "Secret de la clé privée de signature (CLOUDFRONT_PRIVATE_KEY de l'API)."
  value       = aws_secretsmanager_secret.signing_key.arn
}

output "bucket_name" {
  description = "Bucket privé du contenu (dépôt des fichiers par le product owner)."
  value       = aws_s3_bucket.this.id
}

output "distribution_id" {
  description = "Identifiant de la distribution CloudFront."
  value       = aws_cloudfront_distribution.this.id
}

output "alarm_names" {
  description = "Alarmes CloudWatch du module."
  value       = [for a in aws_cloudwatch_metric_alarm.this : a.alarm_name]
}
