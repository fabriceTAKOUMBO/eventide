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
    media   = aws_ecs_task_definition.media.family
  }
}

output "register_inputs" {
  description = "Entrées exactes de RegisterTaskDefinition par famille (api, migrate, jobs, media), identiques aux révisions Terraform ; le registraire de tâches n'y remplace que l'image."
  value       = local.register_inputs
}

output "task_definition_arns" {
  description = "Révisions enregistrées par Terraform."
  value = {
    api     = aws_ecs_task_definition.api.arn
    migrate = aws_ecs_task_definition.migrate.arn
    jobs    = aws_ecs_task_definition.jobs.arn
    media   = aws_ecs_task_definition.media.arn
  }
}

output "container_names" {
  description = "Nom du conteneur principal de chaque famille."
  value       = { api = "api", migrate = "migrate", jobs = "jobs", media = "media" }
}

output "api_security_group_id" {
  description = "Groupe de sécurité des tâches api, migrate, jobs, media et outils PostgreSQL."
  value       = aws_security_group.api.id
}

output "execution_role_arns" {
  description = "Rôles d'exécution par usage (api, migrate, jobs, media)."
  value       = { for k, r in aws_iam_role.execution : k => r.arn }
}

output "task_role_arns" {
  description = "Rôles de tâche (api et media seulement ; migrate et jobs n'en ont pas)."
  value       = { for k, r in aws_iam_role.task : k => r.arn }
}

output "task_role_policies" {
  description = "Politiques exactes des rôles de tâche api et media (contrôle des tests, aucun secret)."
  value       = local.task_role_policies
}

output "media_task" {
  description = "Tâche de traitement des médias : famille, conteneur, taille (budget vCPU), ARN de la famille et du cluster nommés dans les droits du rôle de la tâche api."
  value = {
    family      = local.media_family
    family_arn  = local.media_family_arn
    cluster_arn = local.cluster_arn
    container   = local.media_container.name
    cpu         = var.media.cpu
    memory      = var.media.memory
    secrets     = sort(keys(var.media_secrets))
  }
}

output "execution_secret_arns" {
  description = "Secrets que chaque rôle d'exécution peut lire (ARN, contrôle des tests : media sans ADMIN_EMAILS)."
  value       = { for k, r in local.execution_roles : k => r.secret_arns }
}

output "secret_names_by_family" {
  description = "Variables secrètes injectées dans chaque famille (noms seulement, contrôle des tests)."
  value = {
    api     = sort(keys(var.api_secrets))
    migrate = sort(keys(var.migrate_secrets))
    jobs    = sort(keys(var.jobs_secrets))
    media   = sort(keys(var.media_secrets))
  }
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
