output "task_families" {
  description = "Familles des tâches : { bootstrap, backup, restore }."
  value       = local.families
}

output "task_definition_arns" {
  description = "Révisions enregistrées par Terraform."
  value = {
    bootstrap = aws_ecs_task_definition.bootstrap.arn
    backup    = aws_ecs_task_definition.backup.arn
    restore   = aws_ecs_task_definition.restore.arn
  }
}

output "backup_bucket" {
  description = "Bucket S3 des sauvegardes logiques."
  value       = aws_s3_bucket.backups.id
}

output "backup_bucket_arn" {
  description = "ARN du bucket des sauvegardes."
  value       = aws_s3_bucket.backups.arn
}

output "backup_prefix" {
  description = "Préfixe des objets de sauvegarde."
  value       = local.backup_prefix
}

output "pass_role_arns" {
  description = "Rôles transmis à ECS par le planificateur (sauvegarde)."
  value       = [aws_iam_role.execution["backup"].arn, aws_iam_role.task["backup"].arn]
}

output "database_connection_limit" {
  description = "CONNECTION LIMIT de la base applicative (somme des rôles)."
  value       = local.db_conn_limit
}

output "master_password_secret_name" {
  description = "Nom du secret temporaire attendu par la tâche d'amorçage."
  value       = var.master_password_secret_name
}
