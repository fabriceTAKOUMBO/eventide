output "repository_urls" {
  description = "URL des dépôts, par suffixe."
  value       = { for k, r in aws_ecr_repository.this : k => r.repository_url }
}

output "repository_arns" {
  description = "ARN des dépôts, par suffixe."
  value       = { for k, r in aws_ecr_repository.this : k => r.arn }
}
