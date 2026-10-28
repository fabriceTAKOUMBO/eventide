output "django_secret_key_arn" {
  description = "ARN du secret DJANGO_SECRET_KEY."
  value       = aws_secretsmanager_secret.django_secret_key.arn
}

output "db_secret_arns" {
  description = "ARN des secrets des rôles PostgreSQL (app, migrator, backup)."
  value       = { for k, s in aws_secretsmanager_secret.db : k => s.arn }
}

output "manual_secret_arns" {
  description = "ARN des secrets à remplir à la main."
  value       = { for k, s in aws_secretsmanager_secret.manual : k => s.arn }
}
