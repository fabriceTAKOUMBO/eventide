output "deploy_role_arn" {
  description = "Variable GitHub AWS_DEPLOY_ROLE_ARN de l'environnement."
  value       = aws_iam_role.deploy.arn
}

output "deploy_policy" {
  description = "Politique du rôle de déploiement (contrôle des tests, aucun secret)."
  value       = local.deploy_policy
}
