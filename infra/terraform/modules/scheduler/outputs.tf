output "schedule_group_name" {
  description = "Groupe de planifications."
  value       = aws_scheduler_schedule_group.this.name
}

output "schedule_names" {
  description = "Planifications créées."
  value       = { for k, s in aws_scheduler_schedule.job : k => s.name }
}

output "task_group_prefix" {
  description = "Préfixe du champ group des tâches lancées (filtre des alertes d'échec)."
  value       = "job:"
}
