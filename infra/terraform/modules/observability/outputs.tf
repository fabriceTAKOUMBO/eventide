output "alerts_topic_arn" {
  description = "Sujet SNS des alertes de l'environnement."
  value       = aws_sns_topic.alerts.arn
}

output "metric_namespace" {
  description = "Espace de noms CloudWatch des métriques issues des journaux."
  value       = local.metric_namespace
}
