output "cluster_name" {
  description = "Nom du cluster."
  value       = aws_ecs_cluster.this.name
}

output "cluster_arn" {
  description = "ARN du cluster."
  value       = aws_ecs_cluster.this.arn
}

output "service_names" {
  description = "Services ECS ({} sans domaine)."
  value       = var.api_service_enabled ? { api = aws_ecs_service.api[0].name } : {}
}

output "service_arns" {
  description = "ARN des services."
  value       = var.api_service_enabled ? [aws_ecs_service.api[0].id] : []
}

output "task_families" {
  description = "Familles de définitions de tâche."
  value = {
    api     = aws_ecs_task_definition.api.family
    migrate = aws_ecs_task_definition.migrate.family
    jobs    = aws_ecs_task_definition.jobs.family
  }
}

output "task_definition_arns" {
  description = "Révisions enregistrées par Terraform (modèles du workflow Deploy)."
  value = {
    api     = aws_ecs_task_definition.api.arn
    migrate = aws_ecs_task_definition.migrate.arn
    jobs    = aws_ecs_task_definition.jobs.arn
  }
}

output "container_names" {
  description = "Nom du conteneur principal de chaque famille."
  value       = { api = "api", migrate = "migrate", jobs = "jobs" }
}

output "api_security_group_id" {
  description = "Groupe de sécurité des tâches api, migrate, jobs et outils PostgreSQL."
  value       = aws_security_group.api.id
}

output "execution_role_arns" {
  description = "Rôles d'exécution par usage."
  value       = { for k, r in aws_iam_role.execution : k => r.arn }
}

output "log_group_names" {
  description = "Groupes de journaux (api, jobs)."
  value       = { for k, g in aws_cloudwatch_log_group.this : k => g.name }
}

output "log_group_arns" {
  description = "ARN des groupes de journaux."
  value       = { for k, g in aws_cloudwatch_log_group.this : k => g.arn }
}

output "autoscaling_resource_id" {
  description = "Cible de mise à l'échelle du service api (null sans domaine)."
  value       = var.api_service_enabled ? local.scaling_target.resource_id : null
}
