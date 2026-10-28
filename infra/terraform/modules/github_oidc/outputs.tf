output "deploy_role_arn" {
  description = "Variable GitHub AWS_DEPLOY_ROLE_ARN de l'environnement."
  value       = aws_iam_role.deploy.arn
}
