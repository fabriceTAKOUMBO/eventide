output "api_url" {
  description = "URL de l'API (vide sans domaine)."
  value       = local.api_url
}

output "web_url" {
  description = "Origine des pages web et des liens de partage (vide sans domaine)."
  value       = local.ingress_enabled ? local.public_web_url : ""
}

output "github_deploy_role_arn" {
  description = "Variable GitHub AWS_DEPLOY_ROLE_ARN de l'environnement."
  value       = module.github_oidc.deploy_role_arn
}

output "deploy_config_parameter" {
  description = "Variable GitHub DEPLOY_CONFIG_PARAMETER de l'environnement."
  value       = aws_ssm_parameter.deploy_config.name
}

output "ecr_repository_url" {
  description = "Dépôt ECR de l'image."
  value       = module.ecr.repository_urls["api"]
}

output "ecs_cluster_name" {
  description = "Cluster ECS."
  value       = module.ecs.cluster_name
}

output "ecs_task_families" {
  description = "Familles de tâches applicatives."
  value       = module.ecs.task_families
}

output "db_task_families" {
  description = "Tâches PostgreSQL : amorçage, sauvegarde, test de restauration."
  value       = module.db_tools.task_families
}

output "ecs_api_security_group_id" {
  description = "Groupe de sécurité des tâches (api, migrations, tâches planifiées, outils PostgreSQL)."
  value       = module.ecs.api_security_group_id
}

output "jobs_log_group" {
  description = "Groupe de journaux des tâches ponctuelles."
  value       = module.ecs.log_group_names["jobs"]
}

output "db_bootstrap_master_secret_name" {
  description = "Nom du secret TEMPORAIRE à créer (mot de passe maître) avant l'amorçage, puis à supprimer."
  value       = module.db_tools.master_password_secret_name
}

output "db_connection_limits" {
  description = "Budget de connexions de l'environnement sur l'instance partagée."
  value = {
    app      = var.db_role_connection_limits.app
    migrator = var.db_role_connection_limits.migrator
    backup   = var.db_role_connection_limits.backup
    total    = local.total_connection_limit
    budget   = var.db_connection_budget
    app_max  = local.app_connections_needed
  }
}

output "backup_bucket" {
  description = "Bucket des sauvegardes logiques."
  value       = module.db_tools.backup_bucket
}

output "content" {
  description = "Contenu : bucket où déposer les fichiers, origine, distribution."
  value = {
    bucket          = module.content.bucket_name
    base_url        = module.content.content_base_url
    distribution_id = module.content.distribution_id
    key_pair_id     = module.content.key_pair_id
  }
}

output "alerts_topic_arn" {
  description = "Sujet SNS des alertes."
  value       = module.observability.alerts_topic_arn
}

output "secret_names" {
  description = "Secrets à remplir à la main (valeur provisoire A_REMPLACER)."
  value       = ["${local.secret_prefix}/gemini-api-key", "${local.secret_prefix}/google-play-service-account"]
}

output "shared_alb" {
  description = "Délai d'inactivité de l'ALB partagé et politique TLS de son écouteur (lus, null sans domaine)."
  value = local.ingress_enabled ? {
    idle_timeout = module.alb[0].idle_timeout
    keep_alive   = local.keep_alive_seconds
    ssl_policy   = module.alb[0].listener_ssl_policy
  } : null
}
