output "key_arn" {
  description = "ARN de la clé KMS de l'environnement."
  value       = aws_kms_key.this.arn
}

output "alias_name" {
  description = "Alias de la clé."
  value       = aws_kms_alias.this.name
}
