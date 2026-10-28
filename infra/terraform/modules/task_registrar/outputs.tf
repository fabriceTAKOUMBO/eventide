output "function_name" {
  description = "Nom de la fonction (configuration du workflow Deploy)."
  value       = aws_lambda_function.this.function_name
}

output "function_arn" {
  description = "ARN de la fonction (seul droit ECS du rôle de déploiement GitHub sur les définitions de tâche : lambda:InvokeFunction)."
  value       = aws_lambda_function.this.arn
}

output "policy_actions" {
  description = "Actions IAM accordées au rôle de la fonction (contrôle des tests)."
  value       = sort(distinct(flatten([for s in local.policy.Statement : s.Action])))
}
