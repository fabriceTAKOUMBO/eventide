output "alerts_topic_arn" {
  description = "Sujet SNS des alertes de l'environnement."
  value       = aws_sns_topic.alerts.arn
}

output "metric_namespace" {
  description = "Espace de noms CloudWatch des métriques issues des journaux."
  value       = local.metric_namespace
}

output "rds_alarm_names" {
  description = "Alarmes de charge de l'instance partagée (métriques seulement)."
  value       = [for a in aws_cloudwatch_metric_alarm.rds : a.alarm_name]
}
